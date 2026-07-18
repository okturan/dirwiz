import Foundation

/// Budget for treemap layouts computed *while a scan is in progress* (Plan 044).
///
/// With plan 039's live tree building, a scan-time layout runs against a tree that keeps
/// growing. Two controls keep this affordable while a scan is active; both are lifted the
/// instant it ends — the completion layout is always full-depth and never skipped:
///
///  1. Sparsity (PRIMARY): a scan-time layout is only allowed once a meaningful amount of
///     both time AND tree growth has passed since the previous one
///     (`shouldRunScanTimeLayout`). This caps the total *count* of scan-time layouts over
///     a scan's lifetime — roughly 2-4 over a ~20s scan, versus one on every ~2.5s
///     revision bump (~8) before this control existed. Fewer passes matters more than
///     cheaper passes: it directly cuts the total CPU time layout steals from the scan
///     (live sample evidence that motivated this plan: SquarifyLayout dominating the
///     profile of a running scan while scan workers sat in lock-waits).
///  2. Depth-limited (SECONDARY / insurance): recursion stops at `scanTimeMaxDepth` so the
///     rare scan-time layout that does run stays cheap even on a huge tree. Squarify runs
///     off the main thread (`Task.detached` in
///     `CushionTreemapCoordinator.recomputeLayoutIfNeeded`), confirmed by reading that
///     call site — so this isn't a main-thread-stall guard, it bounds how much CPU a
///     background pass takes away from the scan's own worker threads. Sized from
///     measurement on synthetic multi-million-node trees (plan 044's report): a
///     full-depth (unlimited) pass over 2-5M nodes cost ~15-80ms depending on tree shape —
///     well under budget even with no cap at all — but a directory with a large flat pile
///     of files (e.g. node_modules) that the cutoff excludes can turn tens of milliseconds
///     into a fraction of one. 8 is looser than the depth this plan started with (a
///     shallower main-thread-stall-sized cap) precisely because layout turned out to run
///     off-main and sparsity above now does the heavy lifting — this is insurance against
///     a pathological single directory, not the primary cost control.
enum ScanTimeLayoutBudget {
    /// Depth below the treemap root that scan-time layouts descend to. Below this, whole
    /// subtrees render as one solid rect until a later scan-time layout is allowed to run
    /// (see sparsity below) or the scan ends.
    static let scanTimeMaxDepth = 8

    /// Depth used once a scan is no longer in progress (completion + all post-scan
    /// interaction layouts). Effectively unlimited for any realistic directory tree —
    /// unchanged from the depth the treemap has always used.
    static let unlimitedDepth = 20

    /// Minimum wall-clock time between scan-time layouts, regardless of how fast the
    /// previous one ran — a floor so a burst of cheap layouts early in a scan can't rack
    /// up count.
    static let minLayoutInterval: TimeInterval = 5.0

    /// The next scan-time layout is allowed only after this many multiples of the
    /// PREVIOUS layout's own duration have elapsed, in addition to `minLayoutInterval` —
    /// a slow layout on a big tree earns a proportionally longer rest before the next one.
    static let layoutIntervalDurationMultiplier: Double = 4.0

    /// Minimum tree growth, as a fraction of the node count seen at the previous scan-time
    /// layout, required to justify paying for another one — no point relaying out a tree
    /// that's barely changed since.
    static let minGrowthFraction: Double = 0.25

    /// The maxDepth to pass to `SquarifyLayout.layout` for the current scan state.
    static func maxDepth(isScanning: Bool) -> Int {
        isScanning ? scanTimeMaxDepth : unlimitedDepth
    }

    /// Whether a new scan-time layout is allowed to run right now, given the time and
    /// node count observed at the previous scan-time layout (if any) and the tree's
    /// current node count. `elapsedSinceLastLayout` is nil when no scan-time layout has
    /// run yet this scan — always allowed in that case, so the scan gets its first live
    /// shape promptly rather than waiting out the interval floor with nothing to show.
    /// Only meaningful while a scan is in progress — callers must gate that separately
    /// (the completion layout must never be skipped).
    static func shouldRunScanTimeLayout(
        elapsedSinceLastLayout: TimeInterval?,
        lastLayoutDuration: TimeInterval,
        lastNodeCount: Int,
        currentNodeCount: Int
    ) -> Bool {
        guard let elapsedSinceLastLayout else { return true }
        let requiredInterval = max(minLayoutInterval, layoutIntervalDurationMultiplier * lastLayoutDuration)
        guard elapsedSinceLastLayout >= requiredInterval else { return false }
        guard lastNodeCount > 0 else { return true }
        let growth = Double(currentNodeCount - lastNodeCount) / Double(lastNodeCount)
        return growth >= minGrowthFraction
    }
}
