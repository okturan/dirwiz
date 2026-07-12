import CoreServices
import Foundation

/// Outcome of replaying the FSEvents journal since a cached event id.
public struct JournalReplay: Sendable {
    public enum Outcome: Sendable, Equatable {
        case changes([String])   // changed directory paths (deduped, verbatim from events)
        case poisoned(String)    // MustScanSubDirs/IdsWrapped/RootChanged/(Un)Mount/timeout — reason for logs
    }
    public let outcome: Outcome
    public let newEventId: UInt64   // FSEventsGetCurrentEventId() captured BEFORE the stream started

    public init(outcome: Outcome, newEventId: UInt64) {
        self.outcome = outcome
        self.newEventId = newEventId
    }
}

/// Flags that invalidate a replay outright — FSEvents itself is telling us the change
/// set can't be trusted, so the honest move is a cold fallback rather than acting on a
/// possibly-incomplete or misleading path list. Per the plan-029 feasibility spike.
private let poisonFlags: FSEventStreamEventFlags = UInt32(
    kFSEventStreamEventFlagMustScanSubDirs |
    kFSEventStreamEventFlagEventIdsWrapped |
    kFSEventStreamEventFlagRootChanged |
    kFSEventStreamEventFlagMount |
    kFSEventStreamEventFlagUnmount
)

public enum FSEventsJournal {
    /// The current FSEvents journal position. Callers capture this before a mutation
    /// window they'll want to replay later — e.g. right before a cold scan begins, so
    /// the next warm start knows where to resume from.
    public static func currentEventId() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Replays history for `root` since `eventId`. Completes at `HistoryDone` or
    /// `timeout` (timeout ⇒ `.poisoned` — never hand a possibly-incomplete change set
    /// to the patcher).
    public static func replay(
        root: String,
        since eventId: UInt64,
        timeout: TimeInterval = 10
    ) async -> JournalReplay {
        // Captured FIRST, before the stream even exists: changes landing during this
        // replay (and whatever patch follows it) are then covered by the *next* warm
        // start's replay window — a small overlap re-scan, which 028's subtree rescan
        // proves is idempotent.
        let newEventId = FSEventsGetCurrentEventId()
        let collector = JournalCollector()

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<JournalReplay.Outcome, Never>) in
                collector.start(root: root, since: eventId, timeout: timeout) { outcome in
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            collector.cancel()
        }

        return JournalReplay(outcome: outcome, newEventId: newEventId)
    }
}

