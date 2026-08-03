import Testing
import Foundation
@testable import DirWizCore

/// Shallow-parent splicing: file-derived targets are scoped to one entry level instead
/// of their whole subtree. These gates pin the collapse rules, the honest estimates,
/// the in-place reconcile, promotion, root-level handling, and - non-negotiably - that
/// every outcome remains indistinguishable from a fresh cold scan.
@Suite("Shallow Parent Splice Tests")
struct ShallowParentSpliceTests {

    private func coldScan(_ path: String) async -> FileTree {
        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)
        return tree
    }

    // MARK: - Collapse and planning

    @Test("A shallow root never claims the precise deep targets beneath it")
    func shallowRootsClaimNothing() {
        // Deep ancestor still swallows everything under it.
        #expect(PathCollapse.outermostRoots(["/a", "/a/b/c"], shallow: []) == ["/a"])
        // Shallow ancestor keeps nested deep targets alive.
        #expect(PathCollapse.outermostRoots(["/a", "/a/b/c", "/a/d"], shallow: ["/a"])
                == ["/a", "/a/b/c", "/a/d"])
        // Nested shallow targets are each one disjoint level of work - both survive.
        #expect(Set(PathCollapse.outermostRoots(["/a/b", "/a", "/a/b/c"],
                                                shallow: ["/a", "/a/b", "/a/b/c"]))
                == Set(["/a", "/a/b", "/a/b/c"]))
        // A deep ancestor claims shallow descendants: full staging covers their level.
        #expect(PathCollapse.outermostRoots(["/a", "/a/b"], shallow: ["/a/b"]) == ["/a"])
        // Exact duplicates still dedupe.
        #expect(PathCollapse.outermostRoots(["/a", "/a"], shallow: ["/a"]) == ["/a"])
    }

    @Test("The estimator charges a shallow root its level, not its subtree")
    func estimatorChargesShallowLevel() async throws {
        let (root, cleanup) = try createTempTree([
            "big/file1.txt": 100,
            "big/sub/deep1.txt": 200,
            "big/sub/deep2.txt": 300,
            "other/x.txt": 50,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        let deep = WarmStartPlanner.estimatedPatchItemCounts(
            forChangedPaths: [root + "/big"], cachedTree: tree)
        let shallow = WarmStartPlanner.estimatedPatchItemCounts(
            forChangedPaths: [root + "/big"], cachedTree: tree,
            shallowTargets: [root + "/big"])
        // Deep: big + file1 + sub + deep1 + deep2 territory; shallow: big's two entries.
        let deepEstimate = try #require(deep.values.first)
        let shallowEstimate = try #require(shallow.values.first)
        #expect(shallowEstimate == 2)
        #expect(deepEstimate > shallowEstimate)
    }

    @Test("The incident shape is admitted warm once estimates are honest")
    func incidentShapeAdmitsWarm() {
        // A `.DS_Store`-blamed home folder (shallow, ~200 entries) plus real deep churn
        // far below the 25% gate - this exact shape used to read as "~92% changed".
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(["/Users/okan", "/Users/okan/code/proj/.build"]),
            cachedDirectoryCount: 400_000,
            cachedTotalItemCount: 4_500_000,
            estimatedPatchItems: 250_000,
            shallowTargets: ["/Users/okan"]
        )
        #expect(decision == .warm(targets: ["/Users/okan", "/Users/okan/code/proj/.build"]))

        // A genuine mass change still refuses through the unchanged fraction gate.
        let mass = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(["/Users/okan", "/Users/okan/code/proj/.build"]),
            cachedDirectoryCount: 400_000,
            cachedTotalItemCount: 4_500_000,
            estimatedPatchItems: 4_200_000,
            shallowTargets: ["/Users/okan"]
        )
        #expect(mass == .coldFallback(reason: "~93% of files changed since last scan"))
    }

    // MARK: - Shallow reconcile equivalence

    @Test("A metadata-only shallow patch equals cold and never descends")
    func metadataOnlyShallowEqualsCold() async throws {
        let (root, cleanup) = try createTempTree([
            "big/file1.txt": 100,
            "big/sub/deep1.txt": 200,
            "big/sub/deep2.txt": 300,
            "other/x.txt": 50,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        // The reported change: a file directly inside big/ grew.
        try Data(count: 4096).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/file1.txt"))
        // Deliberately UNREPORTED deep sentinel: a full-subtree rescan of big/ would
        // absorb it; a one-level reconcile must not.
        let sentinel = URL(fileURLWithPath: root).appendingPathComponent("big/sub/sentinel.txt")
        try Data(count: 10).write(to: sentinel)

        let scanner = FileScanner()
        let report = await scanner.rescanSubtrees(
            [root + "/big"], tree: tree, progress: ScanProgress(),
            shallowTargets: [root + "/big"]
        )
        #expect(report.shallowRoots.count == 1)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(summarizeTree(tree)[root + "/big/sub/sentinel.txt"] == nil,
                "a shallow reconcile must not enumerate child subtrees")
        #expect(summarizeTree(tree)[root + "/big/file1.txt"]?.fileSize == 4096,
                "the level's fresh metadata must land in place")

        // With the sentinel removed, the on-disk state matches what the patch claims -
        // the patched tree must be indistinguishable from a fresh cold scan, aggregates
        // included.
        try FileManager.default.removeItem(at: sentinel)
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "metadata-only shallow patch")
    }

    @Test("A structural change at the level promotes to full-subtree semantics")
    func structuralChangePromotes() async throws {
        let (root, cleanup) = try createTempTree([
            "big/file1.txt": 100,
            "big/sub/deep1.txt": 200,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        // Structural change at big/'s own level, plus a deep sentinel that only a
        // full-subtree rescan can absorb - promotion must pick BOTH up.
        try Data(count: 64).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/created.txt"))
        try Data(count: 32).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/sub/sentinel.txt"))

        let scanner = FileScanner()
        let report = await scanner.rescanSubtrees(
            [root + "/big"], tree: tree, progress: ScanProgress(),
            shallowTargets: [root + "/big"]
        )
        #expect(report.shallowRoots.isEmpty, "a promoted target is not an in-place root")
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "promoted shallow patch")
    }

    @Test("A doomed promotion abandons before staging, not after")
    func oversizedPromotionAbandonsBeforeStaging() async throws {
        var layout: [String: UInt64] = ["big/file1.txt": 100, "other/x.txt": 50]
        for i in 0..<220 { layout["big/sub/f\(i).txt"] = 10 }
        let (root, cleanup) = try createTempTree(layout)
        defer { cleanup() }
        let tree = await coldScan(root)
        let before = summarizeTree(tree)

        // Structural change at big/'s level forces a promotion whose cached subtree
        // (~220+ items) dwarfs the remaining budget below.
        try Data(count: 64).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/created.txt"))

        let scanner = FileScanner()
        let report = await scanner.rescanSubtrees(
            [root + "/big"], tree: tree, progress: ScanProgress(),
            shallowTargets: [root + "/big"],
            options: SubtreeRescanOptions(
                priority: .interactive,
                resetsCancellation: true,
                maximumStagedItemCount: 50,
                // The production floor is 100k; the refusal mechanics are identical, so
                // the fixture injects a floor its 220-item subtree clears.
                promotionRefusalFloor: 100
            )
        )
        let exceeded = try #require(report.stagedItemBudgetExceeded,
                                    "the doomed promotion must refuse via the budget")
        #expect(exceeded.actualStagedItemCount > 50,
                "the refusal must carry the predicted size for the reason line")
        #expect(report.metrics.stagedNodeCount == 0,
                "the whole point: no Phase A staging happens for a doomed patch")
        #expect(report.shallowRoots.isEmpty)
        #expect(summarizeTree(tree) == before, "the tree is untouched")
    }

    @Test("Files changing directly inside the scan root reconcile in place")
    func rootLevelShallowReconciles() async throws {
        let (root, cleanup) = try createTempTree([
            "top.txt": 100,
            "dir/inner.txt": 200,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        try Data(count: 2048).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("top.txt"))

        let scanner = FileScanner()
        let report = await scanner.rescanSubtrees(
            [root], tree: tree, progress: ScanProgress(),
            shallowTargets: [root]
        )
        let treeRoot = tree.path(at: 0)
        #expect(report.shallowRoots == [treeRoot],
                "the root's own level must be reconcilable, not an automatic abandon")
        #expect(report.rescannedRoots == [treeRoot])
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "root-level shallow patch")
    }

    @Test("A structural root-level change still abandons before any mutation")
    func rootLevelStructuralStillAbandons() async throws {
        let (root, cleanup) = try createTempTree([
            "top.txt": 100,
            "dir/inner.txt": 200,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)
        let before = summarizeTree(tree)

        try Data(count: 64).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("created.txt"))

        let scanner = FileScanner()
        let report = await scanner.rescanSubtrees(
            [root], tree: tree, progress: ScanProgress(),
            shallowTargets: [root]
        )
        let treeRoot = tree.path(at: 0)
        #expect(report.rescannedRoots.contains(treeRoot),
                "callers keep their existing root-level cold-fallback signal")
        #expect(report.shallowRoots.isEmpty)
        #expect(summarizeTree(tree) == before,
                "a promoted root-level target must abandon before any mutation")
    }

    @Test("A shallow parent and a nested deep target both apply")
    func shallowParentPlusNestedDeepTarget() async throws {
        let (root, cleanup) = try createTempTree([
            "big/file1.txt": 100,
            "big/sub/deep1.txt": 200,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        // Metadata change at big/'s level AND a structural change inside big/sub, each
        // reported as its own target - the old collapse swallowed the deep one.
        try Data(count: 4096).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/file1.txt"))
        try Data(count: 128).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/sub/added.txt"))

        let scanner = FileScanner()
        let report = await scanner.rescanSubtrees(
            [root + "/big", root + "/big/sub"], tree: tree, progress: ScanProgress(),
            shallowTargets: [root + "/big"]
        )
        #expect(report.rescannedRoots.count == 2,
                "the shallow parent must not swallow the nested deep target")
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "shallow parent + nested deep target")
    }

    // MARK: - Evidence tagging

    @Test("Journal replay tags file-only targets and spares directory events")
    func journalReplayTagsFileOnlyTargets() async throws {
        let (root, cleanup) = try createTempTree([
            "dirA/existing.txt": 100,
        ])
        defer { cleanup() }

        // Settle the fixture-creation burst before capturing the horizon: under daemon
        // lag, dirA's own creation event can flush with an id AFTER a naively captured
        // horizon, handing dirA spurious directory evidence and flaking the file-only
        // assertion (same discipline as DeferredEphemeralWarmStartTests' settle).
        let settleMarker = root + "/.settle-\(UUID().uuidString)"
        let beforeSettle = FSEventsJournal.currentEventId()
        try Data().write(to: URL(fileURLWithPath: settleMarker))
        try #require(await waitForJournalChanges(root: root, since: beforeSettle),
                     "FSEvents never journaled the settle marker")
        let beforeRemoval = FSEventsJournal.currentEventId()
        try FileManager.default.removeItem(atPath: settleMarker)
        try #require(await waitForJournalChanges(root: root, since: beforeRemoval),
                     "FSEvents never journaled the settle marker removal")

        let sinceId = FSEventsJournal.currentEventId()
        try Data(count: 900).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("dirA/existing.txt"))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: root).appendingPathComponent("createdDir"),
            withIntermediateDirectories: false)

        // A real FSEvents fixture must wait for the COMPLETE mutation shape (both the
        // file-derived parent and the created directory), within the established 20s
        // ceiling - one event arriving first is a valid but incomplete replay.
        let deadline = Date().addingTimeInterval(20)
        var observed: JournalReplay?
        while Date() < deadline {
            let replay = await FSEventsJournal.replay(root: root, since: sinceId, timeout: 5)
            if case .changes(let targets) = replay.outcome,
               targets.contains(where: { $0.hasSuffix("/dirA") }),
               targets.contains(where: { $0.hasSuffix("/createdDir") }) {
                observed = replay
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let replay = try #require(observed, "journal never reported the full mutation shape")
        #expect(replay.fileOnlyTargets.contains { $0.hasSuffix("/dirA") },
                "a parent blamed only by a file event must be shallow-eligible")
        #expect(!replay.fileOnlyTargets.contains { $0.hasSuffix("/createdDir") },
                "a directory FSEvents reported itself must keep full-subtree semantics")
    }

    @Test("The live monitor records directory evidence stickily")
    func monitorTagsDirectoryEvidence() {
        let monitor = FSEventsMonitor(watchPath: "/tmp/watch-fixture")
        let fileFlag: FSEventStreamEventFlags = 0
        let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)

        monitor.processChanges([
            FSChange(path: "/tmp/watch-fixture/parent/file.txt", flags: fileFlag, timestamp: Date())
        ])
        var summary = monitor.currentChanges().first { $0.path.hasSuffix("/parent") }
        #expect(summary?.hasDirectoryEvent == false,
                "file→parent reduction alone must stay shallow-eligible")

        monitor.processChanges([
            FSChange(path: "/tmp/watch-fixture/parent", flags: dirFlag, timestamp: Date())
        ])
        summary = monitor.currentChanges().first { $0.path.hasSuffix("/parent") }
        #expect(summary?.hasDirectoryEvent == true,
                "directory evidence wins for the rest of the accumulation window")
    }
}
