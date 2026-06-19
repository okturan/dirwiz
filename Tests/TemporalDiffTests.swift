import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

// MARK: - Test Helpers

/// Build an in-memory FileTree with a root directory and child directories/files.
/// `rootPath`: the absolute root path for the tree.
/// `dirs`: child directories to add under root, each with a name and a pre-set fileSize.
/// `files`: files to add under a specific parent index, each with name and fileSize.
/// Returns a fully wired tree (no disk I/O).
private func makeTree(
    rootPath: String = "/TestRoot",
    dirs: [(name: String, size: UInt64)] = [],
    files: [(parent: Int, name: String, size: UInt64)] = []
) -> FileTree {
    let tree = FileTree()
    tree.setRootPath(rootPath)

    // Root node (index 0) — its fileSize will be the sum of all content.
    var root = FileNode()
    root.isDirectory = true
    tree.addNode(root, name: rootPath.split(separator: "/").last.map(String.init) ?? "root")

    // Add child directories under root (indices 1..<1+dirs.count).
    if !dirs.isEmpty {
        let children: [(node: FileNode, name: String)] = dirs.map { entry in
            var node = FileNode()
            node.isDirectory = true
            node.fileSize = entry.size
            return (node: node, name: entry.name)
        }
        tree.addChildren(children, parentIndex: 0)
    }

    // Add files under specified parents.
    // Group files by parent for batch insertion.
    var byParent: [Int: [(name: String, size: UInt64)]] = [:]
    for f in files {
        byParent[f.parent, default: []].append((f.name, f.size))
    }
    for (parentIdx, entries) in byParent.sorted(by: { $0.key < $1.key }) {
        let children: [(node: FileNode, name: String)] = entries.map { entry in
            var node = FileNode()
            node.fileSize = entry.size
            return (node: node, name: entry.name)
        }
        tree.addChildren(children, parentIndex: UInt32(parentIdx))
    }

    // Accumulate sizes up to root so root.fileSize reflects total.
    let nodes = tree.nodesSnapshot()
    var rootSize: UInt64 = 0
    for i in 1..<nodes.count {
        if !nodes[i].isDirectory {
            rootSize += nodes[i].fileSize
        }
    }
    // Also add directory sizes (they may represent pre-computed subtree sizes).
    for d in dirs {
        rootSize += d.size
    }
    tree.updateNode(at: 0) { node in
        node.fileSize = rootSize
    }

    return tree
}

/// Build a snapshot directly from a path-to-size dictionary, bypassing the tree.
private func makeSnapshot(
    rootPath: String = "/TestRoot",
    byPath: [String: UInt64]
) -> TemporalSnapshot {
    let total = byPath[""] ?? byPath.values.reduce(0, +)
    let meta = TemporalSnapshotMeta(
        id: UUID(),
        createdAt: Date(),
        rootPath: rootPath,
        totalBytes: total,
        dirCount: byPath.count
    )
    return TemporalSnapshot(meta: meta, byPath: byPath)
}

// MARK: - Tests

@Suite("TemporalDiffService Tests")
struct TemporalDiffTests {

    // MARK: 1. Snapshot Building

    @Test("buildSnapshot captures directory paths and sizes")
    func snapshotBuilding() async {
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Documents", 5_000_000), ("Photos", 10_000_000)]
        )

        let snapshot = await TemporalDiffService.buildSnapshot(tree: tree)

        #expect(snapshot.meta.rootPath == "/TestRoot")
        #expect(snapshot.meta.dirCount == 3, "Should have root + 2 dirs = 3 directory entries")

        // Root is mapped to "" (empty string, lowercased relative path).
        #expect(snapshot.byPath[""] != nil, "Root should be in snapshot as empty string")

