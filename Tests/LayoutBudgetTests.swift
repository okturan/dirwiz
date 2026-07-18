import Testing
import Foundation
import CoreGraphics
@testable import DirWizCore
@testable import DirWizUI

// MARK: - Depth-limit + adaptive-skip unit tests (fast, no I/O)

/// Plan 044: pins the scan-time layout budget — a depth cutoff (`SquarifyLayout`'s
/// existing but previously-untested `maxDepth` parameter) plus an adaptive skip
/// (`ScanTimeLayoutBudget`) that keeps scan-time treemap relayouts cheap while a scan is
/// building the tree live. The completion layout and all post-scan interaction layouts
/// are unaffected — always full-depth, never skipped.
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

    @Test("Adaptive skip never fires before any scan-time layout has run")
    func neverSkipsWithoutPriorTiming() {
        #expect(!ScanTimeLayoutBudget.shouldSkip(lastDuration: 0, lastNodeCount: 0, currentNodeCount: 1_000))
    }

    @Test("Adaptive skip never fires when the previous layout was cheap, regardless of growth")
    func neverSkipsWhenPreviousLayoutWasCheap() {
        #expect(!ScanTimeLayoutBudget.shouldSkip(lastDuration: 0.05, lastNodeCount: 10_000, currentNodeCount: 10_001))
    }

    @Test("Adaptive skip never fires once the tree has grown enough since the last layout")
    func neverSkipsAfterSufficientGrowth() {
        // 30% growth clears the 25% bar even though the previous layout was expensive.
        #expect(!ScanTimeLayoutBudget.shouldSkip(lastDuration: 0.2, lastNodeCount: 10_000, currentNodeCount: 13_000))
    }

    @Test("Adaptive skip fires when the previous layout was expensive and the tree barely grew")
    func skipsWhenExpensiveAndBarelyGrown() {
        // 10% growth stays under the 25% bar.
        #expect(ScanTimeLayoutBudget.shouldSkip(lastDuration: 0.2, lastNodeCount: 10_000, currentNodeCount: 11_000))
    }

    @Test("Boundary: exactly the duration threshold is not yet 'expensive'")
    func exactDurationThresholdIsNotExpensive() {
        #expect(!ScanTimeLayoutBudget.shouldSkip(
            lastDuration: ScanTimeLayoutBudget.skipDurationThreshold,
            lastNodeCount: 10_000,
            currentNodeCount: 10_500))
    }

    @Test("Boundary: exactly the growth threshold counts as sufficient growth")
    func exactGrowthThresholdIsSufficientGrowth() {
        let lastCount = 10_000
        let currentCount = Int(Double(lastCount) * (1 + ScanTimeLayoutBudget.skipGrowthThreshold))
        #expect(!ScanTimeLayoutBudget.shouldSkip(lastDuration: 0.5, lastNodeCount: lastCount, currentNodeCount: currentCount))
    }
}

// MARK: - Timing gate (Plan 044, Design 3) — the HARD gate

private enum ScanTimeLayoutLoopMode {
    case old   // pre-change: full-depth squarify every tick, never skipped
    case new   // depth-limited + adaptively skipped
}

/// Build a real on-disk fixture with enough depth and breadth to exercise both the depth
/// cutoff (needs more than `ScanTimeLayoutBudget.scanTimeMaxDepth` directory levels) and
/// realistic squarify cost (~150-200k total nodes, per the plan). 4 directory levels
/// (12-way branching) beneath the root, 7 files in each deepest directory:
/// 12 + 144 + 1,728 + 20,736 = 22,620 dirs, 20,736 * 7 = 145,152 files, plus the root —
/// 167,773 nodes total. Uses raw POSIX calls (not `FileManager`/`Data.write`) — this
/// creates ~168k filesystem entries and needs to stay fast enough for a test.
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
/// harder than real scans ever will. Returns the scan's wall-clock duration in seconds.
private func timedLayoutBudgetScan(root: String, layoutLoop: ScanTimeLayoutLoopMode?) async -> TimeInterval {
    let scanner = FileScanner(computeBundleSizes: false, deferTreeMaterialization: false)
    let progress = ScanProgress()
    let tree = FileTree()
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    var loopTask: Task<Void, Never>?
    if let layoutLoop {
        loopTask = Task.detached(priority: .userInitiated) {
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
                case .new:
                    let currentCount = tree.count
                    if ScanTimeLayoutBudget.shouldSkip(
                        lastDuration: lastDuration, lastNodeCount: lastNodeCount, currentNodeCount: currentCount
                    ) {
                        continue
                    }
                    let snapshot = tree.nodesSnapshot()
                    guard !snapshot.isEmpty else { continue }
                    let layoutStart = CFAbsoluteTimeGetCurrent()
                    _ = SquarifyLayout.layout(
                        nodes: snapshot, rootIndex: 0, bounds: bounds,
                        maxDepth: ScanTimeLayoutBudget.scanTimeMaxDepth, minPixelSize: 1.0
                    )
                    lastDuration = CFAbsoluteTimeGetCurrent() - layoutStart
                    lastNodeCount = snapshot.count
                }
            }
        }
    }

    let start = CFAbsoluteTimeGetCurrent()
    await scanner.scan(path: root, progress: progress, tree: tree)
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    loopTask?.cancel()
    _ = await loopTask?.value
    return elapsed
}

@Suite("Layout Budget Timing Gate", .serialized)
struct LayoutBudgetTimingGateTests {

    /// HARD gate (Plan 044, Design 3): scan wall time under the NEW scan-time layout
    /// behavior (depth-limited + adaptively skipped) must stay within 1.15x of the honest
    /// no-layout-loop baseline — even under a synthetic UI loop stress-testing at a much
    /// more aggressive 250ms cadence than real scans see. Reports all three numbers
    /// (no-layout / old-behavior / new-behavior) for the report, per the plan's
    /// maintenance notes.
    @Test("Scan wall time with the new scan-time layout budget stays within 1.15x of no-layout",
          .timeLimit(.minutes(10)))
    func newBehaviorStaysWithinBudget() async throws {
        let (root, cleanup) = try makeLayoutBudgetTimingFixture()
        defer { cleanup() }

        // Warm the OS file cache so all three timed runs see comparable I/O cost — this
        // is a ratio on the same machine in the same process, so cache-state parity
        // across the three configurations matters more than the absolute numbers.
        _ = await timedLayoutBudgetScan(root: root, layoutLoop: nil)

        let noLayoutSeconds = await timedLayoutBudgetScan(root: root, layoutLoop: nil)
        let oldBehaviorSeconds = await timedLayoutBudgetScan(root: root, layoutLoop: .old)
        let newBehaviorSeconds = await timedLayoutBudgetScan(root: root, layoutLoop: .new)

        let budget = noLayoutSeconds * 1.15
        let report = """
        [Plan 044 timing gate] no-layout: \(noLayoutSeconds)s | \
        old-behavior: \(oldBehaviorSeconds)s | new-behavior: \(newBehaviorSeconds)s | \
        budget (1.15x no-layout): \(budget)s
        """
        print(report)

        #expect(newBehaviorSeconds <= budget, "\(report) — new-behavior exceeded the 1.15x no-layout budget")
    }
}
