import CoreServices
import Darwin
import Foundation
import Testing
@testable import DirWizCore

/// Opt-in because this reads the real per-device FSEvents history for the selected
/// volume. It never enumerates or mutates volume content; ordinary and CI test runs stay
/// hermetic.
private let runFSEventsHoldbackBenchmark =
    ProcessInfo.processInfo.environment["DIRWIZ_JOURNAL_HOLDBACK_BENCH"] == "1"

private let holdbackPoisonFlags: FSEventStreamEventFlags = UInt32(
    kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagRootChanged
        | kFSEventStreamEventFlagMount
        | kFSEventStreamEventFlagUnmount
)

private struct DeviceHistoryReplayResult: Sendable {
    enum Outcome: Sendable {
        case changes
        case poisoned(String)
    }

    let outcome: Outcome
    /// Every callback entry, including the HistoryDone control marker.
    let rawCallbackEventCount: Int
    /// Production-shaped directory targets after file events have been reduced to their
    /// parent and exact duplicates removed, but before PathCollapse.
    let directoryTargets: [String]
    let latestEventId: UInt64
}

/// One-shot device-history stream. The timestamp lookup that supplies `sinceEventId` is
/// guaranteed by FSEvents only for `FSEventStreamCreateRelativeToDevice`; deliberately do
/// not pass that ID to DirWiz's production per-host `FSEventsJournal.replay`.
private final class DeviceHistoryReplayCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let deviceMountPoint: String
    private let queue = DispatchQueue(
        label: "com.dirwiz.tests.fsevents-holdback",
        qos: .userInitiated
    )

    private var stream: FSEventStreamRef?
    private var completion: ((DeviceHistoryReplayResult) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var selfRetain: Unmanaged<DeviceHistoryReplayCollector>?
    private var finished = false
    private var rawCallbackEventCount = 0
    private var directoryTargets: [String] = []
    private var seenDirectoryTargets = Set<String>()

    init(deviceMountPoint: String) {
        self.deviceMountPoint = deviceMountPoint
    }

    func replay(
        device: dev_t,
        relativeRoot: String,
        sinceEventId: UInt64,
        timeout: TimeInterval
    ) async -> DeviceHistoryReplayResult {
        await withCheckedContinuation { continuation in
            start(
                device: device,
                relativeRoot: relativeRoot,
                sinceEventId: sinceEventId,
                timeout: timeout
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func start(
        device: dev_t,
        relativeRoot: String,
        sinceEventId: UInt64,
        timeout: TimeInterval,
        completion: @escaping (DeviceHistoryReplayResult) -> Void
    ) {
        lock.lock()
        self.completion = completion
        lock.unlock()

        let retained = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let pathsToWatch = [relativeRoot as CFString] as CFArray
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let newStream = FSEventStreamCreateRelativeToDevice(
            nil,
            deviceHistoryReplayCallback,
            &context,
            device,
            pathsToWatch,
            FSEventStreamEventId(sinceEventId),
            0,
            flags
        ) else {
            retained.release()
            finish(.poisoned("failed to create per-device FSEventStream"))
            return
        }

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.finish(.poisoned("timed out waiting for HistoryDone"))
        }

        lock.lock()
        stream = newStream
        selfRetain = retained
        timeoutWorkItem = timeoutItem
        lock.unlock()

        FSEventStreamSetDispatchQueue(newStream, queue)
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        guard FSEventStreamStart(newStream) else {
            finish(.poisoned("failed to start per-device FSEventStream"))
            return
        }
    }

    fileprivate func handleEvents(
        rawCallbackEventCount batchEventCount: Int,
        paths eventPaths: [String],
        flags eventFlags: [FSEventStreamEventFlags]
    ) {
        var poisonReason: String?
        var historyDone = false

        lock.lock()
        rawCallbackEventCount += batchEventCount
        for (relativePath, flag) in zip(eventPaths, eventFlags) {
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                historyDone = true
                continue
            }
            if flag & holdbackPoisonFlags != 0 {
                poisonReason = Self.describePoison(flag)
            }

            let absolutePath = absoluteDevicePath(relativePath)
            let isDirectory =
                flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
            let target = isDirectory
                ? absolutePath
                : (absolutePath as NSString).deletingLastPathComponent
            if seenDirectoryTargets.insert(target).inserted {
                directoryTargets.append(target)
            }
        }
        lock.unlock()

        if let poisonReason {
            finish(.poisoned(poisonReason))
        } else if historyDone {
            finish(.changes)
        }
    }

    private func absoluteDevicePath(_ relativePath: String) -> String {
        let withoutLeadingSlash = relativePath.drop {
            $0 == "/"
        }
        guard !withoutLeadingSlash.isEmpty else {
            return deviceMountPoint
        }
        if deviceMountPoint == "/" {
            return "/" + String(withoutLeadingSlash)
        }
        return deviceMountPoint + "/" + String(withoutLeadingSlash)
    }

    private func finish(_ outcome: DeviceHistoryReplayResult.Outcome) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let callback = completion
        completion = nil
        let activeStream = stream
        stream = nil
        let retained = selfRetain
        selfRetain = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let rawCount = rawCallbackEventCount
        let targets = directoryTargets
        lock.unlock()

        let latestEventId = activeStream.map {
            UInt64(FSEventStreamGetLatestEventId($0))
        } ?? 0
        if let activeStream {
            FSEventStreamStop(activeStream)
            FSEventStreamInvalidate(activeStream)
            FSEventStreamRelease(activeStream)
        }

        callback?(
            DeviceHistoryReplayResult(
                outcome: outcome,
                rawCallbackEventCount: rawCount,
                directoryTargets: targets,
                latestEventId: latestEventId
            )
        )
        retained?.release()
    }

    private static func describePoison(
        _ flag: FSEventStreamEventFlags
    ) -> String {
        var reasons: [String] = []
        if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            reasons.append("MustScanSubDirs")
        }
        if flag & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
            reasons.append("EventIdsWrapped")
        }
        if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
            reasons.append("RootChanged")
        }
        if flag & UInt32(kFSEventStreamEventFlagMount) != 0 {
            reasons.append("Mount")
        }
        if flag & UInt32(kFSEventStreamEventFlagUnmount) != 0 {
            reasons.append("Unmount")
        }
        return reasons.isEmpty ? "poisoned" : reasons.joined(separator: ",")
    }
}

