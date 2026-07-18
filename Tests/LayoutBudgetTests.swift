import Testing
import Foundation
import CoreGraphics
import Synchronization
@testable import DirWizCore
@testable import DirWizUI

// MARK: - Depth-limit + sparsity-gate unit tests (fast, no I/O)

/// Plan 044: pins the scan-time layout budget — a depth cutoff (`SquarifyLayout`'s
/// existing but previously-untested `maxDepth` parameter, SECONDARY/insurance) plus a
/// sparsity gate (`ScanTimeLayoutBudget.shouldRunScanTimeLayout`, PRIMARY) that keeps
/// scan-time treemap relayouts rare and cheap while a scan is building the tree live. The
/// completion layout and all post-scan interaction layouts are unaffected — always
/// full-depth, never skipped.
@Suite("Layout Budget Tests")
struct LayoutBudgetTests {

    /// Hand-built 5-level-deep chain: root -> d1 -> d2 -> d3 -> d4 -> leaf.txt.
    /// Depths: root=0, d1=1, d2=2, d3=3, d4=4, leaf=5.
    private func makeDeepChain() -> FileTree {
        let tree = FileTree()
        var root = FileNode()
        root.isDirectory = true
        root.fileSize = 100
        tree.addNode(root, name: "root")

        var parent: UInt32 = 0
        for name in ["d1", "d2", "d3", "d4"] {
            var dir = FileNode()
            dir.isDirectory = true
            dir.fileSize = 100
            parent = tree.addChildren([(node: dir, name: name)], parentIndex: parent)
        }

        var file = FileNode()
        file.fileSize = 100
        file.extensionHash = extensionHash("leaf.txt")
        tree.addChildren([(node: file, name: "leaf.txt")], parentIndex: parent)
        return tree
    }

    @Test("maxDepth cuts off recursion: nothing past the cutoff depth is ever emitted")
    func maxDepthCutsOffDeepRecursion() {
        let tree = makeDeepChain()
        let nodes = tree.nodesSnapshot()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let leafIndex: UInt32 = 5 // root=0, d1=1, d2=2, d3=3, d4=4, leaf=5

        let limited = SquarifyLayout.layout(nodes: nodes, rootIndex: 0, bounds: bounds, maxDepth: 4, minPixelSize: 1.0)
        let unlimited = SquarifyLayout.layout(nodes: nodes, rootIndex: 0, bounds: bounds, maxDepth: 20, minPixelSize: 1.0)

        #expect(!limited.contains { $0.depth > 4 },
            "Nothing past the cutoff depth (4) may appear when maxDepth is 4")
        #expect(!limited.contains { $0.nodeIndex == leafIndex },
            "The leaf file must never be emitted once its parent directory (d4, at the cutoff depth) is cut off")
        #expect(limited.contains { $0.nodeIndex == 4 },
            "d4 itself must still be emitted, as the cutoff rect, standing in for everything beneath it")

        #expect(unlimited.contains { $0.nodeIndex == leafIndex && !$0.isBackground },
            "With maxDepth 20 (unlimited for this tree), the leaf must be laid out as its own visible rect at depth 5")

        // The cutoff must not alter geometry for the levels it DOES lay out — d4 occupies
        // the same rect in both runs, whether drawn as a standalone cutoff rect (limited)
        // or as the background beneath its recursed-into child (unlimited).
        let limitedD4 = limited.first { $0.nodeIndex == 4 }
        let unlimitedD4 = unlimited.first { $0.nodeIndex == 4 }
        #expect(limitedD4?.x == unlimitedD4?.x)
        #expect(limitedD4?.y == unlimitedD4?.y)
        #expect(limitedD4?.width == unlimitedD4?.width)
        #expect(limitedD4?.height == unlimitedD4?.height)
    }

    @Test("ScanTimeLayoutBudget.maxDepth is depth-limited while scanning, unlimited once scanning ends")
    func maxDepthTracksScanState() {
        #expect(ScanTimeLayoutBudget.maxDepth(isScanning: true) == ScanTimeLayoutBudget.scanTimeMaxDepth)
        #expect(ScanTimeLayoutBudget.maxDepth(isScanning: false) == ScanTimeLayoutBudget.unlimitedDepth)
    }

    @Test("Sparsity gate always allows the first scan-time layout of a scan")
    func alwaysAllowsFirstLayout() {
        #expect(ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: nil, lastLayoutDuration: 0, lastNodeCount: 0, currentNodeCount: 100))
        // nil elapsed means "no scan-time layout has run yet this scan" — always allowed
        // regardless of how implausible the other recorded values look.
        #expect(ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: nil, lastLayoutDuration: 999, lastNodeCount: 999_999, currentNodeCount: 1))
    }

    @Test("Sparsity gate blocks a relayout before the minimum interval floor elapses, even with ample growth")
    func blocksBeforeMinimumInterval() {
        #expect(!ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: 3, lastLayoutDuration: 0.01, lastNodeCount: 1_000, currentNodeCount: 2_000))
    }

    @Test("Sparsity gate allows a relayout once the interval floor elapses and growth clears the bar")
    func allowsAfterFloorAndGrowth() {
        #expect(ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: 6, lastLayoutDuration: 0.01, lastNodeCount: 1_000, currentNodeCount: 1_300))
    }

    @Test("Sparsity gate blocks a relayout past the interval floor if growth hasn't cleared the bar")
    func blocksWhenGrowthInsufficient() {
        #expect(!ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: 6, lastLayoutDuration: 0.01, lastNodeCount: 1_000, currentNodeCount: 1_100))
    }

    @Test("A slow previous layout extends the required interval beyond the minimum floor")
    func slowPreviousLayoutExtendsInterval() {
        // lastLayoutDuration 2s -> required interval = max(5, 4*2) = 8s.
        #expect(!ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: 6, lastLayoutDuration: 2.0, lastNodeCount: 1_000, currentNodeCount: 2_000),
            "6s elapsed is short of the 8s required after a 2s-long previous layout")
        #expect(ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: 9, lastLayoutDuration: 2.0, lastNodeCount: 1_000, currentNodeCount: 2_000),
            "9s elapsed clears the 8s required interval, and growth is well past the bar")
    }

    @Test("Boundary: exactly the required interval, with exactly the growth threshold, is allowed")
    func exactBoundariesAreAllowed() {
        let lastCount = 10_000
        let currentCount = Int(Double(lastCount) * (1 + ScanTimeLayoutBudget.minGrowthFraction))
        #expect(ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: ScanTimeLayoutBudget.minLayoutInterval,
            lastLayoutDuration: 0, lastNodeCount: lastCount, currentNodeCount: currentCount))
    }

    @Test("No growth baseline (defensive — duration/count are always recorded together in practice) still allows")
    func noGrowthBaselineAllows() {
        #expect(ScanTimeLayoutBudget.shouldRunScanTimeLayout(
            elapsedSinceLastLayout: 10, lastLayoutDuration: 0, lastNodeCount: 0, currentNodeCount: 500))
    }
}