/// Drives one FSEventStream created with `sinceWhen:` from creation through
/// `HistoryDone` (or poison, or timeout) and resolves its completion exactly once.
/// Same C-callback + unmanaged-self + lock convention as `FSEventsMonitor` — the
/// stream callback can't capture Swift closures across the C boundary — but this
/// collector is a one-shot, unowned-by-anyone object, so it retains itself for the
/// duration of the stream and releases on completion instead of relying on an
/// external owner the way `FSEventsMonitor` does.
private final class JournalCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var collectedPaths: [String] = []
    private var seenPaths = Set<String>()
    private var finished = false
    private var completion: ((JournalReplay.Outcome) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var selfRetain: Unmanaged<JournalCollector>?

    func start(root: String, since eventId: UInt64, timeout: TimeInterval, completion: @escaping (JournalReplay.Outcome) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()

        let pathsToWatch = [root as CFString] as CFArray
        let retained = Unmanaged.passRetained(self)

        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let newStream = FSEventStreamCreate(
            nil,
            journalCollectorCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(eventId),
            0,
            flags
        ) else {
            retained.release()
            completion(.poisoned("failed to create FSEventStream"))
            return
        }

        let queue = DispatchQueue(label: "com.dirwiz.warmstart.journal", qos: .userInitiated)
        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)

        lock.lock()
        self.stream = newStream
        self.selfRetain = retained
        lock.unlock()

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.finish(.poisoned("timed out waiting for HistoryDone"))
        }
        timeoutWorkItem = timeoutItem
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    /// Cooperative cancellation from the async caller's side (e.g. the enclosing Task
    /// was cancelled) — tears the stream down instead of leaking it.
    func cancel() {
        finish(.poisoned("replay cancelled"))
    }

    fileprivate func handleEvents(paths eventPaths: [String], flags eventFlags: [FSEventStreamEventFlags]) {
        var poisonReason: String?
        var historyDone = false

        lock.lock()
        for (path, flag) in zip(eventPaths, eventFlags) {
            if flag & poisonFlags != 0 {
                poisonReason = Self.describePoison(flag)
            }
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                historyDone = true
                continue
            }
            if seenPaths.insert(path).inserted {
                collectedPaths.append(path)
            }
        }
        let collected = collectedPaths
        lock.unlock()

        if let poisonReason {
            finish(.poisoned(poisonReason))
        } else if historyDone {
            finish(.changes(collected))
        }
    }

    private func finish(_ outcome: JournalReplay.Outcome) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let cb = completion
        completion = nil
        let s = stream
        stream = nil
        let retained = selfRetain
        selfRetain = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        lock.unlock()

        if let s {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        cb?(outcome)
        retained?.release()
    }

    private static func describePoison(_ flag: FSEventStreamEventFlags) -> String {
        var reasons: [String] = []
        if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { reasons.append("MustScanSubDirs") }
        if flag & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 { reasons.append("EventIdsWrapped") }
        if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { reasons.append("RootChanged") }
        if flag & UInt32(kFSEventStreamEventFlagMount) != 0 { reasons.append("Mount") }
        if flag & UInt32(kFSEventStreamEventFlagUnmount) != 0 { reasons.append("Unmount") }
        return reasons.isEmpty ? "poisoned" : reasons.joined(separator: ",")
    }
}

/// Top-level C function used as the FSEventStream callback. Must not capture any
/// context — the collector reference comes via `clientCallBackInfo`.
private let journalCollectorCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in

    guard let info = clientCallBackInfo else { return }
    let collector = Unmanaged<JournalCollector>.fromOpaque(info).takeUnretainedValue()

    guard numEvents > 0 else { return }
    let pathArray = unsafeBitCast(eventPaths, to: CFArray.self)
    guard CFArrayGetCount(pathArray) >= numEvents else { return }
    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

    var paths: [String] = []
    var flagsCopy: [FSEventStreamEventFlags] = []
    paths.reserveCapacity(numEvents)
    flagsCopy.reserveCapacity(numEvents)
    for i in 0..<numEvents {
        guard let rawPath = CFArrayGetValueAtIndex(pathArray, i) else { continue }
        paths.append(unsafeBitCast(rawPath, to: CFString.self) as String)
        flagsCopy.append(flags[i])
    }

    collector.handleEvents(paths: paths, flags: flagsCopy)
}

/// Pure decision logic for whether to attempt a warm start — unit-testable without
/// touching FSEvents at all.
public enum WarmStartPlanner {
    public enum Decision: Equatable {
        case warm(targets: [String])
        case coldFallback(reason: String)
    }

    /// `maxChangedDirs` default 5_000: above that, enumeration cost approaches cold and
    /// patch bookkeeping dominates — cold is simpler and honest.
    public static func decide(
        cacheAvailable: Bool,
        replay: JournalReplay.Outcome?,
        changedCount: Int?,
        maxChangedDirs: Int = 5_000
    ) -> Decision {
        guard cacheAvailable else {
            return .coldFallback(reason: "no cache available")
        }
        guard let replay else {
            return .coldFallback(reason: "no journal replay result")
        }
        switch replay {
        case .poisoned(let reason):
            return .coldFallback(reason: reason)
        case .changes(let targets):
            let count = changedCount ?? targets.count
            guard count <= maxChangedDirs else {
                return .coldFallback(reason: "too many changed directories (\(count) > \(maxChangedDirs))")
            }
            return .warm(targets: targets)
        }
    }
}
