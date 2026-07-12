import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Equivalence gate for `FileScanner.rescanSubtrees`: every test here builds a fixture,
/// cold-scans it, mutates the filesystem, splices via `rescanSubtrees`, then cold-scans
/// the same (now-mutated) fixture into a second tree and asserts the two are structurally
/// indistinguishable. A partially-correct splice must not pass any of these.
@Suite("Subtree Rescan Tests")
struct SubtreeRescanTests {

    private struct NodeSummary: Equatable, CustomStringConvertible {
        let isDirectory: Bool
        let isBundle: Bool
        let fileSize: UInt64
        let allocatedSize: UInt64
        let childCount: UInt32

        var description: String {
            "(dir: \(isDirectory), bundle: \(isBundle), size: \(fileSize), alloc: \(allocatedSize), children: \(childCount))"
        }
    }

    private func summarize(_ tree: FileTree) -> [String: NodeSummary] {
        var result: [String: NodeSummary] = [:]
        for i in 0..<tree.count {
            let node = tree.nodes[i]
            result[tree.path(at: UInt32(i))] = NodeSummary(
                isDirectory: node.isDirectory,
                isBundle: node.isBundle,
                fileSize: node.fileSize,
                allocatedSize: node.allocatedSize,
                childCount: node.childCount
            )
        }
        return result
    }

    /// Asserts `actual` is structurally indistinguishable from `expected`: same path set,
    /// per-path fileSize/allocatedSize/isDirectory/childCount, and equal root aggregate
    /// totals. `expected` is typically a fresh cold scan of the same on-disk fixture.
    private func assertTreesEquivalent(_ actual: FileTree, _ expected: FileTree, _ context: String) {
        let actualByPath = summarize(actual)
        let expectedByPath = summarize(expected)

        #expect(Set(actualByPath.keys) == Set(expectedByPath.keys),
            "\(context): path sets differ (actual: \(actualByPath.keys.sorted()), expected: \(expectedByPath.keys.sorted()))")

