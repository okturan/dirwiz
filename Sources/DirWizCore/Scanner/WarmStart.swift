import CoreServices
import Foundation

/// Outcome of replaying the FSEvents journal since a cached event id.
public struct JournalReplay: Sendable {
    public enum Outcome: Sendable, Equatable {
        case changes([String])   // changed directory paths (deduped, verbatim from events)
        case poisoned(String)    // MustScanSubDirs/IdsWrapped/RootChanged/(Un)Mount/timeout - reason for logs
    }
    public let outcome: Outcome
    public let newEventId: UInt64   // FSEventsGetCurrentEventId() captured BEFORE the stream started

    public init(outcome: Outcome, newEventId: UInt64) {
        self.outcome = outcome
        self.newEventId = newEventId
    }
}

/// Flags that invalidate a replay outright - FSEvents itself is telling us the change
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
    /// window they'll want to replay later - e.g. right before a cold scan begins, so
    /// the next warm start knows where to resume from.
    public static func currentEventId() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Replays history for `root` since `eventId`. Completes at `HistoryDone` or
    /// `timeout` (timeout ⇒ `.poisoned` - never hand a possibly-incomplete change set
    /// to the patcher).
    public static func replay(
        root: String,
        since eventId: UInt64,
        timeout: TimeInterval = 10
    ) async -> JournalReplay {
        // Captured FIRST, before the stream even exists: changes landing during this
        // replay (and whatever patch follows it) are then covered by the *next* warm
        // start's replay window - a small overlap re-scan, which 028's subtree rescan
        // proves is idempotent.
        let newEventId = FSEventsGetCurrentEventId()

        // An already-expired deadline is deterministic policy, not a scheduler race. The
        // former test used 1ms against a real stream; `HistoryDone` can honestly arrive
        // inside that window and made the alleged timeout test intermittently return
        // `.changes([])`. Production uses 10s. Keep zero useful as the exact timeout seam.
        guard timeout > 0 else {
            return JournalReplay(
                outcome: .poisoned("timed out waiting for HistoryDone"),
                newEventId: newEventId
            )
        }
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
/// Same C-callback + unmanaged-self + lock convention as `FSEventsMonitor` - the
/// stream callback can't capture Swift closures across the C boundary - but this
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

        // FileEvents gives per-file granularity instead of per-directory - without it,
        // ANY file changing directly inside a huge directory (e.g. a shell writing
        // ~/.zsh_history) is reported as "the whole directory changed", which for a
        // root-volume scan can mean "the whole home folder" (a large fraction of the
        // entire tree). `handleEvents` below reduces file-level events back to their
        // parent directory - same pattern `FSEventsMonitor` already uses for the live
        // watcher - so this doesn't change what `rescanSubtrees` receives in shape, only
        // how precisely huge coalesced directories get narrowed down first.
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes
        )

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
    /// was cancelled) - tears the stream down instead of leaking it.
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
            // With FileEvents on, a file-level event's finest reportable unit is the
            // file itself - reduce it to its parent directory so `rescanSubtrees`
            // keeps receiving directory targets, and so a scattered file touched deep
            // in a huge directory doesn't get treated as "that whole directory" the
            // way a directory-level event's path already, correctly, would be.
            let isDir = flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
            let target = isDir ? path : (path as NSString).deletingLastPathComponent
            if seenPaths.insert(target).inserted {
                collectedPaths.append(target)
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
/// context - the collector reference comes via `clientCallBackInfo`.
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

/// Collapses a set of changed-directory paths down to their outermost roots - drops any
/// path nested inside another path in the set (including exact duplicates), keeping only
/// the outermost survivors in first-seen order. Shared between `WarmStartPlanner` (which
/// needs a true folder count for the threshold decision - thousands of raw FSEvents paths
/// under a handful of real folders should count as a handful) and
/// `FileScanner.rescanSubtrees` (which needs to avoid re-enumerating a directory it's
/// about to re-enumerate anyway because a child was also reported changed). String-prefix
/// based since this runs before any index-invalidating mutation - same shallowest-first
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

/// Pure decision logic for whether to attempt a warm start - unit-testable without
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

    /// Retained at 25% from the measured cost model rather than changed for appearance:
    /// cold is 26.42s for 4,749,300 items and warm is approximately `26.42f + 0.15`.
    /// At `f = 0.25`, warm predicts 6.755s versus 26.42s cold (19.665s saved); the
    /// model's crossover is about 99.43%, so 25% remains deliberately conservative.
    public static let defaultMaxChangedItemFraction = 0.25

    /// `maxChangedFraction` default 0.20: warm iff the collapsed changed-root count is at
    /// most this fraction of the cached tree's known directory count. Replaces an earlier
    /// absolute cap on raw (pre-collapse) FSEvents paths, which over-triggered cold
    /// fallback - whole-volume roots accumulate thousands of raw events from background
    /// churn within hours even when only a handful of real folders changed.
    ///
    /// A percentage threshold means a tiny cached tree (few known directories) can fall
    /// back to cold from a small absolute number of changed roots - e.g. 2 of 4 directories
    /// reads as 50% churn. That's by design, not a bug to work around: cold scans are
    /// cheapest exactly when the tree is small, so there's nothing to protect by warming.
    /// The `max(1, …)` floor below is deliberate for the same reason - it guarantees at
    /// least one changed root is always tolerated, so an empty or near-empty tree isn't
    /// permanently locked out of ever warming.
    ///
    /// `cachedTotalItemCount`/`estimatedPatchItems` (plan 042) add a cost-based rule that
    /// runs BEFORE the root-count rule, when the caller can supply both: root COUNT alone
    /// can't see that a single collapsed root is a subtree of 100k+ files (the reported
    /// incident - days of churn collapsed to a handful of roots sitting high in the tree)
    /// while the root-count rule alone happily warms a handful of roots. Judging by
    /// estimated WORK instead catches that shape. The production AppState call supplies
    /// both values, so this is the primary live gate rather than an optional dormant one.
    ///
    /// `maxPatchRoots` is only a sanity backstop and runs after the item rule. Batched
    /// subtree splice changed 38 roots from 9.14s across 38 full-tree recompactions to one
    /// 0.118-0.164s compaction, so per-root structural cost is no longer a reason to reject
    /// ordinary many-root patches. The default 512 is well above the measured 84/99/131
    /// accumulated-root workloads while still refusing pathological unbounded input.
    public static func decide(
        cacheAvailable: Bool,
        replay: JournalReplay.Outcome?,
        cachedDirectoryCount: Int?,
        cachedTotalItemCount: Int? = nil,
        estimatedPatchItems: Int? = nil,
        maxChangedFraction: Double = 0.20,
        maxChangedItemFraction: Double = defaultMaxChangedItemFraction,
        maxPatchRoots: Int = 512
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

            if let estimatedPatchItems,
               let cachedTotalItemCount,
               let reason = itemBudgetFallbackReason(
                   stagedItems: estimatedPatchItems,
                   cachedTotalItemCount: cachedTotalItemCount,
                   maxChangedItemFraction: maxChangedItemFraction
               ) {
                return .coldFallback(reason: reason)
            }

            guard roots.count <= maxPatchRoots else {
                return .coldFallback(reason: "\(roots.count) changed locations - full scan is faster")
            }

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

    /// Maximum integer item count admitted by the same fraction `decide` uses. Warm-patch
    /// tiers pass the remainder of this one budget into Phase A, so splitting work into an
    /// interactive and trailing tier cannot accidentally grant each tier a fresh 25%.
    public static func maximumStagedItemCount(
        cachedTotalItemCount: Int,
        maxChangedItemFraction: Double = defaultMaxChangedItemFraction
    ) -> Int? {
        guard cachedTotalItemCount > 0 else { return nil }
        let threshold = Double(cachedTotalItemCount) * maxChangedItemFraction
        guard threshold.isFinite else {
            return threshold > 0 ? Int.max : 0
        }
        guard threshold > 0 else { return 0 }
        guard threshold < Double(Int.max) else { return Int.max }
        return Int(threshold.rounded(.down))
    }

    /// Shared reason for both the cached estimate gate and the exact post-staging guard.
    /// Keeping one formatter ensures a patch refused after live growth is surfaced through
    /// the same item-fraction vocabulary as an up-front refusal, never as root-count cost.
    public static func itemBudgetFallbackReason(
        stagedItems: Int,
        cachedTotalItemCount: Int,
        maxChangedItemFraction: Double = defaultMaxChangedItemFraction
    ) -> String? {
        guard cachedTotalItemCount > 0 else { return nil }
        let itemThreshold = Double(cachedTotalItemCount) * maxChangedItemFraction
        guard Double(stagedItems) > itemThreshold else { return nil }
        let percent = percentage(stagedItems, of: cachedTotalItemCount)
        return "~\(percent)% of files changed since last scan"
    }

    /// Sum of the CACHED tree's subtree item counts for each collapsed changed root - the
    /// cost-based decision's numerator (plan 042). Caller-computed (like
    /// `cachedDirectoryCount`) rather than done inside `decide` itself, keeping that
    /// function pure logic with no `FileTree` dependency of its own.
    ///
    /// A root that doesn't resolve in the cached tree (a brand-new top-level directory
    /// FSEvents reported, or one already deleted) contributes a small constant instead of
    /// zero - the estimate only needs to bound a decision, not be exact, and treating an
    /// unresolvable root as "free" would silently undercount exactly the case (new
    /// content) most likely to be large.
    public static func estimatedPatchItemCount(forChangedPaths targets: [String], cachedTree: FileTree) -> Int {
        estimatedPatchItemCounts(
            forChangedPaths: targets,
            cachedTree: cachedTree
        ).values.reduce(into: 0) { total, itemCount in
            let sum = total.addingReportingOverflow(itemCount)
            total = sum.overflow ? Int.max : sum.partialValue
        }
    }

    /// Per-collapsed-root form used for production observability. It shares one cached
    /// snapshot across every root so recording estimates does not repeat the aggregate
    /// estimator's whole-tree snapshot/traversal setup immediately before a patch.
    public static func estimatedPatchItemCounts(
        forChangedPaths targets: [String],
        cachedTree: FileTree
    ) -> [String: Int] {
        let roots = PathCollapse.outermostRoots(targets)
        guard !roots.isEmpty else { return [:] }

        let snapshot = cachedTree.pathBuildingSnapshot()
        var estimates: [String: Int] = [:]
        estimates.reserveCapacity(roots.count)
        for root in roots {
            guard let components = FileScanner.relativeComponents(of: root, rootPath: snapshot.rootPath),
                  let index = FileTree.descendPath(components, nodes: snapshot.nodes, stringPool: snapshot.stringPool) else {
                estimates[root] = unresolvedRootItemEstimate
                continue
            }
            estimates[root] = cachedTree.subtreeItemCount(at: index)
        }
        return estimates
    }

    /// Fallback contribution (plan 042) for a changed root that doesn't resolve against
    /// the cached tree at all - see `estimatedPatchItemCount`'s doc comment.
    private static let unresolvedRootItemEstimate = 32

    /// Poison reasons from `JournalCollector` (e.g. "MustScanSubDirs,RootChanged",
    /// "failed to create FSEventStream") are diagnostic jargon meant for logs, not the
    /// people using the app. Collapse them to the two sentences worth showing: a
    /// distinguishable "timed out" case, and a catch-all for everything else.
    private static func userFacingPoisonReason(_ reason: String) -> String {
        reason.contains("timed out") ? "change journal timed out" : "change journal unavailable"
    }
}
