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

/// Plan 041: `fractionCompleted` must never sit at a fabricated fraction. The estimate
/// (`estimatedTotalItems`) is volume-root inode statistics — routinely wrong on APFS (the
/// user-reported incident: the bar read "~50%" for a near-done scan because the estimate
/// had overshot the real total). These tests pin the three honesty mechanisms: a floor
/// below which the estimate is too young to trust, a 0.95 cap so the bar never claims
/// near-done on estimate authority alone while still scanning, and a one-way latch that
/// gives up on the estimate entirely once it's caught undershooting (proven wrong, not just
/// imprecise).
@MainActor
@Suite("ScanProgress fractionCompleted honesty")
struct ScanProgressFractionHonestyTests {

    /// Below the floor, the estimate's quality is unknowable this early — nil regardless of
    /// how plausible the raw ratio looks. At/above the floor, with a sane (non-undershooting,
    /// non-cap-triggering) estimate, the true ratio is returned.
    @Test("nil below the floor; determinate above it with a sane estimate")
    func floorGatesEarlyEstimate() {
        let progress = ScanProgress()
        progress.isScanning = true
        progress.estimatedTotalItems = 100_000

        progress.filesScanned = 9_999
        #expect(progress.fractionCompleted == nil, "9,999 items is one below the 10,000 floor — must stay indeterminate")

        progress.filesScanned = 10_000
        #expect(progress.fractionCompleted == 0.1, "At the floor with a sane estimate, the true ratio (10,000/100,000) must show")

        progress.filesScanned = 30_000
        #expect(progress.fractionCompleted == 0.3, "Well above the floor, the true ratio must show")
    }

    /// Overshooting estimate (2x the eventual actual total): the raw ratio stays low for the
    /// whole scan by construction (bigger denominator), so it never approaches the 0.95 cap
    /// or crosses 1.0 — this is the user's original incident shape. Pin that the fraction
    /// still moves as counts rise (it is not stuck), and that the terminal state (scan
    /// complete) reports the same true ratio rather than something the cap/latch distorts.
    @Test("Overshooting estimate: fraction moves and completion reports the true ratio")
    func overshootingEstimateStillMovesAndCompletes() {
        let progress = ScanProgress()
        progress.isScanning = true
        progress.estimatedTotalItems = 40_000 // true final total will be 20,000 — a 2x overshoot

        progress.filesScanned = 12_000
        #expect(progress.fractionCompleted == 0.3)

        progress.filesScanned = 16_000
        #expect(progress.fractionCompleted == 0.4, "Fraction must move upward as counts rise, never sit still")

        progress.filesScanned = 20_000 // scan finished at its true total
        progress.isScanning = false
        #expect(progress.fractionCompleted == 0.5, "Completion must report the true ratio (20,000/40,000), unmangled by the cap or latch")
    }

    /// Cap: as the raw ratio approaches 1.0 while still scanning (an estimate that turns out
    /// to be roughly accurate, or a slight undershoot short of the 1.0 latch threshold), the
    /// displayed fraction never exceeds 0.95 — it holds there rather than flapping upward
    /// with every tick. Once the scan actually completes, the true (uncapped) ratio is shown.
    @Test("Cap holds the displayed fraction at 0.95 pre-completion; completion overrides it")
    func capHoldsAt095UntilCompletion() {
        let progress = ScanProgress()
        progress.isScanning = true
        progress.estimatedTotalItems = 100_000

        progress.filesScanned = 97_000 // raw 0.97
        #expect(progress.fractionCompleted == 0.95, "Raw 0.97 must be capped to 0.95 while still scanning")

        progress.filesScanned = 99_000 // raw 0.99 — still short of the 1.0 undershoot latch
        #expect(progress.fractionCompleted == 0.95, "Cap must hold at 0.95, not creep up with raw")

        progress.isScanning = false // scan completes with the same counts
        #expect(progress.fractionCompleted == 0.99, "Completion must report the true ratio (0.99), not the pre-completion cap")
    }

    /// Undershooting estimate: once the raw ratio crosses 1.0 (more items scanned than the
    /// estimate predicted), the estimate has proven wrong for this scan — latch to
    /// indeterminate for the remainder, even as counts keep climbing well past the estimate,
    /// rather than flapping back to determinate.
    @Test("Undershooting estimate: crossing 1.0 latches to nil and never flaps back")
    func undershootingEstimateLatchesToNil() {
        let progress = ScanProgress()
        progress.isScanning = true
        progress.estimatedTotalItems = 50_000

        progress.filesScanned = 45_000 // raw 0.9 — still below both the cap-visible zone and 1.0
        #expect(progress.fractionCompleted == 0.9)

        progress.filesScanned = 51_000 // raw 1.02 — crosses 1.0, latch trips
        #expect(progress.fractionCompleted == nil, "Crossing 1.0 must latch to indeterminate")

        progress.filesScanned = 60_000 // counts keep rising well past the estimate
        #expect(progress.fractionCompleted == nil, "Latch must hold — no flapping back to determinate as counts keep climbing")
    }

    /// The latch is scoped to one scan: `reset()` (called at the start of every new scan)
    /// must clear it so the next scan's estimate gets a fair, un-latched evaluation.
    @Test("reset() clears the undershoot latch for the next scan")
    func resetClearsLatch() {
        let progress = ScanProgress()
        progress.isScanning = true
        progress.estimatedTotalItems = 10_000
        progress.filesScanned = 11_000 // raw 1.1 — trips the latch
        #expect(progress.fractionCompleted == nil)

        progress.reset()

        progress.isScanning = true
        progress.estimatedTotalItems = 100_000
        progress.filesScanned = 20_000 // raw 0.2, well-formed — must not still be latched from the prior scan
        #expect(progress.fractionCompleted == 0.2, "A fresh scan after reset() must not inherit the previous scan's latch")
    }
}
