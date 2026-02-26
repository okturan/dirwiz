import Testing
import Foundation
@testable import DirWizLib

@Suite("FileScanner Tests")
struct FileScannerTests {

    @Test("Scan /Applications returns non-empty tree")
    func scanApplications() async {
        let scanner = FileScanner()
        let progress = ScanProgress()

        // /Applications is small enough for a quick test.
        let tree = FileTree()
        await scanner.scan(path: "/Applications", progress: progress, tree: tree)

        #expect(tree.count > 0, "Tree should have nodes after scanning /Applications")
        #expect(progress.scanComplete, "Scan should be marked complete")
        #expect(!progress.isScanning, "Should not be scanning after completion")
        #expect(progress.filesScanned > 0, "Should have scanned some files")
    }

    @Test("Root node is a directory with accumulated size")
    func rootNodeIsDirectory() async {
        let scanner = FileScanner()
        let progress = ScanProgress()

        let tree = FileTree()
        await scanner.scan(path: "/Applications", progress: progress, tree: tree)

        guard !tree.isEmpty else {
            Issue.record("Tree should not be empty")
            return
        }

        let root = tree.nodes[0]
        #expect(root.isDirectory, "Root node should be a directory")
        #expect(root.fileSize > 0, "Root should have accumulated file sizes")
        #expect(root.parentIndex == FileNode.invalid, "Root should have no parent")
    }

    @Test("All children reference valid parent indices")
    func validParentReferences() async {
        let scanner = FileScanner()
        let progress = ScanProgress()

        let tree = FileTree()
        await scanner.scan(path: "/Applications", progress: progress, tree: tree)

        for i in 1..<tree.count {
            let node = tree.nodes[i]
            #expect(node.parentIndex != FileNode.invalid,
                "Non-root node \(i) should have a valid parent")
            #expect(Int(node.parentIndex) < tree.count,
                "Parent index \(node.parentIndex) should be within bounds")
        }
    }

    @Test("Directory child count matches actual children")
    func directoryChildCount() async {
        let scanner = FileScanner()
        let progress = ScanProgress()

        let tree = FileTree()
        await scanner.scan(path: "/Applications", progress: progress, tree: tree)

        for i in 0..<tree.count {
            let node = tree.nodes[i]
            guard node.isDirectory, node.firstChildIndex != FileNode.invalid else { continue }
            let start = Int(node.firstChildIndex)
            let end = start + Int(node.childCount)
            #expect(end <= tree.count,
                "Directory \(tree.name(at: UInt32(i))) children range [\(start)..\(end)) exceeds tree size \(tree.count)")
        }
    }

    @Test("File names are non-empty")
    func fileNamesNonEmpty() async {
        let scanner = FileScanner()
        let progress = ScanProgress()

        let tree = FileTree()
        await scanner.scan(path: "/Applications", progress: progress, tree: tree)

        for i in 0..<min(tree.count, 100) { // Check first 100 nodes
            let name = tree.name(at: UInt32(i))
            #expect(!name.isEmpty, "Node \(i) should have a non-empty name")
        }
    }

    @Test("Elapsed time is reasonable")
    func elapsedTimeReasonable() async {
        let scanner = FileScanner()
        let progress = ScanProgress()

        let tree = FileTree()
        await scanner.scan(path: "/Applications", progress: progress, tree: tree)

        #expect(progress.elapsedTime > 0, "Elapsed time should be positive")
        #expect(progress.elapsedTime < 60, "Scanning /Applications should take less than 60 seconds")
    }

    @Test("Scan non-existent path returns minimal tree")
    func scanNonExistent() async {
        let scanner = FileScanner()
        let progress = ScanProgress()

        let tree = FileTree()
        await scanner.scan(path: "/nonexistent_path_12345", progress: progress, tree: tree)

        // Should still have the root node at minimum.
        #expect(tree.count >= 1, "Should have at least a root node")
        #expect(progress.scanComplete, "Scan should complete even for invalid paths")
    }
}

@Suite("FileNode Tests")
struct FileNodeTests {

    @Test("Extension hash is deterministic")
    func extensionHashDeterministic() {
        let hash1 = extensionHash("test.pdf")
        let hash2 = extensionHash("test.pdf")
        #expect(hash1 == hash2, "Same extension should produce same hash")
    }

    @Test("Different extensions produce different hashes")
    func differentExtensionsDifferentHashes() {
        let pdfHash = extensionHash("file.pdf")
        let jpgHash = extensionHash("file.jpg")
        let swiftHash = extensionHash("file.swift")

        #expect(pdfHash != jpgHash, "pdf and jpg should have different hashes")
        #expect(jpgHash != swiftHash, "jpg and swift should have different hashes")
    }

    @Test("No extension produces zero hash")
    func noExtensionZeroHash() {
        let hash = extensionHash("Makefile")
        #expect(hash == 0, "Files without extension should have hash 0")
    }

    @Test("FileTree path building works")
    func pathBuilding() {
        let tree = FileTree()
        tree.rootPath = "/Users"
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "Users")

        var child = FileNode()
        child.isDirectory = true
        tree.addChildren([(node: child, name: "Documents")], parentIndex: 0)

        var leaf = FileNode()
        leaf.fileSize = 100
        tree.addChildren([(node: leaf, name: "readme.txt")], parentIndex: 1)

