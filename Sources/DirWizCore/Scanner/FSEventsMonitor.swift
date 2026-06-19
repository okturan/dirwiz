import Foundation
import CoreServices

/// Represents a filesystem change detected by FSEvents.
public struct FSChange: Sendable {
    public let path: String
    public let flags: FSEventStreamEventFlags
    public let timestamp: Date

    public var isCreated: Bool { flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 }
    public var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
    public var isModified: Bool { flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 }
    public var isRenamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
    public var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
}

/// Accumulated change summary for a directory.
public struct DirectoryChangeSummary: Identifiable, Sendable {
    public let id: String
    public let path: String
    public var changeCount: Int
    public var lastChangeDate: Date
    public var hasCreations: Bool
    public var hasDeletions: Bool
    public var hasModifications: Bool
}

/// Monitors filesystem changes using FSEvents after initial scan.
///
/// Uses the low-level C callback FSEvents API, which requires an unmanaged
/// self pointer — hence `@unchecked Sendable`. All mutable state is guarded
/// by `lock`.
public final class FSEventsMonitor: @unchecked Sendable {

    private var stream: FSEventStreamRef?
    private let watchPath: String
    private let lock = NSLock()
    private var changes: [String: DirectoryChangeSummary] = [:]
    private var isRunning = false
    private var onChanges: (@Sendable ([DirectoryChangeSummary]) -> Void)?

    /// Maximum number of directory entries kept to prevent unbounded growth.
    private static let maxTrackedDirectories = 1000

    public init(watchPath: String) {
        self.watchPath = watchPath
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Start monitoring. Calls `onChanges` on a background thread when changes
    /// are detected. Batches events with a 3-second latency window.
    public func start(onChanges: @escaping @Sendable ([DirectoryChangeSummary]) -> Void) {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        self.onChanges = onChanges
        lock.unlock()

        let pathsToWatch = [watchPath as CFString] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let newStream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            3.0,
            flags
        ) else { return }

        let queue = DispatchQueue(label: "com.dirwiz.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)

        lock.lock()
        self.stream = newStream
        isRunning = true
        lock.unlock()
    }

    /// Stop monitoring and release the FSEventStream.
    public func stop() {
        lock.lock()
        let s = stream
        stream = nil
        isRunning = false
        onChanges = nil
        lock.unlock()

        if let s {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    /// Get current accumulated changes, sorted by changeCount descending.
    public func currentChanges() -> [DirectoryChangeSummary] {
        lock.lock()
        let snapshot = changes.values.sorted { $0.changeCount > $1.changeCount }
        lock.unlock()
        return snapshot
    }

    /// Clear accumulated changes.
    public func clearChanges() {
        lock.lock()
        changes.removeAll()
        lock.unlock()
    }

    /// Whether the monitor is currently running.
    public var monitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    // MARK: - Internal

    /// Process raw FSChange events into directory summaries.
    fileprivate func processChanges(_ newChanges: [FSChange]) {
        lock.lock()

        for change in newChanges {
            let dirPath = change.isDirectory
                ? change.path
                : (change.path as NSString).deletingLastPathComponent

            if var summary = changes[dirPath] {
                summary.changeCount += 1
                summary.lastChangeDate = change.timestamp
                if change.isCreated { summary.hasCreations = true }
                if change.isRemoved { summary.hasDeletions = true }
                if change.isModified { summary.hasModifications = true }
                changes[dirPath] = summary
            } else {
                changes[dirPath] = DirectoryChangeSummary(
                    id: dirPath,
                    path: dirPath,
                    changeCount: 1,
                    lastChangeDate: change.timestamp,
                    hasCreations: change.isCreated,
                    hasDeletions: change.isRemoved,
                    hasModifications: change.isModified
                )
            }
        }

        // Evict lowest-activity entries if we exceed the cap.
        if changes.count > Self.maxTrackedDirectories {
            let sorted = changes.sorted { $0.value.changeCount > $1.value.changeCount }
            changes = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxTrackedDirectories).map { ($0.key, $0.value) })
        }

        let snapshot = changes.values.sorted { $0.changeCount > $1.changeCount }
        let callback = onChanges
        lock.unlock()

        callback?(snapshot)
    }
}

// MARK: - C Callback

/// Top-level C function used as the FSEventStream callback.
/// Must not capture any context — the monitor reference comes via `clientCallBackInfo`.
private let fsEventsCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in

    guard let info = clientCallBackInfo else { return }
    let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(info).takeUnretainedValue()

    guard numEvents > 0 else { return }
    let pathArray = unsafeBitCast(eventPaths, to: CFArray.self)
    guard CFArrayGetCount(pathArray) >= numEvents else { return }

    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

    let now = Date()
    var batch: [FSChange] = []
    batch.reserveCapacity(numEvents)

    for i in 0..<numEvents {
        guard let rawPath = CFArrayGetValueAtIndex(pathArray, i) else { continue }
        let path = unsafeBitCast(rawPath, to: CFString.self) as String
        batch.append(FSChange(
            path: path,
            flags: flags[i],
            timestamp: now
        ))
    }

    monitor.processChanges(batch)
}
