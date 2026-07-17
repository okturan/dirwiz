import Testing
import Foundation
@testable import DirWizCore

/// Pins the early-churn damping boundary added in plan 039: with the tree building live
/// during a cold scan, the first periodic layout-revision bumps would otherwise lay out a
/// near-empty tree whose rectangles then violently reshuffle as real content arrives.
/// `ScanProgress.publishCounters` suppresses the every-10th bump until the scan has
/// `filesScanned >= 1_000` OR `publishCount >= 20` (≈5s at the ~250ms publish cadence) —
/// whichever comes first, so a fast/file-dense scan gets a live map almost immediately and
/// a slow scan still gets one once it's been running a while. The completion force-bump
/// (`forceLayoutRevision: true`) is untouched and must always fire.
@MainActor
@Suite("ScanProgress Tests")
struct ScanProgressTests {

    /// Below both thresholds (few files, few publishes): the every-10th bump stays
    /// suppressed through the first 10 publishes.
    @Test("Periodic bump suppressed before either threshold is reached")
    func periodicBumpSuppressedBeforeThreshold() {
        let progress = ScanProgress()
        for _ in 1...10 {
            progress.incrementFiles(count: 5) // 50 files total after 10 calls — well under 1,000
            progress.publishCounters()
        }
        #expect(progress.treeLayoutRevision == 0,
            "10th publish with few files and publishCount == 10 must not bump (needs publishCount >= 20 or files >= 1,000)")
    }

    /// The publishCount >= 20 branch: a slow scan that never accumulates many files still
    /// gets a bump once enough time (publishes) has passed.
    @Test("Periodic bump fires once publishCount reaches 20, even with few files")
    func periodicBumpFiresAtPublishCountBoundary() {
        let progress = ScanProgress()
        for _ in 1...20 {
            progress.incrementFiles(count: 5) // 100 files total — still under 1,000
            progress.publishCounters()
        }
        #expect(progress.treeLayoutRevision == 1,
            "20th publish must bump even though files stayed under 1,000")
    }

    /// The filesScanned >= 1,000 branch: a fast, file-dense scan gets a live map on the
    /// very first periodic checkpoint (10th publish) rather than waiting for 20 publishes.
    @Test("Periodic bump fires at the 10th publish once filesScanned reaches 1,000")
    func periodicBumpFiresEarlyWithMeaningfulFileCount() {
        let progress = ScanProgress()
        progress.incrementFiles(count: 1_000)
        for _ in 1...10 {
            progress.publishCounters()
        }
        #expect(progress.treeLayoutRevision == 1,
            "10th publish must bump once filesScanned >= 1,000, without waiting for publishCount >= 20")
    }

    /// Pin the exact numeric boundary: 999 files at the 10th publish is not enough.
    @Test("999 files at the 10th publish is below the meaningful-content boundary")
    func justBelowFileCountBoundaryStaysSuppressed() {
        let progress = ScanProgress()
        progress.incrementFiles(count: 999)
        for _ in 1...10 {
            progress.publishCounters()
        }
        #expect(progress.treeLayoutRevision == 0, "999 files must not satisfy the 1,000-file threshold")
    }

    /// The completion force-bump is unconditional: even at publish 1, with zero files
    /// scanned, `forceLayoutRevision: true` must bump immediately.
    @Test("forceLayoutRevision bumps unconditionally regardless of the damping guard")
    func forceLayoutRevisionAlwaysBumps() {
        let progress = ScanProgress()
        progress.publishCounters(forceLayoutRevision: true)
        #expect(progress.treeLayoutRevision == 1, "Forced bump must fire on the very first publish with no content yet")
    }
}