        let path = tree.path(at: 2)
        #expect(path == "/Users/Documents/readme.txt")

        // Root node itself returns the rootPath
        #expect(tree.path(at: 0) == "/Users")

        // Volume root scan: rootPath = "/"
        let volumeTree = FileTree()
        volumeTree.rootPath = "/"
        var vRoot = FileNode()
        vRoot.isDirectory = true
        volumeTree.addNode(vRoot, name: "/")
        var vChild = FileNode()
        vChild.fileSize = 50
        volumeTree.addChildren([(node: vChild, name: "file.txt")], parentIndex: 0)
        #expect(volumeTree.path(at: 1) == "/file.txt")
        #expect(volumeTree.path(at: 0) == "/")
    }

    @Test("sortAllChildren preserves subtree integrity across directories")
    func sortAllChildrenSubtreeStability() {
        let tree = FileTree()
        tree.rootPath = "/test"

        // Root (index 0)
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "test")

        // Two directories under root: A (small) and B (large)
        var dirA = FileNode()
        dirA.isDirectory = true
        var dirB = FileNode()
        dirB.isDirectory = true
        // A has size 100, B has size 1000 — after sort B should come first.
        dirA.fileSize = 100
        dirB.fileSize = 1000
        tree.addChildren([
            (node: dirA, name: "A"),
            (node: dirB, name: "B"),
        ], parentIndex: 0)
        // A is at index 1, B is at index 2

        // Add children to A: a1 (50), a2 (30), a3 (20)
        var a1 = FileNode(); a1.fileSize = 50
        var a2 = FileNode(); a2.fileSize = 30
        var a3 = FileNode(); a3.fileSize = 20
        tree.addChildren([
            (node: a1, name: "a1.txt"),
            (node: a2, name: "a2.txt"),
            (node: a3, name: "a3.txt"),
        ], parentIndex: 1)
        // a1=3, a2=4, a3=5

        // Add children to B: b1 (200), b2 (800)
        var b1 = FileNode(); b1.fileSize = 200
        var b2 = FileNode(); b2.fileSize = 800
        tree.addChildren([
            (node: b1, name: "b1.txt"),
            (node: b2, name: "b2.txt"),
        ], parentIndex: 2)
        // b1=6, b2=7

        // Sort all children
        tree.sortAllChildren()

        let nodes = tree.nodesSnapshot()

        // Root's children: B (1000) should come before A (100) after sort.
        let rootFirst = Int(nodes[0].firstChildIndex)
        #expect(nodes[rootFirst].fileSize == 1000, "B (size 1000) should be first child of root")
        #expect(nodes[rootFirst + 1].fileSize == 100, "A (size 100) should be second child of root")

        // Both directories should still have valid children.
        let dirBIdx = rootFirst      // B is now first
        let dirAIdx = rootFirst + 1  // A is now second

        let bNode = nodes[dirBIdx]
        #expect(bNode.isDirectory)
        #expect(bNode.childCount == 2)
        let bFirst = Int(bNode.firstChildIndex)
        // B's children should be sorted: b2 (800) before b1 (200).
        #expect(nodes[bFirst].fileSize == 800, "b2 should come first in B")
        #expect(nodes[bFirst + 1].fileSize == 200, "b1 should come second in B")
        // B's children should reference B as parent.
        #expect(nodes[bFirst].parentIndex == UInt32(dirBIdx))
        #expect(nodes[bFirst + 1].parentIndex == UInt32(dirBIdx))

        let aNode = nodes[dirAIdx]
        #expect(aNode.isDirectory)
        #expect(aNode.childCount == 3)
        let aFirst = Int(aNode.firstChildIndex)
        // A's children should be sorted: a1 (50), a2 (30), a3 (20).
        #expect(nodes[aFirst].fileSize == 50)
        #expect(nodes[aFirst + 1].fileSize == 30)
        #expect(nodes[aFirst + 2].fileSize == 20)
        // A's children should reference A as parent.
        for j in aFirst..<(aFirst + 3) {
            #expect(nodes[j].parentIndex == UInt32(dirAIdx),
                "A's child at \(j) should point to A at \(dirAIdx)")
        }

        // Paths should still resolve correctly after sort.
        // B's children are at indices 6,7; A's children at 3,4,5 (unchanged positions).
        // But B and A themselves moved within root's child slice.
        let bChildPath = tree.path(at: UInt32(bFirst))
        #expect(bChildPath.contains("b"), "B's child path should contain 'b': got \(bChildPath)")
        let aChildPath = tree.path(at: UInt32(aFirst))
        #expect(aChildPath.contains("a"), "A's child path should contain 'a': got \(aChildPath)")
    }

    @Test("FileTree size accumulation works")
    func sizeAccumulation() {
        let tree = FileTree()
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "root")

        var child = FileNode()
        child.fileSize = 100
        child.allocatedSize = 128
        tree.addChildren([(node: child, name: "file.txt")], parentIndex: 0)

        tree.accumulateSize(from: 1, fileSize: 100, allocatedSize: 128)

        #expect(tree.nodes[0].fileSize == 100, "Root should accumulate child's file size")
        #expect(tree.nodes[0].allocatedSize == 128, "Root should accumulate child's allocated size")
    }
}
