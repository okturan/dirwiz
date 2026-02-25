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
