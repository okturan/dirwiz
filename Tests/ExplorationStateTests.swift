import Testing
@testable import DirWizCore
@testable import DirWizUI

/// Unit tests for `ExplorationCapture.resolveOrAncestor`: given a path captured before a
/// tree mutation, does it resolve to the right node (itself, or nearest surviving
/// ancestor) against a tree that no longer has some of the original nodes? This is pure
/// over snapshots — no on-disk fixture or real trash operation needed.
/// `Tests/TrashInvalidationTests.swift` covers the AppState-level wiring against a real
/// `trashNode`/`batchTrashPaths` call.
@Suite("Exploration State Tests")
struct ExplorationStateTests {

    /// Build a tree under root "/vol" with only the first `depth` levels of
    /// `dirA/subA1/leaf.txt` present, simulating a post-deletion tree at various depths:
    /// depth 0: root only
    /// depth 1: + dirA
    /// depth 2: + dirA/subA1
    /// depth 3: + dirA/subA1/leaf.txt (nothing missing)
    private func makeFixture(depth: Int) -> FileTree {
        let tree = FileTree()
        tree.setRootPath("/vol")
        tree.addNode(FileNode(parentIndex: FileNode.invalid, flags: 1), name: "root") // index 0
        guard depth >= 1 else { return tree }
        tree.addChildren([(node: FileNode(flags: 1), name: "dirA")], parentIndex: 0) // index 1
        guard depth >= 2 else { return tree }
        tree.addChildren([(node: FileNode(flags: 1), name: "subA1")], parentIndex: 1) // index 2
        guard depth >= 3 else { return tree }
        tree.addChildren([(node: FileNode(flags: 0), name: "leaf.txt")], parentIndex: 2) // index 3
        return tree
    }

    private static let leafPath = "/vol/dirA/subA1/leaf.txt"

    @Test("Surviving path resolves to itself")
    func survivor() {
        let tree = makeFixture(depth: 3)
        let resolved = ExplorationCapture.resolveOrAncestor(Self.leafPath, tree: tree)
        #expect(resolved == 3)
    }

    @Test("Deleted leaf resolves to its surviving parent")
    func deletedLeafResolvesToParent() {
        let tree = makeFixture(depth: 2) // leaf.txt gone; subA1 survives
        let resolved = ExplorationCapture.resolveOrAncestor(Self.leafPath, tree: tree)
        #expect(resolved == 2)
    }

    @Test("Deleted branch resolves to its surviving grandparent")
    func deletedBranchResolvesToGrandparent() {
        let tree = makeFixture(depth: 1) // subA1 (and leaf.txt) gone; dirA survives
        let resolved = ExplorationCapture.resolveOrAncestor(Self.leafPath, tree: tree)
        #expect(resolved == 1)
    }

    @Test("Everything but the tree root gone falls back to root")
    func fallsBackToRoot() {
        let tree = makeFixture(depth: 0) // only root survives
        let resolved = ExplorationCapture.resolveOrAncestor(Self.leafPath, tree: tree)
        #expect(resolved == 0)
    }

    @Test("Path outside the tree's root resolves to nil")
    func pathOutsideTreeIsNil() {
        let tree = makeFixture(depth: 3)
        let resolved = ExplorationCapture.resolveOrAncestor("/other/place/file.txt", tree: tree)
        #expect(resolved == nil)
    }

    @Test("A merely-textual prefix match without a path boundary is rejected")
    func rejectsTextualPrefixWithoutBoundary() {
        let tree = FileTree()
        tree.setRootPath("/Users/al")
        tree.addNode(FileNode(parentIndex: FileNode.invalid, flags: 1), name: "root")
        let resolved = ExplorationCapture.resolveOrAncestor("/Users/alice/file.txt", tree: tree)
        #expect(resolved == nil)
    }

    @Test("capture(tree:selectedIndex:treemapRootIndex:) reads paths from the given indices")
    func captureReadsPaths() {
        let tree = makeFixture(depth: 3)
        let capture = ExplorationCapture.capture(tree: tree, selectedIndex: 3, treemapRootIndex: 1)
        #expect(capture.selectedPath == Self.leafPath)
        #expect(capture.treemapRootPath == "/vol/dirA")
    }

    @Test("capture(tree:selectedIndex:treemapRootIndex:) with nil selection captures nil")
    func captureWithNoSelection() {
        let tree = makeFixture(depth: 3)
        let capture = ExplorationCapture.capture(tree: tree, selectedIndex: nil, treemapRootIndex: 0)
        #expect(capture.selectedPath == nil)
        #expect(capture.treemapRootPath == "/vol")
    }
}
