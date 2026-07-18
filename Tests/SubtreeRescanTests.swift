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

    private func summarize(_ tree: FileTree) -> [String: TreeNodeSummary] {
        summarizeTree(tree)
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

    // MARK: - Large changed root (plan 042: parallel Phase A/B at scale)

    @Test("Equivalence holds for a large (50k-file) changed root — the incident's shape at scale",
          .timeLimit(.minutes(3)))
    func largeChangedRootStaysEquivalent() async throws {
        let (root, cleanup) = try createTempTree([
            "docs/readme.txt": 100,
            "big/seed.txt": 10,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        // Populate "big" with 50k files after the baseline scan — big enough that Phase
        // A's parallel enumeration and Phase B's splice actually exercise real
        // concurrency and a real `installSubtree` merge at scale, not just the small
        // batches every other test in this suite covers.
        let bigURL = URL(fileURLWithPath: root).appendingPathComponent("big")
        let payload = Data(count: 16)
        for i in 0..<50_000 {
            try payload.write(to: bigURL.appendingPathComponent("f\(i).dat"))
        }

        let report = await scanner.rescanSubtrees([root + "/big"], tree: tree, progress: progress)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.rescannedRoots == [root + "/big"])
        #expect(!report.wasCancelled)

        let coldTree = await coldScan(root)
        assertTreesEquivalent(tree, coldTree, "largeChangedRootStaysEquivalent")

        let bigSummary = summarize(tree)[root + "/big"]
        #expect(bigSummary?.childCount == 50_001, "50,000 new files plus the original seed.txt")
    }
}

// MARK: - Cancellation (plan 042: `isCancelled` is now the coherent, non-dead signal)

@Suite("Subtree Rescan Cancellation Tests")
struct SubtreeRescanCancellationTests {

    /// Cancels a specific `FileScanner` the very first time `listDirectory` is called —
    /// deterministic (no wall-clock race), used to prove cancellation mid-Phase-A/B halts
    /// promptly and is reported honestly via `SubtreeRescanReport.wasCancelled`.
    private final class CancelOnFirstListFilesystemProvider: @unchecked Sendable, FilesystemProvider {
        private let inner: MockFilesystemProvider
        private let lock = NSLock()
        private var fired = false
        var scannerToCancel: FileScanner?

        init(inner: MockFilesystemProvider) {
            self.inner = inner
        }

        func listDirectory(path: String) -> [DirectoryEntry]? {
            lock.lock()
            let shouldFire = !fired
            fired = true
            lock.unlock()
            if shouldFire {
                scannerToCancel?.cancel()
            }
            return inner.listDirectory(path: path)
        }

        func computeBundleSize(path: String, isCancelled: () -> Bool) -> (fileSize: UInt64, allocatedSize: UInt64) {
            inner.computeBundleSize(path: path, isCancelled: isCancelled)
        }

        func deviceAndInode(forPath path: String) -> (device: Int32, inode: UInt64)? {
            inner.deviceAndInode(forPath: path)
        }

        func volumeStats(forPath path: String) -> StatfsResult? {
            inner.volumeStats(forPath: path)
        }
    }

    @Test("Cancelling mid-rescan halts promptly, reports it honestly, and leaves the tree structurally valid")
    func cancellingMidRescanHaltsPromptlyAndReportsIt() async {
        let mock = MockFilesystemProvider()
        mock.inodeMap["/vol"] = (device: 1, inode: 0)
        mock.inodeMap["/vol/a"] = (device: 1, inode: 1)
        mock.inodeMap["/vol/b"] = (device: 1, inode: 2)
        mock.directories["/vol"] = [
            MockFilesystemProvider.dir(name: "a", inode: 1),
            MockFilesystemProvider.dir(name: "b", inode: 2),
        ]
        mock.directories["/vol/a"] = [MockFilesystemProvider.file(name: "f1.txt", size: 10, inode: 10)]
        mock.directories["/vol/b"] = [MockFilesystemProvider.file(name: "f2.txt", size: 20, inode: 11)]

        let bootstrapScanner = FileScanner(filesystem: mock)
        let tree = FileTree()
        await bootstrapScanner.scan(path: "/vol", progress: ScanProgress(), tree: tree)

        // "Change" both dirs so both become real rescan targets.
        mock.directories["/vol/a"]?.append(MockFilesystemProvider.file(name: "new_a.txt", size: 5, inode: 12))
        mock.directories["/vol/b"]?.append(MockFilesystemProvider.file(name: "new_b.txt", size: 5, inode: 13))

        let cancelOnFirstList = CancelOnFirstListFilesystemProvider(inner: mock)
        let rescanScanner = FileScanner(filesystem: cancelOnFirstList)
        cancelOnFirstList.scannerToCancel = rescanScanner

        let report = await rescanScanner.rescanSubtrees(["/vol/a", "/vol/b"], tree: tree, progress: ScanProgress())

        #expect(report.wasCancelled, "cancelling on the very first directory listing must be reflected honestly")

        // The tree must remain structurally valid regardless of how much finished
        // applying: every child range must stay inside bounds and start after some real
        // (non-root) node.
        let nodes = tree.nodesSnapshot()
        for node in nodes where node.firstChildIndex != FileNode.invalid {
            #expect(node.firstChildIndex > 0)
            #expect(Int(node.firstChildIndex) + Int(node.childCount) <= nodes.count)
        }
    }
}

// MARK: - Determinate progress (plan 042: "k of N roots" text, not just a spinner)

@Suite("Subtree Rescan Progress Tests")
struct SubtreeRescanProgressTests {

    /// Blocks `listDirectory` for one specific path until the test signals it to
    /// proceed — lets other roots in the same batch complete freely while one is held,
    /// giving a fully deterministic window to observe an in-flight progress update
    /// (rather than racing a wall-clock poll against real work that might already be
    /// done by the time the poll starts). `listDirectory` itself always runs on a
    /// background scanning thread (a plain synchronous call stack), so blocking it on a
    /// `DispatchSemaphore` is fine — only the ASYNC test function must never call
    /// `.wait()` directly (blocking a cooperative-pool thread is disallowed), so the test
    /// observes readiness by polling `didReachGate` instead.
    private final class GatedFilesystemProvider: @unchecked Sendable, FilesystemProvider {
        private let inner: MockFilesystemProvider
        private let gatedPath: String
        private let releaseGate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reachedGateFlag = false

        init(inner: MockFilesystemProvider, gatedPath: String) {
            self.inner = inner
            self.gatedPath = gatedPath
        }

        var didReachGate: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachedGateFlag
        }

        func release() {
            releaseGate.signal()
        }

        func listDirectory(path: String) -> [DirectoryEntry]? {
            if path == gatedPath {
                lock.lock()
                reachedGateFlag = true
                lock.unlock()
                releaseGate.wait()
            }
            return inner.listDirectory(path: path)
        }

        func computeBundleSize(path: String, isCancelled: () -> Bool) -> (fileSize: UInt64, allocatedSize: UInt64) {
            inner.computeBundleSize(path: path, isCancelled: isCancelled)
        }

        func deviceAndInode(forPath path: String) -> (device: Int32, inode: UInt64)? {
            inner.deviceAndInode(forPath: path)
        }

        func volumeStats(forPath path: String) -> StatfsResult? {
            inner.volumeStats(forPath: path)
        }
    }

    @Test("Phase A publishes a 'k of N' progress text as each root finishes staging")
    func determinateRootProgressTextAppears() async {
        let mock = MockFilesystemProvider()
        mock.inodeMap["/vol"] = (device: 1, inode: 0)
        mock.inodeMap["/vol/a"] = (device: 1, inode: 1)
        mock.inodeMap["/vol/b"] = (device: 1, inode: 2)
        mock.inodeMap["/vol/c"] = (device: 1, inode: 3)
        mock.directories["/vol"] = [
            MockFilesystemProvider.dir(name: "a", inode: 1),
            MockFilesystemProvider.dir(name: "b", inode: 2),
            MockFilesystemProvider.dir(name: "c", inode: 3),
        ]
        mock.directories["/vol/a"] = [MockFilesystemProvider.file(name: "f.txt", size: 1, inode: 10)]
        mock.directories["/vol/b"] = [MockFilesystemProvider.file(name: "f.txt", size: 1, inode: 11)]
        mock.directories["/vol/c"] = [MockFilesystemProvider.file(name: "f.txt", size: 1, inode: 12)]

        let bootstrapScanner = FileScanner(filesystem: mock)
        let tree = FileTree()
        await bootstrapScanner.scan(path: "/vol", progress: ScanProgress(), tree: tree)

        mock.directories["/vol/a"]?.append(MockFilesystemProvider.file(name: "new.txt", size: 1, inode: 20))
        mock.directories["/vol/b"]?.append(MockFilesystemProvider.file(name: "new.txt", size: 1, inode: 21))
        mock.directories["/vol/c"]?.append(MockFilesystemProvider.file(name: "new.txt", size: 1, inode: 22))

        // Hold "/vol/a" open — "/vol/b" and "/vol/c" run concurrently (the default
        // worker count comfortably covers all 3 of these tiny plans) and WILL both
        // finish while "/vol/a" is blocked, since nothing gates them.
        let gated = GatedFilesystemProvider(inner: mock, gatedPath: "/vol/a")
        let rescanScanner = FileScanner(filesystem: gated)
        let progress = ScanProgress()

        let rescanTask = Task {
            await rescanScanner.rescanSubtrees(["/vol/a", "/vol/b", "/vol/c"], tree: tree, progress: progress)
        }

        for _ in 0..<400 {
            if gated.didReachGate { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(gated.didReachGate, "expected the gated root's enumeration to have started")

        var sawExpectedText = false
        for _ in 0..<400 {
            if progress.currentPath.contains("2 of 3") {
                sawExpectedText = true
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(sawExpectedText,
            "expected a '(2 of 3)' progress update once two of three roots finished staging; last seen: \"\(progress.currentPath)\"")

        gated.release()
        let report = await rescanTask.value
        #expect(!report.wasCancelled)
        #expect(report.unresolvedPaths.isEmpty)
    }
}
