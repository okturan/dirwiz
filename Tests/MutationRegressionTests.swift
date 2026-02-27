import Testing
@testable import DirWizLib

@Suite("Mutation Regression Tests")
struct MutationRegressionTests {

    @Test("removeSubtree removes deleted directory descendants from the tree")
    func removeDirectorySubtree() {
        let tree = makeTree()

        tree.removeSubtree(at: 1)

        #expect(tree.count == 2)
        #expect(tree.name(at: 1) == "sparse.dat")
        #expect(tree.path(at: 1).hasSuffix("/sparse.dat"))
        #expect(tree.children(of: 0).count == 1)

        if let root = tree.node(at: 0) {
            #expect(root.childCount == 1)
            #expect(root.fileSize == 100)
            #expect(root.allocatedSize == 20)
        } else {
            Issue.record("Missing root node after subtree removal")
        }
    }

    @Test("removeSubtree keeps logical and allocated ancestor totals separate")
    func removeSparseLeafUsesSeparateTotals() {
        let tree = makeTree()

        tree.removeSubtree(at: 2)

        #expect(tree.count == 3)
        if let root = tree.node(at: 0) {
            #expect(root.fileSize == 7)
            #expect(root.allocatedSize == 9)
            #expect(root.childCount == 1)
        } else {
            Issue.record("Missing root node after leaf removal")
        }

        if let folder = tree.node(at: 1) {
            #expect(folder.fileSize == 7)
            #expect(folder.allocatedSize == 9)
            #expect(folder.childCount == 1)
        } else {
            Issue.record("Missing folder node after leaf removal")
        }
    }

    @Test("clone assessment uses allocated sizes rather than logical size")
    func cloneAssessmentUsesAllocatedSizes() {
        // Three identical allocated sizes => zero sharing (each copy fully independent).
        let compressedCopies = APFSIntelligence.assessCloneSharing(allocatedSizes: [64, 64, 64])
        #expect(!compressedCopies.areClones)
        #expect(compressedCopies.sharingConfidence == 0.0)
        #expect(compressedCopies.realWastedSpace == 128)

        // One full copy + one small delta => high sharing confidence.
        let cloneCopies = APFSIntelligence.assessCloneSharing(allocatedSizes: [64, 16])
        #expect(cloneCopies.areClones)
        #expect(cloneCopies.sharingConfidence == 0.75)
        #expect(cloneCopies.realWastedSpace == 16)

        // Perfect clones: all allocation fits in one copy.
        let perfectClones = APFSIntelligence.assessCloneSharing(allocatedSizes: [64, 0, 0])
        #expect(perfectClones.areClones)
        #expect(perfectClones.sharingConfidence == 1.0)
        #expect(perfectClones.realWastedSpace == 0)
    }

    @Test("clone confidence at exact 0.5 boundary is not classified as clone")
    func cloneBoundaryAt50Percent() {
        // allocatedSizes [100, 50]: max=100, total=150, expectedExtra=100, actualExtra=50
        // confidence = 1.0 - 50/100 = 0.5 (exact in IEEE 754)
        // threshold is > 0.5, so areClones must be false.
        let result = APFSIntelligence.assessCloneSharing(allocatedSizes: [100, 50])
        #expect(result.sharingConfidence == 0.5)
        #expect(!result.areClones, "Confidence == 0.5 should NOT be classified as clone (threshold is > 0.5)")
        #expect(result.realWastedSpace == 50)
    }

    @Test("clone assessment with empty input returns no clones")
    func cloneEmptyInput() {
        let result = APFSIntelligence.assessCloneSharing(allocatedSizes: [])
        #expect(!result.areClones)
        #expect(result.sharingConfidence == 0.0)
        #expect(result.realWastedSpace == 0)
    }

    @Test("clone assessment with single element returns no clones")
    func cloneSingleElement() {
        let result = APFSIntelligence.assessCloneSharing(allocatedSizes: [4096])
        #expect(!result.areClones)
        #expect(result.sharingConfidence == 0.0)
        #expect(result.realWastedSpace == 0)
    }

    private func makeTree() -> FileTree {
        let tree = FileTree()
        tree.setRootPath("/root")

        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "root")

        var folder = FileNode()
        folder.isDirectory = true

        var sparse = FileNode()
        sparse.fileSize = 100
        sparse.allocatedSize = 20

        tree.addChildren([
            (node: folder, name: "folder"),
            (node: sparse, name: "sparse.dat"),
        ], parentIndex: 0)

        var nested = FileNode()
        nested.fileSize = 7
        nested.allocatedSize = 9
        tree.addChildren([
            (node: nested, name: "nested.txt"),
        ], parentIndex: 1)

        tree.propagateSizes()
        return tree
    }
}