private let deviceHistoryReplayCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in

    guard let info = clientCallBackInfo, numEvents > 0 else { return }
    let collector =
        Unmanaged<DeviceHistoryReplayCollector>
            .fromOpaque(info)
            .takeUnretainedValue()
    let pathArray = unsafeBitCast(eventPaths, to: CFArray.self)
    guard CFArrayGetCount(pathArray) >= numEvents else { return }
    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

    var paths: [String] = []
    var copiedFlags: [FSEventStreamEventFlags] = []
    paths.reserveCapacity(numEvents)
    copiedFlags.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        guard let rawPath = CFArrayGetValueAtIndex(pathArray, index) else {
            continue
        }
        paths.append(unsafeBitCast(rawPath, to: CFString.self) as String)
        copiedFlags.append(flags[index])
    }
    collector.handleEvents(
        rawCallbackEventCount: numEvents,
        paths: paths,
        flags: copiedFlags
    )
}

@Suite(
    "FSEvents holdback device-history feasibility benchmark",
    .serialized,
    .enabled(
        if: runFSEventsHoldbackBenchmark,
        "Set DIRWIZ_JOURNAL_HOLDBACK_BENCH=1 to read real per-device journal history"
    )
)
struct FSEventsHoldbackBenchmarkTests {
    private static let holdbackMinutes = [1, 5, 15, 30]
    private static let repeats = 3
    private static let replayTimeout: TimeInterval = 10

    private struct HoldbackPoint {
        let minutes: Int
        let cutoffPOSIXTime: TimeInterval
        let eventId: UInt64
    }

    private struct RecordedRepeat {
        let minutes: Int
        let duration: Double
        let poisoned: Bool
    }

