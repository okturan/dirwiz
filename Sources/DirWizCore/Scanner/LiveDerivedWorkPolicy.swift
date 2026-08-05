import Foundation

/// When expensive DERIVED work may be repeated behind the living view.
///
/// A live splice already pays for what it must: re-enumerating the changed directories.
/// Everything downstream of it is derived, and re-running all of it on every ~10 second
/// apply is what made an idle-looking DirWiz burn CPU continuously in the background
/// (sampled live). The two offenders:
///
/// - `TreeCache.save` re-serializes the WHOLE tree and checksums it byte-at-a-time
///   (~220 MB for a 4.6M-item volume). Skipping a save is strictly safe: the previous
///   atomic cache and its older event id simply stay on disk, so the next launch replays
///   a wider journal window - which subtree rescan is idempotent under by design (plan
///   028/029). This only ever widens replay; it can never advance the horizon past work
///   that did not happen, so the cache-horizon invariant is untouched.
/// - The hardlink walk traverses every node to regroup by inode.
///
/// Pure and clock-injected, like `LiveRefreshPolicy` and `WarmStartPlanner`, so the
/// intervals are testable without waiting on wall time.
public enum LiveDerivedWorkPolicy {
    /// Cache writes exist to make the NEXT launch fast, not to be current. Two minutes
    /// of extra replay costs a fraction of a second at launch.
    public static let cacheSaveMinimumInterval: TimeInterval = 120

    /// Hardlink groups are path-keyed, so a slightly stale set still names real files.
    /// The tab forces a refresh when it is actually being looked at.
    public static let hardlinkRefreshMinimumInterval: TimeInterval = 120

    /// - Parameters:
    ///   - isNeededNow: the result is being displayed (or otherwise required) right now,
    ///     which always wins over the interval.
    public static func shouldRun(
        lastRunAt: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        minimumInterval: TimeInterval,
        isNeededNow: Bool = false
    ) -> Bool {
        if isNeededNow { return true }
        guard let lastRunAt else { return true }
        return now - lastRunAt >= minimumInterval
    }
}