// MARK: - Timing gate (Plan 044, Design 3) — the HARD gate

private enum ScanTimeLayoutLoopMode {
    case old   // pre-change: full-depth squarify on every 250ms tick, never skipped
    case new   // sparsity-gated (PRIMARY) + depth-limited (SECONDARY) when it does run
}

/// Build a real on-disk fixture with enough depth and breadth to exercise both the depth
/// cutoff (needs more than `ScanTimeLayoutBudget.scanTimeMaxDepth` directory levels) and
/// realistic squarify cost (~150-200k total nodes, per the plan). 4 directory levels
/// (12-way branching) beneath the root, 7 files in each deepest directory:
/// 12 + 144 + 1,728 + 20,736 = 22,620 dirs, 20,736 * 7 = 145,152 files, plus the root —
/// 167,773 nodes total. Uses raw POSIX calls (not `FileManager`/`Data.write`) — this
/// creates ~168k filesystem entries and needs to stay fast enough for a test.
///
/// Deliberately kept at this size rather than scaled up to force a longer scan — see
/// `LayoutBudgetTimingGateTests`'s doc comment for why a longer CI-safe scan doesn't
/// actually help here, and plan 044's report for a separate finding (out of this plan's
/// scope) that `FileTree.addChildren`'s cost tracks DIRECTORY count more than total node
/// count: growing `dirLevels` here to force more addChildren calls turned a fast fixture
/// into a multi-minute one, while growing `filesPerLeafDir` alone (same call count, more
/// nodes per call) scaled roughly linearly.
private func makeLayoutBudgetTimingFixture() throws -> (path: String, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DirWizLayoutBudgetFixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let branching = 12
    let dirLevels = 4
    let filesPerLeafDir = 7

    func mkdirAt(_ path: String) {
        _ = path.withCString { mkdir($0, 0o755) }
    }

    func touchFile(_ path: String) {
        let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        if fd >= 0 { close(fd) }
    }

    func build(at path: String, level: Int) {
        if level == dirLevels {
            for f in 0..<filesPerLeafDir {
                touchFile("\(path)/f\(f).dat")
            }
            return
        }
        for i in 0..<branching {
            let childPath = "\(path)/L\(level)_\(i)"
            mkdirAt(childPath)
            build(at: childPath, level: level + 1)
        }
    }

    build(at: root.path, level: 0)

    return (root.path, { try? FileManager.default.removeItem(at: root) })
}

