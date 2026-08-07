import Testing
import Foundation
@testable import DirWizCore

/// Stage 6 equivalence gates for `selective-child-rescan`: addition / removal / type
/// change / mixed / multi-target / untouched-sibling identity / hardlink flags.
@Suite("Selective Child Rescan Tests")
struct SelectiveChildRescanTests {

    private func coldScan(_ path: String) async -> FileTree {
        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)
        return tree
    }

    private func patch(
        _ targets: [String],
        tree: FileTree,
        shallow: Set<String> = []
    ) async -> SubtreeRescanReport {
        await FileScanner().rescanSubtrees(
            targets, tree: tree, progress: ScanProgress(), shallowTargets: shallow
        )
    }

    @Test("Addition-only level diff equals a fresh cold scan")
    func additionOnlyEqualsCold() async throws {
        let (root, cleanup) = try createTempTree([
            "keep/a.txt": 100,
            "keep/nested/b.txt": 200,
            "sibling/c.txt": 50,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: root).appendingPathComponent("keep/newDir"),
            withIntermediateDirectories: true)
        try Data(count: 77).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("keep/newDir/leaf.txt"))

        let report = await patch([root + "/keep"], tree: tree)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.stagedItemBudgetExceeded == nil)
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "addition-only")
    }

    @Test("Removal-only level diff equals a fresh cold scan")
    func removalOnlyEqualsCold() async throws {
        let (root, cleanup) = try createTempTree([
            "keep/a.txt": 100,
            "keep/gone/nested.txt": 200,
            "keep/stay/x.txt": 30,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: root).appendingPathComponent("keep/gone"))

        let report = await patch([root + "/keep"], tree: tree)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(summarizeTree(tree)[root + "/keep/gone/nested.txt"] == nil)
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "removal-only")
    }

    @Test("Type-change level diff equals a fresh cold scan")
    func typeChangeEqualsCold() async throws {
        let (root, cleanup) = try createTempTree([
            "keep/wasFile.txt": 100,
            "keep/other/x.txt": 20,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        let flipped = URL(fileURLWithPath: root).appendingPathComponent("keep/wasFile.txt")
        try FileManager.default.removeItem(at: flipped)
        try FileManager.default.createDirectory(at: flipped, withIntermediateDirectories: false)
        try Data(count: 55).write(to: flipped.appendingPathComponent("inside.txt"))

        let report = await patch([root + "/keep"], tree: tree)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(summarizeTree(tree)[root + "/keep/wasFile.txt/inside.txt"]?.fileSize == 55)
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "type-change")
    }

    @Test("Mixed add/remove/type-change equals a fresh cold scan")
    func mixedDiffEqualsCold() async throws {
        let (root, cleanup) = try createTempTree([
            "keep/a.txt": 10,
            "keep/gone.txt": 20,
            "keep/flip.txt": 30,
            "keep/stay/nested.txt": 40,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: root).appendingPathComponent("keep/gone.txt"))
        try Data(count: 88).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("keep/added.txt"))
        let flip = URL(fileURLWithPath: root).appendingPathComponent("keep/flip.txt")
        try FileManager.default.removeItem(at: flip)
        try FileManager.default.createDirectory(at: flip, withIntermediateDirectories: false)
        try Data(count: 9).write(to: flip.appendingPathComponent("n.txt"))

        let report = await patch([root + "/keep"], tree: tree)
        #expect(report.unresolvedPaths.isEmpty)
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "mixed diff")
    }

    @Test("Untouched sibling subtrees retain their node identities")
    func untouchedSiblingRetainsIdentity() async throws {
        let (root, cleanup) = try createTempTree([
            "keep/a.txt": 10,
            "keep/untouched/deep/x.txt": 20,
            "keep/untouched/deep/y.txt": 30,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)
        let before = summarizeTree(tree)
        let untouchedBefore = before[root + "/keep/untouched/deep/x.txt"]

        try Data(count: 64).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("keep/created.txt"))

        let report = await patch([root + "/keep"], tree: tree)
        #expect(report.unresolvedPaths.isEmpty)
        let after = summarizeTree(tree)
        #expect(after[root + "/keep/untouched/deep/x.txt"] == untouchedBefore,
                "descendant identity of an unchanged sibling must survive")
        #expect(after[root + "/keep/untouched/deep/y.txt"]
                    == before[root + "/keep/untouched/deep/y.txt"])
        #expect(after[root + "/keep/created.txt"]?.fileSize == 64)
    }

    @Test("Multi-target batch equals a fresh cold scan in one compaction")
    func multiTargetBatchEqualsCold() async throws {
        let (root, cleanup) = try createTempTree([
            "a/keep.txt": 10,
            "a/gone.txt": 11,
            "b/keep.txt": 20,
            "c/nested/x.txt": 30,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: root).appendingPathComponent("a/gone.txt"))
        try Data(count: 5).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("a/new.txt"))
        try Data(count: 6).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("b/new.txt"))
        try Data(count: 7).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("c/nested/y.txt"))

        let report = await patch(
            [root + "/a", root + "/b", root + "/c/nested"],
            tree: tree
        )
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.metrics.structurallyReplacedRootCount >= 1)
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "multi-target batch")
    }

    @Test("Hardlink flags survive an in-place metadata update beside an addition")
    func hardlinkFlagsSurviveMetadataAndAddition() async throws {
        let (root, cleanup) = try createTempTree([
            "keep/shared.txt": 100,
            "keep/other.txt": 50,
        ])
        defer { cleanup() }

        let shared = root + "/keep/shared.txt"
        let linked = root + "/keep/shared-link.txt"
        guard link(shared, linked) == 0 else {
            Issue.record("link(2) failed: \(errno)")
            return
        }

        let tree = await coldScan(root)
        let before = summarizeTree(tree)
        #expect(before[shared]?.hasMultipleHardlinks == true)
        #expect(before[linked]?.hasMultipleHardlinks == true)

        try Data(count: 2048).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("keep/other.txt"))
        try Data(count: 12).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("keep/created.txt"))

        let report = await patch([root + "/keep"], tree: tree)
        #expect(report.unresolvedPaths.isEmpty)
        let after = summarizeTree(tree)
        #expect(after[shared]?.hasMultipleHardlinks == true)
        #expect(after[linked]?.hasMultipleHardlinks == true)
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "hardlink flags after selective patch")
    }

    @Test("Parent and child directory changes apply together in one patch")
    func parentAndChildDirectoryBothChangedApplyTogether() async throws {
        let (root, cleanup) = try createTempTree([
            "big/file1.txt": 100,
            "big/sub/deep1.txt": 200,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        try Data(count: 64).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/created.txt"))
        try Data(count: 32).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/sub/nested.txt"))

        let report = await patch([root + "/big", root + "/big/sub"], tree: tree)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.stagedItemBudgetExceeded == nil)
        #expect(report.metrics.structurallyReplacedRootCount == 2,
                "one compaction must carry both nested structural targets")
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "parent+child directory both changed")
    }

    @Test("A deep chain of changed directories equals a fresh cold scan")
    func deepChainOfChangedDirectories() async throws {
        let (root, cleanup) = try createTempTree([
            "a/b/c/d/leaf.txt": 10,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        try Data(count: 1).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("a/a-new.txt"))
        try Data(count: 2).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("a/b/b-new.txt"))
        try Data(count: 3).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("a/b/c/c-new.txt"))
        try Data(count: 4).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("a/b/c/d/d-new.txt"))

        let report = await patch(
            [root + "/a", root + "/a/b", root + "/a/b/c", root + "/a/b/c/d"],
            tree: tree
        )
        #expect(report.unresolvedPaths.isEmpty)
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "deep chain of changed directories")
    }

    @Test("Directory-event targets level-diff without shallow tagging")
    func directoryEventTargetLevelDiffs() async throws {
        let (root, cleanup) = try createTempTree([
            "big/file1.txt": 100,
            "big/sub/deep1.txt": 200,
            "big/sub/deep2.txt": 300,
        ])
        defer { cleanup() }
        let tree = await coldScan(root)

        try Data(count: 64).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/created.txt"))
        // Unreported deep sentinel under an unchanged child - must stay out.
        try Data(count: 8).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("big/sub/sentinel.txt"))

        // No shallowTargets: this is a directory-event target.
        let report = await patch([root + "/big"], tree: tree)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(summarizeTree(tree)[root + "/big/created.txt"]?.fileSize == 64)
        #expect(summarizeTree(tree)[root + "/big/sub/sentinel.txt"] == nil)

        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: root).appendingPathComponent("big/sub/sentinel.txt"))
        let fresh = await coldScan(root)
        assertTreesEquivalent(tree, fresh, "directory-event selective patch")
    }
}
