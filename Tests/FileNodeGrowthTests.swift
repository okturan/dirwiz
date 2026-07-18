import Testing
import Foundation
@testable import DirWizCore

/// Scaling regression for `FileTree.addChildren`'s capacity management.
///
/// `addChildren` is called once per directory during an immediate-mode scan. Before the fix
/// it ran `nodes.reserveCapacity(nodes.count + children.count)` on every call, collapsing
/// `Array`'s spare capacity to exactly the current count — so the next append reallocated and
/// copied the entire node array. That is O(n) per directory and O(n²) across a scan.
/// Reviewer's isolated measurement at 800k nodes over 160k small batches: 0.096s WITH the
/// exact-reserve pattern vs 0.001s WITHOUT — ~100×, quadratic in tree size. The fix reserves
/// geometrically (double when growth is needed), restoring amortized O(1) appends.
///
/// This test pins the *property*, not an absolute time: doubling the directory count must
/// roughly double the build time, not quadruple it. Under the reverted exact-reserve pattern
/// the ratio blows past the bound (quadratic ≈ 4×+); the geometric fix keeps it near linear
/// (≈ 2×). `.serialized` so the timing loop isn't fighting sibling tests in this suite for cores.
@Suite("FileNode Growth Tests", .serialized)
struct FileNodeGrowthTests {

    /// Files added per directory — a deliberately *small* per-call batch, the exact shape that
    /// defeats amortized growth under the old exact-reserve pattern.
    private static let filesPerDir = 3

    /// Build a tree with `directoryCount` sibling directories under the root, each populated by
    /// its own `addChildren` call carrying `filesPerDir` files — one per-directory batch per
    /// directory, matching how the immediate-mode scanner drives `addChildren`.
    ///
    /// Starts from a small-capacity tree (`stagingCapacityHint`) so the node array grows
    /// organically from the first batch; the default init's 500k-node reservation would
    /// otherwise mask the quadratic until the tree exceeded half a million nodes.
    private func buildTree(directoryCount: Int) -> FileTree {
        let tree = FileTree(stagingCapacityHint: 1024)
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "root")

        // One setup batch creates all the parent directories (a single call, O(n) for both sizes).
        var dirs: [(node: FileNode, name: String)] = []
        dirs.reserveCapacity(directoryCount)
        for _ in 0..<directoryCount {
            var dir = FileNode()
            dir.isDirectory = true
            dirs.append((node: dir, name: "d"))
        }
        tree.addChildren(dirs, parentIndex: 0)

        // The measured loop: one small addChildren per directory. Under the old pattern each
        // call reallocated and copied the whole (growing) array — the O(n²) this guards against.
        var files: [(node: FileNode, name: String)] = []
        files.reserveCapacity(Self.filesPerDir)
        for _ in 0..<Self.filesPerDir {
            var file = FileNode()
            file.fileSize = 1
            files.append((node: file, name: "f"))
        }
        for dirIndex in 1...directoryCount {
            tree.addChildren(files, parentIndex: UInt32(dirIndex))
        }
        return tree
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Best-of-`runs` minimum wall time to build a tree of `directoryCount` directories,
    /// stripping scheduler spikes from shared CI runners the same way
    /// `TreeTablePerformanceTests` does.
    private func minBuildSeconds(directoryCount: Int, runs: Int = 3) -> Double {
        let clock = ContinuousClock()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<runs {
            let start = clock.now
            let tree = buildTree(directoryCount: directoryCount)
            let elapsed = seconds(clock.now - start)
            // Assert the exact node count both to validate the build and to keep the tree
            // live across the measurement so the optimizer can't elide it.
            #expect(tree.count == 1 + directoryCount * (1 + Self.filesPerDir))
            best = min(best, elapsed)
        }
        return best
    }

    @Test("addChildren build time scales ~linearly with directory count, not quadratically")
    func buildTimeScalesLinearly() {
        let n = 50_000
        let twoN = 100_000

        // Warm code paths / allocator before timing.
        _ = buildTree(directoryCount: 1_000)

        let timeN = minBuildSeconds(directoryCount: n)
        let time2N = minBuildSeconds(directoryCount: twoN)

        // Linear growth ≈ 2×; the old exact-reserve pattern is quadratic ≈ 4×+ and blows past
        // this bound. 3× is a generous threshold that still cleanly separates the two regimes.
        #expect(
            time2N < 3 * timeN,
            """
            Expected ~linear scaling (2N < 3×N): \
            N=\(n) took \(timeN)s, 2N=\(twoN) took \(time2N)s (ratio \(time2N / timeN)).
            """
        )
    }
}
