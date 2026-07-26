import Foundation

/// Decides WHEN accumulated FSEvents changes should be spliced into the displayed tree.
///
/// This formally reverses plan 037's "decision 3a: no auto-apply, ever". That decision was
/// right at the time — the splice engine was young. It is now the same proven path warm
/// start uses, with path-keyed exploration restore and an idempotent splice, so the
/// displayed tree can simply stay true instead of asking the user to click Refresh.
///
/// Kept pure and clock-injected so every branch is testable without waiting real seconds.
/// The corresponding decision for warm start lives in `WarmStartPlanner`; both follow the
/// same shape — a pure planner, a thin caller.
public enum LiveRefreshPolicy {

    /// FSEvents silence required before applying. Splicing mid-burst (an install, a build)
    /// means splicing repeatedly over the same directories.
    public static let quiescenceSeconds: TimeInterval = 2.0

    /// Floor between applies, so a steadily-churning volume cannot pin the UI in a
    /// permanent apply loop.
    public static let minimumIntervalSeconds: TimeInterval = 10.0

    /// Matches warm start's `unknownDirectoryCountBackstop`. Past this, splicing is slower
    /// than rescanning, so suggest the rescan rather than grind.
    public static let stormThreshold = 5_000

    public enum Decision: Equatable, Sendable {
        /// Splice now.
        case apply
        /// Nothing pending.
        case idle
        /// Changes are still arriving; wait for quiescence.
        case waitingForQuiescence
        /// Applied too recently.
        case waitingForInterval
        /// Deferred by a guard (a scan, a heavy task, the temporal-diff overlay, or pause).
        case deferred(reason: DeferralReason)
        /// Too many changed directories to splice honestly — offer a full rescan.
        case storm(pendingCount: Int)
    }

    public enum DeferralReason: String, Equatable, Sendable {
        case paused
        case scanning
        case heavyTaskRunning
        /// The temporal-diff overlay is index-keyed against a specific tree; splicing under
        /// it would silently repaint the diff onto renumbered nodes.
        case temporalDiffActive
    }

    /// Everything the decision depends on, gathered by the caller.
    public struct Input: Sendable {
        public var pendingCount: Int
        public var now: TimeInterval
        /// When the most recent FSEvents change arrived. nil when nothing is pending.
        public var lastChangeAt: TimeInterval?
        /// When the last apply completed. nil if none this session.
        public var lastAppliedAt: TimeInterval?
        public var isPaused: Bool
        public var isScanning: Bool
        public var canStartHeavyTask: Bool
        public var isTemporalDiffActive: Bool

        public init(
            pendingCount: Int,
            now: TimeInterval,
            lastChangeAt: TimeInterval? = nil,
            lastAppliedAt: TimeInterval? = nil,
            isPaused: Bool = false,
            isScanning: Bool = false,
            canStartHeavyTask: Bool = true,
            isTemporalDiffActive: Bool = false
        ) {
            self.pendingCount = pendingCount
            self.now = now
            self.lastChangeAt = lastChangeAt
            self.lastAppliedAt = lastAppliedAt
            self.isPaused = isPaused
            self.isScanning = isScanning
            self.canStartHeavyTask = canStartHeavyTask
            self.isTemporalDiffActive = isTemporalDiffActive
        }
    }

    public static func decide(_ input: Input) -> Decision {
        guard input.pendingCount > 0 else { return .idle }

        // Guards come before the storm check on purpose: while a scan is running the
        // pending set is meaningless (the scan is about to replace the tree wholesale), and
        // telling the user to run a rescan during a rescan would be absurd.
        if input.isPaused { return .deferred(reason: .paused) }
        if input.isScanning { return .deferred(reason: .scanning) }
        if input.isTemporalDiffActive { return .deferred(reason: .temporalDiffActive) }
        if !input.canStartHeavyTask { return .deferred(reason: .heavyTaskRunning) }

        if input.pendingCount > stormThreshold {
            return .storm(pendingCount: input.pendingCount)
        }

        // Quiescence: only meaningful if we know when the last change landed. A missing
        // timestamp is treated as "quiet enough" rather than blocking forever.
        if let lastChangeAt = input.lastChangeAt,
           input.now - lastChangeAt < quiescenceSeconds {
            return .waitingForQuiescence
        }

        if let lastAppliedAt = input.lastAppliedAt,
           input.now - lastAppliedAt < minimumIntervalSeconds {
            return .waitingForInterval
        }

        return .apply
    }
}
