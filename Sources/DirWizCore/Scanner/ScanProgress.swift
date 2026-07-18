import Foundation
import Observation
import Synchronization

/// Observable scan state published by the file scanner.
/// Hot counters are updated from scanner background threads without triggering
/// @Observable notifications. Call `publishCounters()` on the main thread
/// at throttled intervals to sync to observable properties.
///
/// `@unchecked Sendable` safety: all cross-thread state (hot counters) is behind
/// a `Mutex`. Observable properties are only written on `@MainActor` via
/// `publishCounters()` / `reset()`. The scanner holds a reference but only
/// touches the Mutex-protected hot counters from background threads.
@Observable
public final class ScanProgress: @unchecked Sendable {
    // MARK: - Observable properties (read by SwiftUI, written only on main thread)

    public var isScanning: Bool = false
    public var filesScanned: Int = 0
    public var directoriesScanned: Int = 0
    public var totalSize: UInt64 = 0
    public var currentPath: String = ""
    public var elapsedTime: TimeInterval = 0
    public var scanComplete: Bool = false
    public var isCancelled: Bool = false
    public var error: String?
    public var estimatedTotalItems: Int = 0
    public var scannedAllocatedBytes: UInt64 = 0

    /// Directories that could not be read (permission denied or I/O error).
    public var skippedDirectories: Int = 0

    // MARK: - Hot counters (written from scanner threads, NOT observable)

    private struct HotCounters: Sendable {
        var files: Int = 0
        var dirs: Int = 0
        var totalSize: UInt64 = 0
        var allocatedBytes: UInt64 = 0
        var skipped: Int = 0
        var path: String = ""
        var publishCount: Int = 0
    }

    @ObservationIgnored private let hot = Mutex(HotCounters())

    /// One-way latch: set once `fractionCompleted` observes the estimate undershoot the
    /// actual count (more items scanned than predicted). Read/written only from
    /// `fractionCompleted` and `reset()`, both main-thread-only (see their `@MainActor`).
    @ObservationIgnored private var estimateUndershot = false

    /// Below this many items scanned, the estimate's plausibility is unknowable — matches
    /// 039's damping spirit (wait for a meaningful sample before trusting a signal).
    private static let minItemsForEstimate = 10_000

    /// Bumped every ~10 publishCounters() calls (≈2.5s) and once at scan end.
    /// Used as the treemap layout revision signal to avoid re-layout on every
    /// progress update (which would cancel in-flight layout tasks continuously).
    public private(set) var treeLayoutRevision: Int = 0

    public init() {}

    public var filesPerSecond: Double {
        guard elapsedTime > 0 else { return 0 }
        return Double(filesScanned) / elapsedTime
    }

    public var totalItems: Int {
        filesScanned + directoriesScanned
    }

    /// Progress fraction 0.0–1.0, or nil if the estimate can't be trusted right now.
    ///
    /// `estimatedTotalItems` comes from volume-root inode statistics, which only loosely
    /// correlate with the true item count on APFS — `BenchmarkTelemetry` measures this
    /// error per run, and it is routinely large. Trusting it blindly caused a real
    /// incident: the bar sat at "~50%" for a scan that was actually near done (the
    /// estimate had overshot the real total), making a stranded scan look merely slow.
    /// This computes bounded honesty instead of blind trust:
    ///
    /// - Below `minItemsForEstimate` items scanned, the estimate's quality is unknowable
    ///   this early — return nil (indeterminate) rather than a number nobody can vouch for.
    /// - While scanning, cap the result at 0.95: the bar keeps *moving* toward 95% but
    ///   never claims near-done on estimate authority alone. Completion is signaled by the
    ///   terminal state (`isScanning` flipping false), never by the estimate crossing 1.0.
    /// - If the raw fraction ever exceeds 1.0 (the estimate undershot — more items turned
    ///   up than predicted), the estimate has proven wrong for this scan: latch to
    ///   indeterminate for the remainder so it doesn't flap back and forth as counts climb.
    ///   `reset()` clears the latch for the next scan.
    @MainActor public var fractionCompleted: Double? {
        guard estimatedTotalItems > 0 else { return nil }
        let raw = Double(totalItems) / Double(estimatedTotalItems)

        guard isScanning else { return min(1.0, raw) }
        guard totalItems >= Self.minItemsForEstimate else { return nil }

        if raw > 1.0 {
            estimateUndershot = true
        }
        guard !estimateUndershot else { return nil }

        return min(0.95, raw)
    }

    @MainActor public func reset() {
        hot.withLock { counters in
            counters.files = 0
            counters.dirs = 0
            counters.totalSize = 0
            counters.allocatedBytes = 0
            counters.skipped = 0
            counters.path = ""
            counters.publishCount = 0
        }

        isScanning = false
        filesScanned = 0
        directoriesScanned = 0
        totalSize = 0
        currentPath = ""
        elapsedTime = 0
        scanComplete = false
        isCancelled = false
        error = nil
        estimatedTotalItems = 0
        scannedAllocatedBytes = 0
        skippedDirectories = 0
        treeLayoutRevision = 0
        estimateUndershot = false
    }

    /// Called from scanner background threads. Does NOT trigger @Observable.
    public func incrementFiles(count: Int = 1, size: UInt64 = 0, allocatedSize: UInt64 = 0) {
        hot.withLock { counters in
            counters.files += count
            counters.totalSize += size
            counters.allocatedBytes += allocatedSize
        }
    }

    /// Called from scanner background threads. Does NOT trigger @Observable.
    public func incrementDirectories(count: Int = 1) {
        hot.withLock { counters in
            counters.dirs += count
        }
    }

    /// Called from scanner background threads. Does NOT trigger @Observable.
    public func incrementSkippedDirectories(count: Int = 1) {
        hot.withLock { counters in
            counters.skipped += count
        }
    }

    /// Called from scanner background threads. Does NOT trigger @Observable.
    public func updateCurrentPath(_ path: String) {
        hot.withLock { counters in
            counters.path = path
        }
    }

    /// Sync hot counters to observable properties.
    /// Must be called on the main thread at throttled intervals.
    /// Pass `forceLayoutRevision: true` at scan completion to guarantee a final layout.
    @MainActor public func publishCounters(forceLayoutRevision: Bool = false) {
        let snapshot = hot.withLock { counters -> HotCounters in
            counters.publishCount += 1
            return counters
        }

        filesScanned = snapshot.files
        directoriesScanned = snapshot.dirs
        totalSize = snapshot.totalSize
        scannedAllocatedBytes = snapshot.allocatedBytes
        skippedDirectories = snapshot.skipped
        currentPath = snapshot.path

        // Bump layout revision every 10 publishes (≈2.5s) or when forced at scan end.
        // Early-churn guard (plan 039): with live tree building, the first bumps would
        // otherwise lay out a near-empty tree whose rectangles then violently reshuffle
        // as real content arrives. Suppress the periodic bump until the scan has *some*
        // shape to show — 1,000 files scanned (fast, file-dense volumes get a live map
        // almost immediately) or 20 publishes/≈5s elapsed (slow scans still get a bump
        // once something exists, rather than waiting on a files count that may never
        // arrive quickly). The completion force-bump is untouched so the final layout
        // always reflects the finished tree.
        let hasMeaningfulContent = snapshot.files >= 1_000 || snapshot.publishCount >= 20
        if (snapshot.publishCount % 10 == 0 && hasMeaningfulContent) || forceLayoutRevision {
            treeLayoutRevision &+= 1
        }
    }
}