/// Runs one full immediate-mode scan of `root` (live tree materialization — matches the
/// app's default, see `AppState+Scan.appDefersTreeMaterialization`), optionally with a
/// concurrent task simulating the treemap's UI relayout loop. The loop wakes every 250ms —
/// `FileScanner`'s own progress-publish throttle interval — deliberately more aggressive
/// than production's ~2.5s `treeLayoutRevision` bump cadence, stress-testing the budget
/// harder than real scans ever will. Returns the scan's wall-clock duration in seconds and
/// the number of squarify passes actually run (diagnostic — reported for calibration).
private func timedLayoutBudgetScan(root: String, layoutLoop: ScanTimeLayoutLoopMode?) async -> (seconds: TimeInterval, layoutsRun: Int) {
    let scanner = FileScanner(computeBundleSizes: false, deferTreeMaterialization: false)
    let progress = ScanProgress()
    let tree = FileTree()
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let layoutsRunCounter = Mutex(0)

    var loopTask: Task<Void, Never>?
    if let layoutLoop {
        loopTask = Task.detached(priority: .userInitiated) {
            var lastCompletedAt: CFAbsoluteTime?
            var lastDuration: TimeInterval = 0
            var lastNodeCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { break }

                switch layoutLoop {
                case .old:
                    let snapshot = tree.nodesSnapshot()
                    guard !snapshot.isEmpty else { continue }
                    _ = SquarifyLayout.layout(
                        nodes: snapshot, rootIndex: 0, bounds: bounds,
                        maxDepth: ScanTimeLayoutBudget.unlimitedDepth, minPixelSize: 1.0
                    )
                    layoutsRunCounter.withLock { $0 += 1 }
                case .new:
                    let currentCount = tree.count
                    let elapsed = lastCompletedAt.map { CFAbsoluteTimeGetCurrent() - $0 }
                    guard ScanTimeLayoutBudget.shouldRunScanTimeLayout(
                        elapsedSinceLastLayout: elapsed, lastLayoutDuration: lastDuration,
                        lastNodeCount: lastNodeCount, currentNodeCount: currentCount
                    ) else { continue }
                    let snapshot = tree.nodesSnapshot()
                    guard !snapshot.isEmpty else { continue }
                    let layoutStart = CFAbsoluteTimeGetCurrent()
                    _ = SquarifyLayout.layout(
                        nodes: snapshot, rootIndex: 0, bounds: bounds,
                        maxDepth: ScanTimeLayoutBudget.scanTimeMaxDepth, minPixelSize: 1.0
                    )
                    lastCompletedAt = CFAbsoluteTimeGetCurrent()
                    lastDuration = lastCompletedAt! - layoutStart
                    lastNodeCount = snapshot.count
                    layoutsRunCounter.withLock { $0 += 1 }
                }
            }
        }
    }

    let start = CFAbsoluteTimeGetCurrent()
    await scanner.scan(path: root, progress: progress, tree: tree)
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    loopTask?.cancel()
    _ = await loopTask?.value
    return (elapsed, layoutsRunCounter.withLock { $0 })
}

@Suite("Layout Budget Timing Gate", .serialized)
struct LayoutBudgetTimingGateTests {

    /// The fixture's scan is sub-second, so a single measurement is noisy under ambient
    /// swift-testing parallel load (`.serialized` only serializes this suite's own tests
    /// against each other — it does nothing to stop OTHER suites from running
    /// concurrently, per `TestHelpers.swift`'s `AppSupportEnvSuites` doc). Taking the
    /// MINIMUM across several trials estimates each configuration's unloaded cost, since
    /// external contention can only add delay, never subtract it.
    private static let trialCount = 15

    private enum Configuration: CaseIterable {
        case noLayout, old, new
    }

