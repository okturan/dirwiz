import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

@Suite("FileScanner Tests")
struct FileScannerTests {

    /// Standard fixture: 3 files across 2 directories.
    private static let standardLayout: [String: UInt64] = [
        "docs/readme.txt": 100,
        "docs/notes.md": 200,
        "images/photo.jpg": 500,
    ]

    @Test("Scan returns non-empty tree")
    func scanReturnsNonEmptyTree() async throws {
        let (path, cleanup) = try createTempTree(Self.standardLayout)
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)

        #expect(tree.count > 0, "Tree should have nodes after scanning")
        #expect(progress.scanComplete, "Scan should be marked complete")
        #expect(!progress.isScanning, "Should not be scanning after completion")
        #expect(progress.filesScanned > 0, "Should have scanned some files")
    }

    @Test("Root node is a directory with accumulated size")
    func rootNodeIsDirectory() async throws {
        let (path, cleanup) = try createTempTree(Self.standardLayout)
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)

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
    func validParentReferences() async throws {
        let (path, cleanup) = try createTempTree(Self.standardLayout)
        defer { cleanup() }

        let scanner = FileScanner(deferTreeMaterialization: true)
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)

        for i in 1..<tree.count {
            let node = tree.nodes[i]
            #expect(node.parentIndex != FileNode.invalid,
                "Non-root node \(i) should have a valid parent")
            #expect(Int(node.parentIndex) < tree.count,
                "Parent index \(node.parentIndex) should be within bounds")
        }
    }

    @Test("Directory child count matches actual children")
    func directoryChildCount() async throws {
        let layout: [String: UInt64] = [
            "docs/readme.txt": 100,
            "docs/notes.md": 200,
            "images/photo.jpg": 500,
            "empty_dir/": 0,
        ]
        let (path, cleanup) = try createTempTree(layout)
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)

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
    func fileNamesNonEmpty() async throws {
        let (path, cleanup) = try createTempTree(Self.standardLayout)
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)

        for i in 0..<tree.count {
            let name = tree.name(at: UInt32(i))
            #expect(!name.isEmpty, "Node \(i) should have a non-empty name")
        }
    }

    @Test("Elapsed time is reasonable")
    func elapsedTimeReasonable() async throws {
        let (path, cleanup) = try createTempTree(Self.standardLayout)
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)

        #expect(progress.elapsedTime > 0, "Elapsed time should be positive")
        #expect(progress.elapsedTime < 5, "Scanning a small fixture should take less than 5 seconds")
    }

    @Test("Scan non-existent path returns minimal tree")
    func scanNonExistent() async {
        let scanner = FileScanner()
        let progress = ScanProgress()

        let tree = FileTree()
        await scanner.scan(path: "/nonexistent_path_12345", progress: progress, tree: tree)

        // Non-existent path produces exactly the root node.
        #expect(tree.count == 1, "Should have exactly the root node")
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

    @Test("Extension hash is ASCII case-insensitive")
    func extensionHashASCIICaseInsensitive() {
        #expect(extensionHash("photo.JPG") == extensionHash("photo.jpg"))
        #expect(extensionHash("archive.TAR.GZ") == extensionHash("archive.tar.gz"))
    }

    @Test("Extension hash matches legacy Unicode lowercasing behavior")
    func extensionHashUnicodeMatchesLegacy() {
        let name = "report.ÇAĞRI"
        #expect(extensionHash(name) == legacyExtensionHash(name))
    }

    @Test("Extension hash trailing dot produces zero")
    func extensionHashTrailingDot() {
        #expect(extensionHash("archive.") == 0)
    }

    @Test("Extension hash ASCII fast path matches legacy")
    func extensionHashASCIIFastPathMatchesLegacy() {
        let names = ["photo.JPG", "archive.tar.gz", ".gitignore", "README.MD"]
        for name in names {
            #expect(extensionHash(name) == legacyExtensionHash(name))
        }
    }

    @Test("FileTree path building works")
    func pathBuilding() {
        let tree = FileTree()
        tree.setRootPath("/Users")
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
        volumeTree.setRootPath("/")
        var vRoot = FileNode()
        vRoot.isDirectory = true
        volumeTree.addNode(vRoot, name: "/")
        var vChild = FileNode()
        vChild.fileSize = 50
        volumeTree.addChildren([(node: vChild, name: "file.txt")], parentIndex: 0)
        #expect(volumeTree.path(at: 1) == "/file.txt")
        #expect(volumeTree.path(at: 0) == "/")
    }

    @Test("FileTree snapshot C path matches regular path building")
    func snapshotCPathBuilding() {
        let tree = FileTree()
        tree.setRootPath("/Users")
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "Users")

        var child = FileNode()
        child.isDirectory = true
        tree.addChildren([(node: child, name: "Documents")], parentIndex: 0)

        var leaf = FileNode()
        leaf.fileSize = 100
        tree.addChildren([(node: leaf, name: "readme.txt")], parentIndex: 1)

        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()
        let cPath = FileTree.withCPathFromSnapshot(
            at: 2,
            nodes: nodes,
            stringPool: stringPool,
            rootPath: rootPath
        ) { ptr in
            String(cString: ptr)
        }

        #expect(cPath == tree.path(at: 2))
    }

    @Test("FileTree snapshot C path skips malformed name segment safely")
    func snapshotCPathSkipsMalformedSegment() {
        let tree = FileTree()
        tree.setRootPath("/Users")
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "Users")

        var child = FileNode()
        child.isDirectory = true
        tree.addChildren([(node: child, name: "Documents")], parentIndex: 0)

        var leaf = FileNode()
        leaf.fileSize = 100
        tree.addChildren([(node: leaf, name: "readme.txt")], parentIndex: 1)

        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()
        var malformedNodes = nodes
        malformedNodes[2].nameOffset = UInt32(stringPool.count + 8)
        malformedNodes[2].nameLength = 32

        let cPath = FileTree.withCPathFromSnapshot(
            at: 2,
            nodes: malformedNodes,
            stringPool: stringPool,
            rootPath: rootPath
        ) { ptr in
            String(cString: ptr)
        }

        #expect(cPath == "/Users/Documents")
    }

    @Test("Search index stays aligned with nodes after bulk insertion")
    func searchIndexAlignedAfterBulkInsertion() {
        let tree = FileTree()
        tree.setRootPath("/test")

        var root = FileNode()
        root.isDirectory = true
        _ = tree.addNode(root, name: "test")

        var children: [(node: FileNode, name: String)] = []
        let batchSize = 400
        children.reserveCapacity(batchSize)
        for i in 0..<batchSize {
            var node = FileNode()
            node.fileSize = UInt64(i + 1)
            let name = i.isMultiple(of: 2)
                ? "Item-\(i)-Caf\u{E9}.txt"
                : "Item-\(i)-Cafe\u{301}.txt"
            children.append((node: node, name: name))
        }
        tree.addChildren(children, parentIndex: 0)

        let nodes = tree.nodesSnapshot()
        let namePool = tree.stringPoolSnapshot()
        let (searchPool, searchEntries) = tree.searchIndexSnapshot()
        #expect(searchEntries.count == nodes.count)

        for i in 0..<nodes.count {
            let node = nodes[i]
            let nameStart = Int(node.nameOffset)
            let nameEnd = nameStart + Int(node.nameLength)
            guard nameEnd <= namePool.count,
                  let original = String(data: namePool[nameStart..<nameEnd], encoding: .utf8) else {
                Issue.record("Invalid name bytes at node \(i)")
                continue
            }
            let expected = original.precomposedStringWithCanonicalMapping.lowercased()

            let entry = searchEntries[i]
            let start = Int(entry.offset)
            let end = start + Int(entry.length)
            guard end <= searchPool.count,
                  let indexed = String(data: searchPool[start..<end], encoding: .utf8) else {
                Issue.record("Invalid search bytes at node \(i)")
                continue
            }
            #expect(indexed == expected)
        }

        let result = SearchEngine.search(
            query: "caf\u{E9}",
            nodes: nodes,
            searchPool: searchPool,
            searchEntries: searchEntries
        )
        #expect(result.totalMatches == batchSize)
    }

    @Test("sortAllChildren preserves subtree integrity across directories")
    func sortAllChildrenSubtreeStability() {
        let tree = FileTree()
        tree.setRootPath("/test")

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

    @Test("sortAllChildren correctly handles 3-element cycle (was buggy with old algorithm)")
    func sortAllChildrenThreeElementCycle() {
        // A(10), B(30), C(20) inserted in that order.
        // Sorted descending → B(30), C(20), A(10).
        // perm = [1, 2, 0] which forms a 3-cycle — the old broken algorithm
        // produced [C, A, B] (20, 10, 30) instead of the correct [B, C, A] (30, 20, 10).
        let tree = FileTree()
        tree.setRootPath("/test")
        var root = FileNode(); root.isDirectory = true
        tree.addNode(root, name: "test")

        var a = FileNode(); a.fileSize = 10
        var b = FileNode(); b.fileSize = 30
        var c = FileNode(); c.fileSize = 20
        tree.addChildren([
            (node: a, name: "a.txt"),
            (node: b, name: "b.txt"),
            (node: c, name: "c.txt"),
        ], parentIndex: 0)

        tree.sortAllChildren()

        let nodes = tree.nodesSnapshot()
        let first = Int(nodes[0].firstChildIndex)
        #expect(nodes[first].fileSize == 30, "Expected 30 (B) first, got \(nodes[first].fileSize)")
        #expect(nodes[first + 1].fileSize == 20, "Expected 20 (C) second, got \(nodes[first + 1].fileSize)")
        #expect(nodes[first + 2].fileSize == 10, "Expected 10 (A) third, got \(nodes[first + 2].fileSize)")
    }

    @Test("sortAllChildren skips already strictly-descending slices")
    func sortAllChildrenSkipsAlreadyStrictlyDescendingSlices() {
        let tree = FileTree()
        tree.setRootPath("/test")
        var root = FileNode(); root.isDirectory = true
        tree.addNode(root, name: "test")

        var large = FileNode(); large.fileSize = 90
        var medium = FileNode(); medium.fileSize = 40
        var small = FileNode(); small.fileSize = 10
        tree.addChildren([
            (node: large, name: "large.bin"),
            (node: medium, name: "medium.bin"),
            (node: small, name: "small.bin"),
        ], parentIndex: 0)

        let beforeNodes = tree.nodesSnapshot()
        let beforeSearchEntries = tree.searchIndexSnapshot().entries
        let rootFirstBefore = beforeNodes[0].firstChildIndex
        let namesBefore = (Int(rootFirstBefore)..<Int(rootFirstBefore) + 3).map {
            tree.name(at: UInt32($0))
        }

        tree.sortAllChildren()

        let afterNodes = tree.nodesSnapshot()
        let afterSearchEntries = tree.searchIndexSnapshot().entries
        let rootFirstAfter = afterNodes[0].firstChildIndex
        let namesAfter = (Int(rootFirstAfter)..<Int(rootFirstAfter) + 3).map {
            tree.name(at: UInt32($0))
        }

        #expect(rootFirstAfter == rootFirstBefore)
        #expect(namesAfter == namesBefore)
        #expect(afterSearchEntries.count == beforeSearchEntries.count)
        for i in 0..<min(afterSearchEntries.count, beforeSearchEntries.count) {
            #expect(afterSearchEntries[i].offset == beforeSearchEntries[i].offset)
            #expect(afterSearchEntries[i].length == beforeSearchEntries[i].length)
        }
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

private func legacyExtensionHash(_ name: String) -> UInt32 {
    guard let dotIndex = name.lastIndex(of: ".") else { return 0 }
    let ext = name[name.index(after: dotIndex)...].lowercased()
    guard !ext.isEmpty else { return 0 }
    var hash: UInt32 = 5381
    for byte in ext.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt32(byte)
    }
    return hash
}
@Suite("FileScanner Mock Tests")
struct FileScannerMockTests {

    // MARK: - Helpers

    /// Run a scan on a mock and return the finished tree.
    private func scan(
        root: String = "/root",
        mock: FilesystemProvider
    ) async -> FileTree {
        let scanner = FileScanner(filesystem: mock)
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)
        return tree
    }

    // MARK: - Test 1: Empty directory → only root node

    @Test("Empty directory produces tree with only root node")
    func emptyDirectoryOnlyRoot() async {
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = []  // accessible but empty

        let tree = await scan(mock: mock)

        #expect(tree.count == 1, "Empty root should produce exactly 1 node (the root)")
        let root = tree.nodes[0]
        #expect(root.isDirectory, "Root node must be a directory")
        #expect(root.fileSize == 0, "Empty directory should have zero size")
        #expect(root.parentIndex == FileNode.invalid, "Root has no parent")
        #expect(root.childCount == 0, "Root has no children")
    }

    // MARK: - Test 2: Single file → correct size on parent

    @Test("Single file has correct size accumulated on parent")
    func singleFileCorrectSize() async {
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = [
            MockFilesystemProvider.file(name: "data.bin", size: 4096, allocatedSize: 8192, inode: 1)
        ]

        let tree = await scan(mock: mock)

        // Nodes: root (index 0), data.bin (index 1)
        #expect(tree.count == 2, "Should have root + 1 file = 2 nodes")

        let root = tree.nodes[0]
        #expect(root.fileSize == 4096, "Root fileSize should equal the file's logical size")
        #expect(root.allocatedSize == 8192, "Root allocatedSize should equal the file's allocated size")
        #expect(root.childCount == 1)

        let fileNode = tree.nodes[1]
        #expect(!fileNode.isDirectory)
        #expect(fileNode.fileSize == 4096)
        #expect(fileNode.allocatedSize == 8192)
        #expect(fileNode.device == 1)
        #expect(fileNode.inode == 1)
        #expect(tree.name(at: 1) == "data.bin")
    }

    // MARK: - Test 3: Deep nesting (3 levels) → correct parent-child linkage

    @Test("Three-level nesting has correct parent-child linkage")
    func deepNestingParentChildLinkage() async {
        let mock = MockFilesystemProvider()
        // /root → subA/
        // /root/subA → subB/
        // /root/subA/subB → leaf.txt
        mock.directories["/root"] = [
            MockFilesystemProvider.dir(name: "subA", inode: 10)
        ]
        mock.directories["/root/subA"] = [
            MockFilesystemProvider.dir(name: "subB", inode: 11)
        ]
        mock.directories["/root/subA/subB"] = [
            MockFilesystemProvider.file(name: "leaf.txt", size: 512, inode: 12)
        ]

        let tree = await scan(mock: mock)

        // Expected: root(0), subA(1), subB(2), leaf.txt(3)
        // (exact indices may vary due to concurrent enqueuing, but the structure must be valid)
        #expect(tree.count == 4, "Should have root + subA + subB + leaf.txt = 4 nodes")

        // Validate every non-root node has a valid parent
        for i in 1..<tree.count {
            let node = tree.nodes[i]
            #expect(node.parentIndex != FileNode.invalid,
                "Node \(i) (\(tree.name(at: UInt32(i)))) must have a valid parent")
            #expect(Int(node.parentIndex) < tree.count,
                "Node \(i) parent index \(node.parentIndex) must be within bounds")
        }

        // Verify the leaf file exists and has correct size
        var leafIndex: UInt32? = nil
        for i in 0..<tree.count {
            if tree.name(at: UInt32(i)) == "leaf.txt" {
                leafIndex = UInt32(i)
                break
            }
        }
        #expect(leafIndex != nil, "leaf.txt must appear in the tree")
        if let li = leafIndex {
            #expect(tree.nodes[Int(li)].fileSize == 512)
        }

        // Root must have accumulated the leaf's size
        #expect(tree.nodes[0].fileSize == 512, "Root must accumulate leaf size through 3 levels")
    }

    // MARK: - Test 4: Large directory (1000 files) → all nodes present

    @Test("Large directory with 1000 files contains all nodes")
    func largeDirectoryAllNodesPresent() async {
        let mock = MockFilesystemProvider()
        var entries: [DirectoryEntry] = []
        for i in 0..<1000 {
            entries.append(MockFilesystemProvider.file(
                name: "file\(i).dat",
                size: UInt64(i + 1),
                inode: UInt64(100 + i)
            ))
        }
        mock.directories["/root"] = entries

        let tree = await scan(mock: mock)

        // root + 1000 files = 1001 nodes
        #expect(tree.count == 1001, "Should have root + 1000 file nodes")

        // Root's accumulated size should equal 1+2+…+1000 = 500500
        let expectedTotal: UInt64 = (1...1000).reduce(0) { $0 + UInt64($1) }
        #expect(tree.nodes[0].fileSize == expectedTotal,
            "Root fileSize should be sum of all file sizes: got \(tree.nodes[0].fileSize), want \(expectedTotal)")
    }

    // MARK: - Test 5: Mixed files and subdirectories → correct isDirectory flags

    @Test("Mixed files and subdirectories have correct isDirectory flags")
    func mixedFilesAndDirsCorrectFlags() async {
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = [
            MockFilesystemProvider.file(name: "readme.txt", size: 100, inode: 1),
            MockFilesystemProvider.dir(name: "docs", inode: 2),
            MockFilesystemProvider.file(name: "image.png", size: 500, inode: 3),
            MockFilesystemProvider.dir(name: "src", inode: 4),
            MockFilesystemProvider.symlink(name: "link", inode: 5),  // should be skipped
        ]
        mock.directories["/root/docs"] = []
        mock.directories["/root/src"] = [
            MockFilesystemProvider.file(name: "main.swift", size: 2048, inode: 6)
        ]

        let tree = await scan(mock: mock)

        // Expected nodes: root, readme.txt, docs, image.png, src, main.swift
        // Symlink is skipped by FileScanner.
        #expect(tree.count == 6,
            "Should have 6 nodes (symlink excluded): got \(tree.count)")

        // Collect names and their isDirectory flags
        var nameToIsDir: [String: Bool] = [:]
        for i in 0..<tree.count {
            nameToIsDir[tree.name(at: UInt32(i))] = tree.nodes[i].isDirectory
        }

        #expect(nameToIsDir["readme.txt"] == false)
        #expect(nameToIsDir["image.png"] == false)
        #expect(nameToIsDir["docs"] == true)
        #expect(nameToIsDir["src"] == true)
        #expect(nameToIsDir["link"] == nil, "Symlink should not appear in tree")
    }

    // MARK: - Test 6: Cancelled scan → no crash, tree partially populated

    @Test("Cancelled scan does not crash and tree is partially valid")
    func cancelledScanNoCrash() async {
        // Build a mock with enough directories to make cancellation mid-scan plausible.
        let mock = MockFilesystemProvider()
        var rootEntries: [DirectoryEntry] = []
        for i in 0..<50 {
            let dirName = "subdir\(i)"
            rootEntries.append(MockFilesystemProvider.dir(name: dirName, inode: UInt64(i + 1)))
            var subdirEntries: [DirectoryEntry] = []
            for j in 0..<20 {
                subdirEntries.append(MockFilesystemProvider.file(
                    name: "file\(j).dat",
                    size: UInt64(j + 1),
                    inode: UInt64(10000 + i * 20 + j)
                ))
            }
            mock.directories["/root/\(dirName)"] = subdirEntries
        }
        mock.directories["/root"] = rootEntries

        // Cancel concurrently once the scan has started.
        // scan() resets the cancel flag at its start, so pre-cancelling is a no-op;
        // we use a concurrent Task to race cancel() against the running scan instead.
        let scanner = FileScanner(filesystem: mock)
        let progress = ScanProgress()
        let tree = FileTree()
        let cancelTask = Task {
            // Yield once to let scan() start and create its OperationQueue.
            await Task.yield()
            scanner.cancel()
        }
        await scanner.scan(path: "/root", progress: progress, tree: tree)
        await cancelTask.value

        // The tree must have at least the root node and no out-of-bounds parent references.
        #expect(tree.count >= 1, "Cancelled scan must still produce at least root node")
        #expect(progress.scanComplete, "Scan should be marked complete even when cancelled")
        // Plan 040 pin: a cancelled scan must not strand `isScanning == true` — `scan()`'s
        // finalization block runs unconditionally after the worker pool drains, cancelled
        // or not, so this must always clear. If a future change to `scan()` adds an early
        // return before that finalization, this is the regression it would trip.
        #expect(!progress.isScanning, "isScanning must be cleared even when the scan was cancelled")

        for i in 1..<tree.count {
            let node = tree.nodes[i]
            if node.parentIndex != FileNode.invalid {
                #expect(Int(node.parentIndex) < tree.count,
                    "Parent index \(node.parentIndex) for node \(i) must be within bounds")
            }
        }
    }

    // MARK: - Test 7: Permission-denied directory counted as skipped

    @Test("Permission-denied directory is counted as skipped")
    func permissionDeniedDirectorySkipped() async {
        let mock = FailingMockFilesystemProvider()
        mock.inner.directories["/root"] = [
            MockFilesystemProvider.dir(name: "private", inode: 99)
        ]
        mock.failingPaths.insert("/root/private")

        let scanner = FileScanner(filesystem: mock)
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: "/root", progress: progress, tree: tree)

        // The "private" dir node is added to the tree (as a directory entry),
        // then when its contents are scanned, open() fails → skipped.
        // Tree: root + private = 2 nodes
        #expect(tree.count == 2)
        await MainActor.run {
            progress.publishCounters()
            #expect(progress.skippedDirectories == 1,
                "One directory was unreadable so skippedDirectories should be 1")
        }
    }

    // MARK: - Test 8: Firmlink deduplication via (dev, inode)

    @Test("Directories with duplicate (dev, inode) are visited only once (firmlink dedup)")
    func firmlinkDeduplication() async {
        // /root has two dirs with the SAME inode — second should be skipped
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = [
            MockFilesystemProvider.dir(name: "realDir", inode: 42, device: 1),
            MockFilesystemProvider.dir(name: "firmlink", inode: 42, device: 1), // same inode
        ]
        mock.directories["/root/realDir"] = [
            MockFilesystemProvider.file(name: "file.txt", size: 100, inode: 99)
        ]
        mock.directories["/root/firmlink"] = [
            // This would add a duplicate "file.txt" if dedup doesn't work
            MockFilesystemProvider.file(name: "file2.txt", size: 200, inode: 100)
        ]

        let tree = await scan(mock: mock)

        // Only realDir should be recursed (first seen wins).
        // Nodes: root, realDir, firmlink, file.txt = 4
        // file2.txt must NOT appear (firmlink skipped)
        var names = Set<String>()
        for i in 0..<tree.count { names.insert(tree.name(at: UInt32(i))) }
        #expect(!names.contains("file2.txt"),
            "file2.txt from the firmlink directory must not appear (inode dedup)")
        #expect(names.contains("file.txt"),
            "file.txt from the real directory must appear")
    }

    // MARK: - Test 9: Extension hash set correctly on file nodes

    @Test("Extension hash is set on file nodes")
    func extensionHashSetOnFileNodes() async {
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = [
            MockFilesystemProvider.file(name: "report.pdf", size: 1000, inode: 1),
            MockFilesystemProvider.file(name: "Makefile", size: 500, inode: 2), // no extension
        ]

        let tree = await scan(mock: mock)

        var pdfNode: FileNode? = nil
        var makefileNode: FileNode? = nil
        for i in 0..<tree.count {
            let name = tree.name(at: UInt32(i))
            if name == "report.pdf" { pdfNode = tree.nodes[i] }
            if name == "Makefile"   { makefileNode = tree.nodes[i] }
        }

        #expect(pdfNode != nil)
        #expect(makefileNode != nil)
        if let pdf = pdfNode {
            #expect(pdf.extensionHash == extensionHash("report.pdf"),
                "extensionHash should match for .pdf file")
            #expect(pdf.extensionHash != 0)
        }
        if let mf = makefileNode {
            #expect(mf.extensionHash == 0, "File with no extension should have hash 0")
        }
    }

    // MARK: - Test 10: Scan progress counters are updated

    @Test("Scan progress counters reflect scanned files and directories")
    func scanProgressCounters() async {
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = [
            MockFilesystemProvider.file(name: "a.txt", size: 100, inode: 1),
            MockFilesystemProvider.file(name: "b.txt", size: 200, inode: 2),
            MockFilesystemProvider.dir(name: "subdir", inode: 3),
        ]
        mock.directories["/root/subdir"] = [
            MockFilesystemProvider.file(name: "c.txt", size: 300, inode: 4),
        ]

        let scanner = FileScanner(filesystem: mock)
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: "/root", progress: progress, tree: tree)

        await MainActor.run {
            progress.publishCounters()
            #expect(progress.filesScanned == 3, "Should count 3 files total")
            #expect(progress.directoriesScanned == 1, "Should count 1 subdirectory")
            #expect(progress.scanComplete)
            #expect(!progress.isCancelled)
        }
    }

    // MARK: - Test 11: Scanner is reusable after cancel()

    @Test("Scanner produces results when reused after cancel()")
    func scannerReusableAfterCancel() async {
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = [
            MockFilesystemProvider.file(name: "a.txt", size: 100, inode: 1),
            MockFilesystemProvider.file(name: "b.txt", size: 200, inode: 2),
        ]

        let scanner = FileScanner(filesystem: mock)

        // First scan: cancel immediately.
        let tree1 = FileTree()
        scanner.cancel()
        await scanner.scan(path: "/root", progress: ScanProgress(), tree: tree1)
        // tree1 may be empty or partial; what matters is the scanner's cancel flag is reset.

        // Second scan with the same scanner instance: must not be sticky-cancelled.
        let tree2 = FileTree()
        let progress2 = ScanProgress()
        await scanner.scan(path: "/root", progress: progress2, tree: tree2)

        // The second scan should complete normally and find all files.
        #expect(tree2.count >= 1, "Reused scanner must populate tree2 (got \(tree2.count) nodes)")
        await MainActor.run {
            progress2.publishCounters()
            #expect(!progress2.isCancelled, "Second scan should not be cancelled")
            #expect(progress2.scanComplete, "Second scan should complete")
        }
    }

    // MARK: - Test 12: UInt64.max inode counts do not trap

    @Test("volumeStats with UInt64.max inode counts does not crash")
    func largeInodeCountsDoNotTrap() async {
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = [
            MockFilesystemProvider.file(name: "a.txt", size: 1, inode: 1),
        ]
        // Simulate a pathological statfs result with maximum UInt64 values.
        mock.mockVolumeStats = StatfsResult(
            totalFiles: UInt64.max,
            freeFiles: UInt64.max - 1,
            filesystemType: "apfs"
        )

        let scanner = FileScanner(filesystem: mock)
        let tree = FileTree()
        // Must not trap with Fatal error: Not enough bits to represent the passed value.
        await scanner.scan(path: "/root", progress: ScanProgress(), tree: tree)
        #expect(tree.count >= 1)
    }

    @Test("subdirectory scan suppresses volume-wide progress estimate")
    func subdirectoryScanSuppressesVolumeEstimate() async {
        let mock = MockFilesystemProvider()
        mock.directories["/root"] = [
            MockFilesystemProvider.file(name: "a.txt", size: 100, inode: 1),
        ]
        mock.mockVolumeStats = StatfsResult(
            totalFiles: 10_000,
            freeFiles: 8_000,
            filesystemType: "apfs",
            mountPoint: "/"
        )

        let progress = ScanProgress()
        let scanner = FileScanner(filesystem: mock)
        let tree = FileTree()
        await scanner.scan(path: "/root", progress: progress, tree: tree)

        await MainActor.run {
            #expect(progress.estimatedTotalItems == 0,
                "Subdirectory scans should not publish a misleading whole-volume estimate")
        }
    }

    @Test("mount-root scan keeps volume-wide progress estimate")
    func mountRootScanKeepsVolumeEstimate() async {
        let mock = MockFilesystemProvider()
        mock.directories["/"] = [
            MockFilesystemProvider.file(name: "a.txt", size: 100, inode: 1),
        ]
        mock.inodeMap["/"] = (device: 1, inode: 1)
        mock.mockVolumeStats = StatfsResult(
            totalFiles: 10_000,
            freeFiles: 8_000,
            filesystemType: "apfs",
            mountPoint: "/"
        )

        let progress = ScanProgress()
        let scanner = FileScanner(filesystem: mock)
        let tree = FileTree()
        await scanner.scan(path: "/", progress: progress, tree: tree)

        await MainActor.run {
            #expect(progress.estimatedTotalItems == 4_000,
                "Root scans should include the Data volume inode estimate as well")
        }
    }

    @Test("Real filesystem deferred scan preserves tree structure")
    func realFilesystemDeferredScanPreservesTreeStructure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirwiz-deferred-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("alpha/beta", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sample.app/Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("one".utf8).write(to: root.appendingPathComponent("alpha/a.txt"))
        try Data("two".utf8).write(to: root.appendingPathComponent("alpha/beta/b.txt"))
        try Data("bundle".utf8).write(to: root.appendingPathComponent("Sample.app/Contents/info.txt"))

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root.path, progress: progress, tree: tree)

        #expect(progress.scanComplete)
        #expect(tree.count >= 5)

        var paths: [String: FileNode] = [:]
        for i in 0..<tree.count {
            let index = UInt32(i)
            paths[tree.path(at: index)] = tree.nodes[i]
            let node = tree.nodes[i]
            if node.parentIndex != FileNode.invalid {
                #expect(Int(node.parentIndex) < tree.count)
            }
            if node.firstChildIndex != FileNode.invalid {
                let start = Int(node.firstChildIndex)
                let end = start + Int(node.childCount)
                #expect(start >= 0)
                #expect(end <= tree.count)
                for childIndex in start..<end {
                    #expect(tree.nodes[childIndex].parentIndex == index)
                }
            }
        }

        let alphaPath = root.appendingPathComponent("alpha").path
        let betaPath = root.appendingPathComponent("alpha/beta").path
        let filePath = root.appendingPathComponent("alpha/beta/b.txt").path
        let bundlePath = root.appendingPathComponent("Sample.app").path

        #expect(paths[alphaPath]?.isDirectory == true)
        #expect(paths[betaPath]?.isDirectory == true)
        #expect(paths[filePath]?.isDirectory == false)
        #expect(paths[bundlePath]?.isBundle == true)
        #expect((paths[bundlePath]?.displaySize ?? 0) > 0)
    }

    // MARK: - Immediate-raw vs deferred materialization equivalence
    //
    // `DIRWIZ_DEFER_TREE=0` is the only way to reach the immediate raw-materialization
    // path (`scanDirectoryRaw`) against a real filesystem in production, and until now
    // no test exercised it — it was environment-gated and skipped by every other test.
    // `FileScanner.init` already accepts `deferTreeMaterialization` as a constructor
    // parameter, so this threads the flag directly instead of touching the environment.

    private struct ScanNodeSummary: Equatable {
        let isDirectory: Bool
        let isBundle: Bool
        let fileSize: UInt64
        let allocatedSize: UInt64
        let childCount: UInt32
    }

    private func summarize(_ tree: FileTree) -> [String: ScanNodeSummary] {
        var result: [String: ScanNodeSummary] = [:]
        for i in 0..<tree.count {
            let node = tree.nodes[i]
            result[tree.path(at: UInt32(i))] = ScanNodeSummary(
                isDirectory: node.isDirectory,
                isBundle: node.isBundle,
                fileSize: node.fileSize,
                allocatedSize: node.allocatedSize,
                childCount: node.childCount
            )
        }
        return result
    }

    @Test("Immediate raw materialization matches deferred materialization on the same fixture")
    func immediateRawMatchesDeferredMaterialization() async throws {
        let (root, cleanup) = try createTempTree([
            "alpha/a.txt": 4096,
            "alpha/beta/b.txt": 8192,
            "alpha/beta/empty_dir/": 0,
            "Sample.app/Contents/Resources/data.bin": 16384,
            "loose.txt": 100,
        ])
        defer { cleanup() }

        let immediateScanner = FileScanner(deferTreeMaterialization: false)
        let immediateProgress = ScanProgress()
        let immediateTree = FileTree()
        await immediateScanner.scan(path: root, progress: immediateProgress, tree: immediateTree)

        let deferredScanner = FileScanner(deferTreeMaterialization: true)
        let deferredProgress = ScanProgress()
        let deferredTree = FileTree()
        await deferredScanner.scan(path: root, progress: deferredProgress, tree: deferredTree)

        #expect(immediateProgress.scanComplete)
        #expect(deferredProgress.scanComplete)
        #expect(immediateTree.count == deferredTree.count,
            "Same fixture must produce the same total node count regardless of materialization strategy")

        let immediateByPath = summarize(immediateTree)
        let deferredByPath = summarize(deferredTree)

        #expect(Set(immediateByPath.keys) == Set(deferredByPath.keys),
            "Both materialization strategies must produce the same set of paths (same child sets)")

        for (nodePath, immediateValue) in immediateByPath {
            guard let deferredValue = deferredByPath[nodePath] else {
                Issue.record("Path \(nodePath) present in immediate scan but missing from deferred scan")
                continue
            }
            #expect(immediateValue == deferredValue, "Node summary mismatch at \(nodePath): immediate \(immediateValue) vs deferred \(deferredValue)")
        }

        // Root aggregate sizes must match across strategies.
        let immediateRoot = immediateTree.nodes[0]
        let deferredRoot = deferredTree.nodes[0]
        #expect(immediateRoot.fileSize == deferredRoot.fileSize, "Root fileSize must match across strategies")
        #expect(immediateRoot.allocatedSize == deferredRoot.allocatedSize, "Root allocatedSize must match across strategies")

        // The bundle must have actually resolved to a non-zero size in both strategies —
        // this is the one place the two strategies genuinely differ in internal sequencing
        // (immediate publishes to the tree then patches the bundle size in place; deferred
        // bakes the bundle size into the scratch buffer before it is copied into the arena).
        // A coincidental both-zero result would pass the equality checks above without
        // actually exercising that difference.
        guard let bundleInfo = immediateByPath[root + "/Sample.app"] else {
            Issue.record("Sample.app bundle not found in immediate scan")
            return
        }
        #expect(bundleInfo.isBundle)
        #expect(bundleInfo.fileSize == 16384)
    }
}