        for (path, expectedValue) in expectedByPath {
            guard let actualValue = actualByPath[path] else {
                Issue.record("\(context): path \(path) missing from the rescanned tree")
                continue
            }
            #expect(actualValue == expectedValue,
                "\(context): mismatch at \(path): rescanned \(actualValue) vs cold \(expectedValue)")
        }

        guard !actual.isEmpty, !expected.isEmpty else {
            Issue.record("\(context): one of the trees is empty")
            return
        }
        let actualRoot = actual.nodes[0]
        let expectedRoot = expected.nodes[0]
        #expect(actualRoot.fileSize == expectedRoot.fileSize,
            "\(context): root fileSize mismatch (rescanned \(actualRoot.fileSize) vs cold \(expectedRoot.fileSize))")
        #expect(actualRoot.allocatedSize == expectedRoot.allocatedSize,
            "\(context): root allocatedSize mismatch (rescanned \(actualRoot.allocatedSize) vs cold \(expectedRoot.allocatedSize))")
    }

    private func coldScan(_ path: String) async -> FileTree {
        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)
        return tree
    }

    @Test("Files added to an existing dir")
    func filesAdded() async throws {
        let (root, cleanup) = try createTempTree([
            "docs/readme.txt": 100,
            "docs/notes.md": 200,
            "images/photo.jpg": 500,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        try Data(count: 300).write(to: URL(fileURLWithPath: root).appendingPathComponent("docs/added.log"))

        let report = await scanner.rescanSubtrees([root + "/docs"], tree: tree, progress: progress)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.rescannedRoots == [root + "/docs"])

        let coldTree = await coldScan(root)
        assertTreesEquivalent(tree, coldTree, "filesAdded")
    }

    @Test("Files deleted, including the dir becoming empty")
    func filesDeleted() async throws {
        let (root, cleanup) = try createTempTree([
            "docs/readme.txt": 100,
            "docs/notes.md": 200,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        try FileManager.default.removeItem(atPath: root + "/docs/readme.txt")
        try FileManager.default.removeItem(atPath: root + "/docs/notes.md")

        let report = await scanner.rescanSubtrees([root + "/docs"], tree: tree, progress: progress)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.rescannedRoots == [root + "/docs"])

        let coldTree = await coldScan(root)
        assertTreesEquivalent(tree, coldTree, "filesDeleted")

        let docsSummary = summarize(tree)[root + "/docs"]
        #expect(docsSummary?.childCount == 0, "docs/ should be empty after both files are removed")
    }

    @Test("File grown/shrunk (size change only)")
    func fileResized() async throws {
        let (root, cleanup) = try createTempTree([
            "docs/readme.txt": 100,
            "docs/notes.md": 200,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        // Overwrite readme.txt with a much larger payload — grown; then shrink notes.md.
        try Data(count: 5000).write(to: URL(fileURLWithPath: root).appendingPathComponent("docs/readme.txt"))
        try Data(count: 10).write(to: URL(fileURLWithPath: root).appendingPathComponent("docs/notes.md"))

        let report = await scanner.rescanSubtrees([root + "/docs"], tree: tree, progress: progress)
        #expect(report.unresolvedPaths.isEmpty)

        let coldTree = await coldScan(root)
        assertTreesEquivalent(tree, coldTree, "fileResized")
    }

    @Test("New nested dir subtree created — ancestor rule hits its parent")
    func newNestedDirSubtree() async throws {
        let (root, cleanup) = try createTempTree([
            "src/existing.txt": 50,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        // Brand-new nested directory tree — not in `tree` yet.
        let newModule = URL(fileURLWithPath: root).appendingPathComponent("src/newmodule/sub")
        try FileManager.default.createDirectory(at: newModule, withIntermediateDirectories: true)
        try Data(count: 42).write(to: newModule.appendingPathComponent("deep.txt"))
        try Data(count: 7).write(to: newModule.deletingLastPathComponent().appendingPathComponent("shallow.txt"))

        // The changed path reported is the new directory itself — it can't resolve in the
        // tree, so the ancestor rule must fall back to its parent, "src".
        let report = await scanner.rescanSubtrees([root + "/src/newmodule"], tree: tree, progress: progress)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.rescannedRoots == [root + "/src"],
            "ancestor rule should resolve to the parent that still exists and resolves")

        let coldTree = await coldScan(root)
        assertTreesEquivalent(tree, coldTree, "newNestedDirSubtree")
    }

    @Test("Dir deleted entirely — ancestor rule")
    func dirDeletedEntirely() async throws {
        let (root, cleanup) = try createTempTree([
            "src/oldmodule/sub/deep.txt": 42,
            "src/oldmodule/shallow.txt": 7,
            "src/keep.txt": 3,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        try FileManager.default.removeItem(atPath: root + "/src/oldmodule")

        let report = await scanner.rescanSubtrees([root + "/src/oldmodule"], tree: tree, progress: progress)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.rescannedRoots == [root + "/src"],
            "ancestor rule should resolve to the parent since the changed path no longer exists")

        let coldTree = await coldScan(root)
        assertTreesEquivalent(tree, coldTree, "dirDeletedEntirely")

        #expect(summarize(tree)[root + "/src/oldmodule"] == nil, "deleted subtree must be gone")
    }

    @Test("Two changed dirs where one contains the other — outermost-dedupe")
    func outermostDedupe() async throws {
        let (root, cleanup) = try createTempTree([
            "src/sub/file.txt": 10,
            "src/other.txt": 20,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        try Data(count: 99).write(to: URL(fileURLWithPath: root).appendingPathComponent("src/sub/added.txt"))
        try Data(count: 11).write(to: URL(fileURLWithPath: root).appendingPathComponent("src/newfile.txt"))

        // List the inner path first to prove dedupe doesn't depend on input order.
        let report = await scanner.rescanSubtrees(
            [root + "/src/sub", root + "/src"],
            tree: tree,
            progress: progress
        )
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.rescannedRoots == [root + "/src"],
            "the inner target must be absorbed by the outer one, not scanned twice")

        let coldTree = await coldScan(root)
        assertTreesEquivalent(tree, coldTree, "outermostDedupe")
    }

    @Test("Change outside the tree root leaves the tree untouched")
    func outsideRootIsUnresolved() async throws {
        let (root, cleanup) = try createTempTree([
            "docs/readme.txt": 100,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        let before = summarize(tree)
        let outsidePath = "/System/Library/CoreServices"

        let report = await scanner.rescanSubtrees([outsidePath], tree: tree, progress: progress)
        #expect(report.unresolvedPaths == [outsidePath])
        #expect(report.rescannedRoots.isEmpty)

        let after = summarize(tree)
        #expect(before == after, "a change outside the tree's root must not mutate the tree")
    }

    @Test("Rescan with zero actual changes is idempotent")
    func zeroChangeIdempotence() async throws {
        let (root, cleanup) = try createTempTree([
            "docs/readme.txt": 100,
            "docs/notes.md": 200,
            "images/photo.jpg": 500,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)
        let before = summarize(tree)
        let beforeRoot = tree.nodes[0]

        let report = await scanner.rescanSubtrees([root + "/docs"], tree: tree, progress: progress)
        #expect(report.unresolvedPaths.isEmpty)

        let after = summarize(tree)
        #expect(before == after, "re-enumerating unchanged content must reproduce the same tree")
        #expect(tree.nodes[0].fileSize == beforeRoot.fileSize)
        #expect(tree.nodes[0].allocatedSize == beforeRoot.allocatedSize)

        let coldTree = await coldScan(root)
        assertTreesEquivalent(tree, coldTree, "zeroChangeIdempotence")
    }

    @Test("Search index is correct after a splice")
    func searchIndexAfterSplice() async throws {
        let (root, cleanup) = try createTempTree([
            "docs/readme.txt": 100,
            "docs/notes.md": 200,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        try FileManager.default.removeItem(atPath: root + "/docs/notes.md")
        try Data(count: 12).write(to: URL(fileURLWithPath: root).appendingPathComponent("docs/uniquename123.txt"))

        _ = await scanner.rescanSubtrees([root + "/docs"], tree: tree, progress: progress)

        let nodes = tree.nodesSnapshot()
        let (searchPool, searchEntries) = tree.searchIndexSnapshot()

        let foundResult = SearchEngine.search(
            query: "uniquename123",
            nodes: nodes,
            searchPool: searchPool,
            searchEntries: searchEntries
        )
        #expect(foundResult.matchingIndices.contains { tree.path(at: $0) == root + "/docs/uniquename123.txt" },
            "the file added during the splice must be searchable")

        let deletedResult = SearchEngine.search(
            query: "notes",
            nodes: nodes,
            searchPool: searchPool,
            searchEntries: searchEntries
        )
        #expect(!deletedResult.matchingIndices.contains { tree.path(at: $0) == root + "/docs/notes.md" },
            "the file removed during the splice must no longer be searchable")
    }

    @Test("Repeated splices stay equivalent to cold each round")
    func repeatedSplicesStayEquivalent() async throws {
        let (root, cleanup) = try createTempTree([
            "docs/readme.txt": 100,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        for round in 1...3 {
            let docsURL = URL(fileURLWithPath: root).appendingPathComponent("docs")
            try Data(count: round * 111).write(to: docsURL.appendingPathComponent("round\(round).txt"))
            if round == 2 {
                try FileManager.default.removeItem(atPath: root + "/docs/readme.txt")
            }

            let report = await scanner.rescanSubtrees([root + "/docs"], tree: tree, progress: progress)
            #expect(report.unresolvedPaths.isEmpty, "round \(round) should resolve cleanly")

            let coldTree = await coldScan(root)
            assertTreesEquivalent(tree, coldTree, "round \(round)")
        }
    }
}