        // Child dirs should appear as lowercased relative paths.
        #expect(snapshot.byPath["documents"] == 5_000_000)
        #expect(snapshot.byPath["photos"] == 10_000_000)
    }

    // MARK: 2. No Change

    @Test("Identical snapshot and tree yields all .none")
    func noChange() async {
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Documents", 50_000_000)]
        )

        // Build snapshot from same tree — sizes match exactly.
        let snapshot = await TemporalDiffService.buildSnapshot(tree: tree)
        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        for i in 0..<result.kinds.count {
            #expect(result.kinds[i] == TemporalDiffKind.none.rawValue,
                "Node \(i) should be .none when nothing changed")
        }
        #expect(result.deletedByNode.isEmpty, "No deleted descendants expected")
    }

    // MARK: 3. New Directory

    @Test("Directory in tree but not in snapshot is classified as .new")
    func newDirectory() async {
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Documents", 50_000_000), ("NewFolder", 20_000_000)]
        )

        // Snapshot only knows about root + Documents.
        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 50_000_000,
            "documents": 50_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        // Find NewFolder (index 2, the second child dir).
        #expect(result.kinds[2] == TemporalDiffKind.new.rawValue,
            "NewFolder should be classified as .new")
        #expect(result.strengths[2] > 0, "New directory should have positive strength")
    }

    // MARK: 4. Grown Directory

    @Test("Directory that grew beyond threshold is classified as .grown")
    func grownDirectory() async {
        // Old size = 100MB, new size = 200MB.
        // Threshold = max(4MB, 100MB/20) = 5MB. Delta = 100MB >> 5MB → .grown.
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("BigDir", 200_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 100_000_000,
            "bigdir": 100_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        #expect(result.kinds[1] == TemporalDiffKind.grown.rawValue,
            "BigDir should be classified as .grown")
        #expect(result.strengths[1] > 0, "Grown directory should have positive strength")
        #expect(result.strengths[1] <= 1.0, "Strength should be capped at 1.0")
    }

    // MARK: 5. Shrunk Directory

    @Test("Directory that shrank beyond threshold is classified as .shrunk")
    func shrunkDirectory() async {
        // Old size = 200MB, new size = 50MB.
        // Threshold = max(4MB, 200MB/20) = 10MB. Delta = 150MB >> 10MB → .shrunk.
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("ShrinkDir", 50_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 200_000_000,
            "shrinkdir": 200_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        #expect(result.kinds[1] == TemporalDiffKind.shrunk.rawValue,
            "ShrinkDir should be classified as .shrunk")
        #expect(result.strengths[1] > 0, "Shrunk directory should have positive strength")
    }

    // MARK: 6. Below Threshold

    @Test("Small change within threshold is classified as .none")
    func belowThreshold() async {
        // Old size = 100MB, new size = 102MB.
        // Threshold = max(4MB, 100MB/20) = 5MB. Delta = 2MB < 5MB → .none.
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("StableDir", 102_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 100_000_000,
            "stabledir": 100_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        #expect(result.kinds[1] == TemporalDiffKind.none.rawValue,
            "StableDir should be .none when change is below threshold")
        #expect(result.strengths[1] == 0, "Below-threshold should have zero strength")
    }

    @Test("Small directory uses 4MB absolute threshold floor")
    func absoluteThresholdFloor() async {
        // Old size = 10MB, new size = 13MB.
        // Threshold = max(4MB, 10MB/20) = max(4MB, 0.5MB) = 4MB. Delta = 3MB < 4MB → .none.
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("SmallDir", 13_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 10_000_000,
            "smalldir": 10_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        #expect(result.kinds[1] == TemporalDiffKind.none.rawValue,
            "3MB change on 10MB dir should be below 4MB absolute threshold")
    }

    // MARK: 7. Deleted Descendants

    @Test("Deleted snapshot path aggregates to nearest surviving ancestor")
    func deletedDescendants() async {
        // Current tree has root + Documents. Snapshot also had Documents/OldSub.
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Documents", 50_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 60_000_000,
            "documents": 60_000_000,
            "documents/oldsub": 10_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        // "documents/oldsub" is deleted — should aggregate to "documents" (index 1).
        #expect(result.deletedByNode[1] != nil,
            "Documents should have deleted descendants")
        #expect(result.deletedByNode[1]?.count == 1,
            "Should have 1 deleted descendant")
        #expect(result.deletedByNode[1]?.bytes == 10_000_000,
            "Deleted bytes should be 10MB")

        // Documents was 60MB→50MB, delta = 10MB, threshold = max(4MB, 60MB/20=3MB) = 4MB.
        // 10MB > 4MB → .shrunk takes priority over .deletedDescendants.
        // The code only marks .deletedDescendants if the node is .none, so with the
        // significant shrink, it stays .shrunk.
        let docsKind = TemporalDiffKind(rawValue: result.kinds[1])
        #expect(docsKind == .shrunk || docsKind == .deletedDescendants,
            "Documents should be .shrunk (priority) or .deletedDescendants")
    }

    @Test("Deleted path with no size change marks ancestor as .deletedDescendants")
    func deletedDescendantsNoSizeChange() async {
        // Documents stayed the same size but lost a sub-directory.
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Documents", 50_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 50_000_000,
            "documents": 50_000_000,
            "documents/oldsub": 5_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        // Documents has no size change → .none initially.
        // Then the deleted descendant pass should mark it .deletedDescendants.
        #expect(result.kinds[1] == TemporalDiffKind.deletedDescendants.rawValue,
            "Documents should be .deletedDescendants when it has no size change but lost a sub-dir")
        #expect(result.strengths[1] == 0.55,
            "deletedDescendants strength should be 0.55")
    }

    // MARK: 8. Multiple Deleted Under Same Ancestor

    @Test("Multiple deleted paths aggregate to same surviving ancestor")
    func multipleDeletedSameAncestor() async {
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Documents", 50_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 50_000_000,
            "documents": 50_000_000,
            "documents/old1": 3_000_000,
            "documents/old2": 7_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        let summary = result.deletedByNode[1]
        #expect(summary != nil, "Documents should have deleted descendants")
        #expect(summary?.count == 2, "Should aggregate 2 deleted paths")
        #expect(summary?.bytes == 10_000_000, "Should aggregate 3MB + 7MB = 10MB")
    }

    // MARK: 9. Snapshot Save/Load Round-Trip

    @Test("Snapshot save and load preserves meta and byPath")
    func snapshotSaveLoadRoundTrip() async throws {
        let tempSupportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirWizAppSupport_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempSupportRoot, withIntermediateDirectories: true)
        let previousOverride = ProcessInfo.processInfo.environment["DIRWIZ_APP_SUPPORT_DIR"]
        setenv("DIRWIZ_APP_SUPPORT_DIR", tempSupportRoot.path, 1)
        defer {
            if let previousOverride {
                setenv("DIRWIZ_APP_SUPPORT_DIR", previousOverride, 1)
            } else {
                unsetenv("DIRWIZ_APP_SUPPORT_DIR")
            }
            try? FileManager.default.removeItem(at: tempSupportRoot)
        }

        let tree = makeTree(
            rootPath: "/tmp/DirWizTest_\(UUID().uuidString)",
            dirs: [("Alpha", 1_000_000), ("Beta", 2_000_000)]
        )

        let original = await TemporalDiffService.buildSnapshot(tree: tree)
        try original.save()

        let loaded = try TemporalSnapshot.load(for: original.meta.rootPath)
        #expect(loaded != nil, "Should load saved snapshot")

        guard let loaded else { return }

        #expect(loaded.meta.rootPath == original.meta.rootPath)
        #expect(loaded.meta.totalBytes == original.meta.totalBytes)
        #expect(loaded.meta.dirCount == original.meta.dirCount)
        #expect(loaded.meta.id == original.meta.id)
        #expect(loaded.byPath.count == original.byPath.count)

        for (path, size) in original.byPath {
            #expect(loaded.byPath[path] == size,
                "Path '\(path)' should have size \(size), got \(loaded.byPath[path] as Any)")
        }

        // Clean up the saved file.
        let url = TemporalSnapshot.snapshotURL(for: original.meta.rootPath)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: 10. Empty Tree

    @Test("Empty tree produces empty diff result")
    func emptyTree() async {
        let tree = FileTree()
        tree.setRootPath("/Empty")
        // Don't add any nodes.

        let snapshot = makeSnapshot(rootPath: "/Empty", byPath: [:])
        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        #expect(result.kinds.isEmpty, "Empty tree should produce empty kinds")
        #expect(result.strengths.isEmpty, "Empty tree should produce empty strengths")
        #expect(result.deletedByNode.isEmpty, "Empty tree should produce empty deletedByNode")
    }

    @Test("Empty tree produces empty snapshot")
    func emptyTreeSnapshot() async {
        let tree = FileTree()
        tree.setRootPath("/Empty")

        let snapshot = await TemporalDiffService.buildSnapshot(tree: tree)
        #expect(snapshot.byPath.isEmpty, "Empty tree should produce empty byPath")
        #expect(snapshot.meta.totalBytes == 0)
        #expect(snapshot.meta.dirCount == 0)
    }

    // MARK: - Edge Cases

    @Test("logStrength is bounded between 0 and 1")
    func strengthBounds() async {
        // Massive growth: 1MB → 10GB (10000x increase).
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Huge", 10_000_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 1_000_000,
            "huge": 1_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        #expect(result.strengths[1] >= 0, "Strength should be >= 0")
        #expect(result.strengths[1] <= 1.0, "Strength should be <= 1.0")
        #expect(result.kinds[1] == TemporalDiffKind.grown.rawValue)
    }

    @Test("Case-insensitive path matching works")
    func caseInsensitiveMatching() async {
        // Tree has "Documents" → relative path becomes "documents" (lowercased).
        // Snapshot has "documents" — should match.
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Documents", 50_000_000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 50_000_000,
            "documents": 50_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        // Should match and be .none (no change).
        #expect(result.kinds[1] == TemporalDiffKind.none.rawValue,
            "Case-insensitive matching should find Documents as 'documents'")
    }

    @Test("Deleted path with no surviving ancestor aggregates to root")
    func deletedAggregateToRoot() async {
        // Only root in current tree. Snapshot had root + a child dir.
        let tree = FileTree()
        tree.setRootPath("/TestRoot")
        var root = FileNode()
        root.isDirectory = true
        root.fileSize = 10_000_000
        tree.addNode(root, name: "TestRoot")

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 20_000_000,
            "vanished": 10_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        // "vanished" is deleted. Nearest ancestor lookup: parent of "vanished" is "" (root).
        // Root is at index 0.
        #expect(result.deletedByNode[0] != nil,
            "Deleted path should aggregate to root (index 0)")
        #expect(result.deletedByNode[0]?.bytes == 10_000_000)
    }

    @Test("Files (non-directories) are ignored in diff classification")
    func filesIgnoredInDiff() async {
        let tree = makeTree(
            rootPath: "/TestRoot",
            dirs: [("Documents", 50_000_000)],
            files: [(1, "readme.txt", 1000)]
        )

        let snapshot = makeSnapshot(rootPath: "/TestRoot", byPath: [
            "": 50_000_000,
            "documents": 50_000_000,
        ])

        let result = await TemporalDiffService.computeDiff(currentTree: tree, snapshot: snapshot)

        // File node (index 2) should remain .none — diff only classifies directories.
        #expect(result.kinds[2] == TemporalDiffKind.none.rawValue,
            "File nodes should stay .none (not classified)")
    }
}
