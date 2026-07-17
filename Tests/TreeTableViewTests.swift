import Testing
@testable import DirWizCore
@testable import DirWizUI

/// Unit tests for `TreeTableView.remapExpansion`: rebuilding an index-keyed expansion set
/// from path-keyed state after a tree mutation that renumbers indices. Pure over a tree
/// snapshot, so these build small in-memory trees directly rather than driving a real
/// trash operation (that's `Tests/TrashInvalidationTests.swift`'s job).
@MainActor
@Suite("TreeTableView Expansion Remap Tests")
struct TreeTableViewTests {

    @Test("Surviving folders keep their (possibly shifted) index; deleted folders drop out")
    func survivorsKeepDeletedDrop() {
        // "Before" shape: root(0) / dirA(1) / dirA/subA1(2) / dirB(3).
        // The user had dirA and dirB expanded, so expandedPaths = {"/vol/dirA", "/vol/dirB"}
        // (subA1 was never expanded, just included below to prove it plays no role).
        let expandedPaths: Set<String> = ["/vol/dirA", "/vol/dirB"]

        // "After" shape simulates dirA (and its child subA1) having been trashed: only
        // dirB survives, and — because removeSubtree compacts the array — it now sits at
        // index 1 instead of its old index 3.
        let after = FileTree()
        after.setRootPath("/vol")
        after.addNode(FileNode(parentIndex: FileNode.invalid, flags: 1), name: "root") // 0
        after.addChildren([(node: FileNode(flags: 1), name: "dirB")], parentIndex: 0) // 1

        let remapped = TreeTableView.remapExpansion(paths: expandedPaths, tree: after)

        #expect(remapped == [1], "dirB should survive at its new (shifted) index; dirA should drop out")
    }

    @Test("A path outside the tree's root is dropped, not mistakenly matched")
    func outsideRootPathDropped() {
        let tree = FileTree()
        tree.setRootPath("/vol")
        tree.addNode(FileNode(parentIndex: FileNode.invalid, flags: 1), name: "root")
        tree.addChildren([(node: FileNode(flags: 1), name: "dirA")], parentIndex: 0)

        let remapped = TreeTableView.remapExpansion(paths: ["/other/place"], tree: tree)

        #expect(remapped.isEmpty)
    }

    @Test("Empty expandedPaths remaps to an empty set")
    func emptyInputRemapsToEmpty() {
        let tree = FileTree()
        tree.setRootPath("/vol")
        tree.addNode(FileNode(parentIndex: FileNode.invalid, flags: 1), name: "root")

        let remapped = TreeTableView.remapExpansion(paths: [], tree: tree)

        #expect(remapped.isEmpty)
    }
}