    /// HARD gate (Plan 044, Design 3). The reviewer asked to tighten this to 1.07x (from
    /// 1.15x) to match a ~20s-scan target where the sparsity gate suppresses most
    /// would-be layouts. That target is NOT reachable by THIS test, and the gap is
    /// structural, not a flaw in the fix — reported here rather than silently reverted:
    ///
    /// `shouldRunScanTimeLayout` always allows a scan's FIRST scan-time layout
    /// unconditionally (so a scan shows something live promptly). On a real multi-second
    /// scan that first look lands early, while the tree is still small, so it's cheap; on
    /// THIS fixture the entire scan finishes in ~0.3s — faster than one 250ms tick — so
    /// the "first" layout is actually a layout of the essentially-COMPLETE tree, and its
    /// cost (empirically ~7-15% of total scan time here) is indistinguishable from
    /// old-behavior's, because both old and new run exactly one pass in a scan this
    /// short. No amount of repeated trials or fixture scaling fixes this: scan time and
    /// per-pass squarify cost scale together, so the ratio floor stays roughly constant
    /// across fixture sizes as long as the scan stays under `minLayoutInterval` (5s) —
    /// confirmed empirically at 2x and 5x this fixture's size. Only a scan genuinely
    /// lasting several-to-tens of seconds lets sparsity suppress enough SUBSEQUENT
    /// layouts for the ratio to approach 1.0x; see the plan 044 report for a release-build
    /// measurement at that scale. Kept here at 1.15x (the original plan's own budget,
    /// reliably achievable at this fixture size across repeated runs including under
    /// full-suite parallel contention) rather than committing a test that coin-flips
    /// between pass/fail at 1.07x — the reviewer should decide whether the CI gate needs a
    /// genuinely long-running fixture instead (with the build-time tradeoffs that implies)
    /// or whether 1.15x here plus a release-build check at realistic scale is sufficient.
    /// Reports all three best-of-N numbers (no-layout / old-behavior / new-behavior) plus
    /// how many squarify passes each configuration ran on its best trial, for the report.
    @Test("Scan wall time with the new scan-time layout budget stays within 1.15x of no-layout (best-of-N)",
          .timeLimit(.minutes(10)))
    func newBehaviorStaysWithinBudget() async throws {
        let (root, cleanup) = try makeLayoutBudgetTimingFixture()
        defer { cleanup() }

        // Warm the OS file cache before any timed trial — this is a ratio on the same
        // machine in the same process, so cache-state parity matters more than absolute
        // numbers.
        _ = await timedLayoutBudgetScan(root: root, layoutLoop: nil)

        var results: [Configuration: [(seconds: TimeInterval, layoutsRun: Int)]] = [
            .noLayout: [], .old: [], .new: []
        ]
        let order = Configuration.allCases

        for round in 0..<Self.trialCount {
            // Rotate which configuration runs first/middle/last each round, so a
            // systematic drift in ambient load across the whole run (e.g. rising thermal
            // throttling, another suite ramping up) can't systematically favor or
            // penalize any one configuration by always landing at the same position.
            for offset in 0..<order.count {
                let config = order[(offset + round) % order.count]
                switch config {
                case .noLayout: results[.noLayout]!.append(await timedLayoutBudgetScan(root: root, layoutLoop: nil))
                case .old: results[.old]!.append(await timedLayoutBudgetScan(root: root, layoutLoop: .old))
                case .new: results[.new]!.append(await timedLayoutBudgetScan(root: root, layoutLoop: .new))
                }
            }
        }

        let noLayoutMin = results[.noLayout]!.map(\.seconds).min()!
        let oldMin = results[.old]!.map(\.seconds).min()!
        let newMin = results[.new]!.map(\.seconds).min()!
        let oldLayoutsRun = results[.old]!.map(\.layoutsRun).max() ?? 0
        let newLayoutsRun = results[.new]!.map(\.layoutsRun).max() ?? 0

        let budget = noLayoutMin * 1.15
        let report = """
        [Plan 044 timing gate] best-of-\(Self.trialCount): \
        no-layout: \(noLayoutMin)s | old-behavior: \(oldMin)s (\(oldLayoutsRun) layouts) | \
        new-behavior: \(newMin)s (\(newLayoutsRun) layouts) | budget (1.15x no-layout): \(budget)s
        """
        print(report)

        #expect(newMin <= budget, "\(report) — new-behavior exceeded the 1.15x no-layout budget")
    }
}
