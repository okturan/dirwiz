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

/// Collapses a set of changed-directory paths down to their outermost roots — drops any
/// path nested inside another path in the set (including exact duplicates), keeping only
/// the outermost survivors in first-seen order. Shared between `WarmStartPlanner` (which
/// needs a true folder count for the threshold decision — thousands of raw FSEvents paths
/// under a handful of real folders should count as a handful) and
/// `FileScanner.rescanSubtrees` (which needs to avoid re-enumerating a directory it's
/// about to re-enumerate anyway because a child was also reported changed). String-prefix
/// based since this runs before any index-invalidating mutation — same shallowest-first
/// claim discipline as `SpaceAnalyzer.isDescendantOfClaimed`.
enum PathCollapse {
    static func outermostRoots(_ paths: [String]) -> [String] {
        var uniqueInOrder: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            uniqueInOrder.append(path)
        }

        let shallowestFirst = uniqueInOrder.enumerated().sorted { a, b in
            let depthA = a.element.utf8.reduce(0) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
            let depthB = b.element.utf8.reduce(0) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
            if depthA != depthB { return depthA < depthB }
            return a.offset < b.offset
        }

        var claimed: [String] = []
        for (_, path) in shallowestFirst {
            let nested = claimed.contains { ancestor in
                path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
            }
            if !nested {
                claimed.append(path)
            }
        }

        let claimedSet = Set(claimed)
        return uniqueInOrder.filter { claimedSet.contains($0) }
    }
}

/// Pure decision logic for whether to attempt a warm start — unit-testable without
/// touching FSEvents at all.
public enum WarmStartPlanner {
    public enum Decision: Equatable {
        case warm(targets: [String])
        case coldFallback(reason: String)
    }

    /// Backstop when the caller can't tell us the cached tree's directory count (should
    /// only happen on a malformed/defensive call): above this many collapsed roots,
    /// enumeration cost approaches cold and patch bookkeeping dominates anyway, so refuse
    /// to warm unboundedly rather than trust an unbounded root count blind.
    private static let unknownDirectoryCountBackstop = 5_000

    /// `maxChangedFraction` default 0.20: warm iff the collapsed changed-root count is at
    /// most this fraction of the cached tree's known directory count. Replaces an earlier
    /// absolute cap on raw (pre-collapse) FSEvents paths, which over-triggered cold
    /// fallback — whole-volume roots accumulate thousands of raw events from background
    /// churn within hours even when only a handful of real folders changed.
    ///
    /// A percentage threshold means a tiny cached tree (few known directories) can fall
    /// back to cold from a small absolute number of changed roots — e.g. 2 of 4 directories
    /// reads as 50% churn. That's by design, not a bug to work around: cold scans are
    /// cheapest exactly when the tree is small, so there's nothing to protect by warming.
    /// The `max(1, …)` floor below is deliberate for the same reason — it guarantees at
    /// least one changed root is always tolerated, so an empty or near-empty tree isn't
    /// permanently locked out of ever warming.
    public static func decide(
        cacheAvailable: Bool,
        replay: JournalReplay.Outcome?,
        cachedDirectoryCount: Int?,
        maxChangedFraction: Double = 0.20
    ) -> Decision {
        guard cacheAvailable else {
            return .coldFallback(reason: "no cache available")
        }
        guard let replay else {
            return .coldFallback(reason: "no journal replay result")
        }
        switch replay {
        case .poisoned(let reason):
            return .coldFallback(reason: userFacingPoisonReason(reason))
        case .changes(let targets):
            let roots = PathCollapse.outermostRoots(targets)
            guard let cachedDirectoryCount else {
                guard roots.count <= unknownDirectoryCountBackstop else {
                    return .coldFallback(
                        reason: "too many changed directories (\(roots.count) > \(unknownDirectoryCountBackstop))"
                    )
                }
                return .warm(targets: roots)
            }
            let threshold = max(1, Int(Double(cachedDirectoryCount) * maxChangedFraction))
            guard roots.count <= threshold else {
                let percent = percentage(roots.count, of: cachedDirectoryCount)
                return .coldFallback(reason: "\(roots.count) folders (\(percent)%) changed since last scan")
            }
            return .warm(targets: roots)
        }
    }

    private static func percentage(_ count: Int, of total: Int) -> Int {
        guard total > 0 else { return 100 }
        return Int((Double(count) / Double(total) * 100).rounded())
    }

    /// Poison reasons from `JournalCollector` (e.g. "MustScanSubDirs,RootChanged",
    /// "failed to create FSEventStream") are diagnostic jargon meant for logs, not the
    /// people using the app. Collapse them to the two sentences worth showing: a
    /// distinguishable "timed out" case, and a catch-all for everything else.
    private static func userFacingPoisonReason(_ reason: String) -> String {
        reason.contains("timed out") ? "change journal timed out" : "change journal unavailable"
    }
}
