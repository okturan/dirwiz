import Foundation

/// Budget for treemap layouts computed *while a scan is in progress* (Plan 044).
///
/// With plan 039's live tree building, a scan-time layout runs against a tree that keeps
/// growing — full-depth squarify over the current (partial) tree costs O(current tree
/// size), so repeating it on every periodic revision bump makes total layout work grow
/// quadratically with scan progress, starving the scan workers of CPU (live sample
/// evidence: SquarifyLayout dominating the profile of a running scan). Two independent
/// caps apply only while a scan is active; both are lifted the instant it ends — the
/// completion layout is always full-depth and never skipped:
///
///  1. Depth-limited: recursion stops at `scanTimeMaxDepth`, rendering everything below as
///     a single solid rect for that directory (existing `SquarifyLayout` maxDepth cutoff).
///  2. Adaptively skipped: a periodic relayout is skipped outright when the previous
///     scan-time layout was expensive AND the tree has barely grown since — cheap
///     insurance on top of the depth limit for the largest trees.
enum ScanTimeLayoutBudget {
    /// Depth below the treemap root that scan-time layouts descend to. Below this, whole
    /// subtrees render as one solid rect until the scan ends. 4 keeps typical volumes
    /// (Users/Library/Applications-shaped trees) showing a meaningful shape at low cost.
    static let scanTimeMaxDepth = 4

    /// Depth used once a scan is no longer in progress (completion + all post-scan
    /// interaction layouts). Effectively unlimited for any realistic directory tree —
    /// unchanged from the depth the treemap has always used.
    static let unlimitedDepth = 20

    /// A scan-time layout slower than this is considered "expensive" for the adaptive
    /// skip below.
    static let skipDurationThreshold: TimeInterval = 0.1

    /// Minimum tree growth, as a fraction of the node count seen at the last scan-time
    /// layout, required to justify paying for another expensive layout.
    static let skipGrowthThreshold: Double = 0.25

    /// The maxDepth to pass to `SquarifyLayout.layout` for the current scan state.
    static func maxDepth(isScanning: Bool) -> Int {
        isScanning ? scanTimeMaxDepth : unlimitedDepth
    }

    /// Whether to skip the next scan-time relayout, given the previous scan-time layout's
    /// duration and the node count it saw, plus the tree's current node count. Only
    /// meaningful while a scan is in progress — callers must gate that separately (the
    /// completion layout must never be skipped).
    static func shouldSkip(lastDuration: TimeInterval, lastNodeCount: Int, currentNodeCount: Int) -> Bool {
        guard lastDuration > skipDurationThreshold, lastNodeCount > 0 else { return false }
        let growth = Double(currentNodeCount - lastNodeCount) / Double(lastNodeCount)
        return growth < skipGrowthThreshold
    }
}