    @Test(
        "Replay 1, 5, 15, and 30 minute per-device history windows",
        .timeLimit(.minutes(5))
    )
    func replayMeasuredHoldbackWindows() async throws {
        let requestedRoot =
            ProcessInfo.processInfo.environment["DIRWIZ_JOURNAL_HOLDBACK_ROOT"]
            ?? "/"
        let root = try canonicalDirectoryPath(requestedRoot)
        let deviceLocation = try deviceLocation(for: root)

        guard let deviceUUID =
                FSEventsCopyUUIDForDevice(deviceLocation.device) else {
            Issue.record(
                "FSEvents historical data is unavailable for device \(deviceLocation.device)"
            )
            return
        }
        let deviceUUIDString =
            CFUUIDCreateString(nil, deviceUUID) as String

        // Despite the CFAbsoluteTime spelling in this API, the current SDK contract
        // explicitly defines this parameter as POSIX seconds since 1970.
        let benchmarkPOSIXTime = Date().timeIntervalSince1970
        let points = Self.holdbackMinutes.map { minutes in
            HoldbackPoint(
                minutes: minutes,
                cutoffPOSIXTime:
                    benchmarkPOSIXTime - Double(minutes * 60),
                eventId: UInt64(
                    FSEventsGetLastEventIdForDeviceBeforeTime(
                        deviceLocation.device,
                        CFAbsoluteTime(
                            benchmarkPOSIXTime - Double(minutes * 60)
                        )
                    )
                )
            )
        }

        let sinceNow = UInt64(kFSEventStreamEventIdSinceNow)
        guard points.allSatisfy({
            $0.eventId > 0 && $0.eventId != sinceNow
        }) else {
            Issue.record(
                "FSEvents returned an unusable historical event id; refusing an accidental beginning-of-time replay"
            )
            return
        }

        print(
            "[journal holdback device-history feasibility] BEGIN "
                + "root=\(root), device=\(deviceLocation.device), "
                + "device_uuid=\(deviceUUIDString), "
                + "device_mount=\(deviceLocation.mountPoint), "
                + "relative_root=\(deviceLocation.relativeRoot), "
                + "repeats=\(Self.repeats), timeout_seconds="
                + String(format: "%.0f", Self.replayTimeout)
                + ", production_stream_equivalence=false"
        )

        var recorded: [RecordedRepeat] = []
        recorded.reserveCapacity(Self.holdbackMinutes.count * Self.repeats)

        // Rotate the four ages so no single holdback always runs against the coldest or
        // warmest journal pages. Each result remains a full independent stream replay.
        let schedules = [
            [30, 15, 5, 1],
            [1, 5, 15, 30],
            [15, 30, 1, 5],
        ]
        let pointsByMinutes = Dictionary(
            uniqueKeysWithValues: points.map { ($0.minutes, $0) }
        )

        for repeatIndex in 1...Self.repeats {
            for minutes in schedules[repeatIndex - 1] {
                let point = try #require(pointsByMinutes[minutes])
                let collector = DeviceHistoryReplayCollector(
                    deviceMountPoint: deviceLocation.mountPoint
                )
                let start = ContinuousClock().now
                let result = await collector.replay(
                    device: deviceLocation.device,
                    relativeRoot: deviceLocation.relativeRoot,
                    sinceEventId: point.eventId,
                    timeout: Self.replayTimeout
                )
                let duration = seconds(ContinuousClock().now - start)
                let collapsedCount =
                    PathCollapse.outermostRoots(result.directoryTargets).count
                let poisonReason: String
                let poisoned: Bool
                switch result.outcome {
                case .changes:
                    poisoned = false
                    poisonReason = "none"
                case .poisoned(let reason):
                    poisoned = true
                    poisonReason = reason
                }

                recorded.append(
                    RecordedRepeat(
                        minutes: minutes,
                        duration: duration,
                        poisoned: poisoned
                    )
                )
                print(
                    "[journal holdback device-history feasibility] "
                        + "age_minutes=\(minutes), repeat=\(repeatIndex), "
                        + "duration_seconds="
                        + String(format: "%.6f", duration)
                        + ", raw_callback_events="
                        + "\(result.rawCallbackEventCount), "
                        + "deduped_directory_targets="
                        + "\(result.directoryTargets.count), "
                        + "collapsed_roots=\(collapsedCount), "
                        + "poisoned=\(poisoned), poison_reason="
                        + "\(poisonReason), since_event_id=\(point.eventId), "
                        + "latest_stream_event_id=\(result.latestEventId), "
                        + "cutoff_posix_seconds="
                        + String(format: "%.3f", point.cutoffPOSIXTime)
                )
            }
        }

        for minutes in Self.holdbackMinutes {
            let samples = recorded.filter { $0.minutes == minutes }
            let durations = samples.map(\.duration).sorted()
            let median = durations[durations.count / 2]
            let poisonedCount = samples.reduce(0) {
                $0 + ($1.poisoned ? 1 : 0)
            }
            let summaryFields = [
                "age_minutes=\(minutes)",
                "repeats=\(samples.count)",
                "duration_min_seconds="
                    + String(format: "%.6f", durations.first!),
                "duration_median_seconds="
                    + String(format: "%.6f", median),
                "duration_max_seconds="
                    + String(format: "%.6f", durations.last!),
                "poisoned_repeats=\(poisonedCount)",
                "production_stream_equivalence=false",
            ]
            print(
                "[journal holdback device-history feasibility] SUMMARY "
                    + summaryFields.joined(separator: ", ")
            )
        }
    }

    private func canonicalDirectoryPath(_ requestedPath: String) throws -> String {
        let requested = requestedPath.isEmpty ? "/" : requestedPath
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(requested, &buffer) != nil else {
            throw POSIXError(.init(rawValue: errno) ?? .ENOENT)
        }
        return buffer.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
    }

    private func deviceLocation(
        for root: String
    ) throws -> (device: dev_t, mountPoint: String, relativeRoot: String) {
        let descriptor = open(root, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var rootStat = stat()
        guard fstat(descriptor, &rootStat) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let volumeValues = try rootURL.resourceValues(forKeys: [.volumeURLKey])
        guard let volumeURL = volumeValues.volume else {
            throw CocoaError(.fileReadUnknown)
        }
        let mountPoint = try canonicalDirectoryPath(volumeURL.path)

        var mountStat = stat()
        guard lstat(mountPoint, &mountStat) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard mountStat.st_dev == rootStat.st_dev else {
            throw CocoaError(.fileReadUnknown)
        }

        let relativeRoot: String
        if root == mountPoint {
            relativeRoot = ""
        } else {
            let prefix = mountPoint == "/" ? "/" : mountPoint + "/"
            guard root.hasPrefix(prefix) else {
                throw CocoaError(.fileReadUnknown)
            }
            relativeRoot = String(root.dropFirst(prefix.count))
        }
        return (
            device: rootStat.st_dev,
            mountPoint: mountPoint,
            relativeRoot: relativeRoot
        )
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds)
                / 1_000_000_000_000_000_000
    }
}
