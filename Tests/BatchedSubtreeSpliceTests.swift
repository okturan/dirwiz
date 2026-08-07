import Foundation
import Testing
@testable import DirWizCore

extension PerformanceSensitiveSuites {

    @Suite("Batched Subtree Splice Baseline", .serialized)
    struct BatchedSubtreeSpliceBaselineTests {
        private static let targetCount = 60
        private static let childrenPerTarget = 1_000
        private static let totalNodeTarget = 200_000

        private struct Replacement {
            let path: String
            let staged: FileTree
        }

        private func makeDirectory() -> FileNode {
            var node = FileNode()
            node.isDirectory = true
            return node
        }

        private func makeFile(size: UInt64 = 1) -> FileNode {
            var node = FileNode()
            node.fileSize = size
            node.allocatedSize = size
            return node
        }

        /// Build the same broad shape Phase B sees on a large cached volume: many nodes
        /// survive every splice, while each of sixty disjoint directories is replaced
        /// with a detached staging tree of approximately the same size.
        private func makeFixture() -> (tree: FileTree, replacements: [Replacement]) {
            let tree = FileTree(stagingCapacityHint: Self.totalNodeTarget)
            tree.setRootPath("/synthetic")
            tree.addNode(makeDirectory(), name: "synthetic")

            var rootChildren: [(node: FileNode, name: String)] = []
            rootChildren.reserveCapacity(
                Self.targetCount
                    + Self.totalNodeTarget
                    - 1
                    - Self.targetCount
                    - Self.targetCount * Self.childrenPerTarget
            )
            for target in 0..<Self.targetCount {
                rootChildren.append((makeDirectory(), "target-\(target)"))
            }

            let fillerCount = Self.totalNodeTarget
                - 1
                - Self.targetCount
                - Self.targetCount * Self.childrenPerTarget
            for filler in 0..<fillerCount {
                rootChildren.append((makeFile(), "filler-\(filler)"))
            }
            tree.addChildren(rootChildren, parentIndex: 0)

            let oldChildren = Array(
                repeating: (node: makeFile(), name: "old"),
                count: Self.childrenPerTarget
            )
            for targetIndex in 1...Self.targetCount {
                tree.addChildren(oldChildren, parentIndex: UInt32(targetIndex))
            }

            var replacements: [Replacement] = []
            replacements.reserveCapacity(Self.targetCount)
            for target in 0..<Self.targetCount {
                let staged = FileTree(stagingCapacityHint: Self.childrenPerTarget + 1)
                staged.addNode(makeDirectory(), name: "target-\(target)")
                let newChildren = Array(
                    repeating: (node: makeFile(size: 2), name: "new"),
                    count: Self.childrenPerTarget
                )
                staged.addChildren(newChildren, parentIndex: 0)
                replacements.append(Replacement(
                    path: "/synthetic/target-\(target)",
                    staged: staged
                ))
            }

            #expect(tree.count == Self.totalNodeTarget)
            return (tree, replacements)
        }

        private func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        }

        @Test("Batched replacement stays within a small multiple of one compaction",
              .timeLimit(.minutes(5)))
        func batchedReplacementIsLinearInTreeSize() throws {
            let single = makeFixture()
            let batched = makeFixture()
            let clock = ContinuousClock()

            let singleTarget = try #require(
                single.tree.nodeIndex(forPath: single.replacements[0].path)
            )
            let singleStart = clock.now
            single.tree.removeChildren(of: singleTarget)
            let singleDuration = seconds(clock.now - singleStart)

            // Resolve the durable paths before timing the structural primitive, just as
            // production Phase B does against one pre-mutation snapshot.
            let batch = try batched.replacements.map { replacement in
                (
                    target: try #require(
                        batched.tree.nodeIndex(forPath: replacement.path)
                    ),
                    staged: replacement.staged
                )
            }
            let batchedStart = clock.now
            #expect(batched.tree.applyStagedReplacements(batch))
            let batchedDuration = seconds(clock.now - batchedStart)

            print(
                "[batched-subtree-splice linearity] "
                    + "\(Self.totalNodeTarget) source nodes, \(Self.targetCount) roots: "
                    + "single_compaction=\(singleDuration)s, "
                    + "batched_compaction=\(batchedDuration)s, "
                    + "ratio=\(batchedDuration / max(singleDuration, .leastNonzeroMagnitude))"
            )

            // This ratio, rather than an absolute wall-time, pins the intended O(tree)
            // behavior while tolerating different developer and CI hardware.
            #expect(
                batchedDuration <= singleDuration * 5,
                "sixty replacements must not regress toward sixty whole-tree compactions"
            )
            #expect(batched.tree.count == Self.totalNodeTarget)
        }
    }
}

@Suite("Batched Subtree Splice Characterization")
struct BatchedSubtreeSpliceCharacterizationTests {

    @Test("Phase B progress text is pinned")
    func phaseBProgressTextIsPinned() async throws {
        let (root, cleanup) = try createTempTree([
            "a/old.txt": 1,
            "b/old.txt": 1,
        ])
        defer { cleanup() }

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: root, progress: progress, tree: tree)

        try Data(count: 2).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("a/new.txt"))
        try Data(count: 3).write(
            to: URL(fileURLWithPath: root).appendingPathComponent("b/new.txt"))

        let report = await scanner.rescanSubtrees(
            [root + "/a", root + "/b"],
            tree: tree,
            progress: progress
        )
        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.metrics.structurallyReplacedRootCount == 2)

        let finalProgress = await MainActor.run {
            progress.publishCounters()
            return progress.currentPath
        }
        // Task 3.4 deliberately replaces sixty per-root updates with one honest step:
        // Phase B now performs one transactional application, not N serial mutations.
        #expect(finalProgress == "Applying 2 folders…")
    }
}

private struct ExactNodeSnapshot: Equatable {
    let nameOffset: UInt32
    let nameLength: UInt16
    let parentIndex: UInt32
    let firstChildIndex: UInt32
    let childCount: UInt32
    let fileSize: UInt64
    let allocatedSize: UInt64
    let inode: UInt64
    let extensionHash: UInt32
    let device: Int32
    let flags: UInt8
    let modifiedDate: UInt32

    init(_ node: FileNode) {
        nameOffset = node.nameOffset
        nameLength = node.nameLength
        parentIndex = node.parentIndex
        firstChildIndex = node.firstChildIndex
        childCount = node.childCount
        fileSize = node.fileSize
        allocatedSize = node.allocatedSize
        inode = node.inode
        extensionHash = node.extensionHash
        device = node.device
        flags = node.flags
        modifiedDate = node.modifiedDate
    }
}

private struct ExactTreeSnapshot: Equatable {
    let nodes: [ExactNodeSnapshot]
    let stringPool: Data
    let rootPath: String
    let isCaseSensitive: Bool
    let linkCountsCaptured: Bool

    init(_ tree: FileTree) {
        nodes = tree.nodesSnapshot().map(ExactNodeSnapshot.init)
        stringPool = tree.stringPoolSnapshot()
        rootPath = tree.rootPath
        isCaseSensitive = tree.isCaseSensitive
        linkCountsCaptured = tree.linkCountsCaptured
    }
}

@Suite("FileTree Batched Replacement Tests")
struct FileTreeBatchedReplacementTests {
    private struct ReplacementSpec {
        let path: String
        let staged: FileTree
    }

    private func directory(seed: UInt64 = 0) -> FileNode {
        var node = FileNode(
            fileSize: seed * 10,
            allocatedSize: seed * 12,
            inode: 10_000 + seed,
            extensionHash: UInt32(truncatingIfNeeded: seed * 37),
            device: Int32(truncatingIfNeeded: seed + 3),
            modifiedDate: UInt32(truncatingIfNeeded: seed + 100)
        )
        node.isDirectory = true
        return node
    }

    private func file(seed: UInt64) -> FileNode {
        var node = FileNode(
            fileSize: seed * 10 + 1,
            allocatedSize: seed * 12 + 2,
            inode: 20_000 + seed,
            extensionHash: UInt32(truncatingIfNeeded: seed * 41),
            device: Int32(truncatingIfNeeded: seed + 7),
            modifiedDate: UInt32(truncatingIfNeeded: seed + 200)
        )
        if seed.isMultiple(of: 3) {
            node.hasMultipleHardlinks = true
        }
        return node
    }

    private func stagedTree(name: String, fileCount: Int, seed: UInt64) -> FileTree {
        let staged = FileTree(stagingCapacityHint: fileCount + 1)
        staged.addNode(directory(seed: seed), name: name)
        guard fileCount > 0 else { return staged }
        var children: [(node: FileNode, name: String)] = []
        children.reserveCapacity(fileCount)
        for child in 0..<fileCount {
            children.append((
                file(seed: seed + UInt64(child) + 1),
                "\(name)-new-\(child)"
            ))
        }
        staged.addChildren(children, parentIndex: 0)
        return staged
    }

    private func baseTree(
        directoryNames: [String],
        oldFilesPerDirectory: Int,
        trailingFile: Bool = false
    ) -> FileTree {
        let estimated = 1 + directoryNames.count * (oldFilesPerDirectory + 1)
            + (trailingFile ? 1 : 0)
        let tree = FileTree(stagingCapacityHint: estimated)
        tree.setRootPath("/fixture")
        tree.setCaseSensitivity(true)
        tree.setLinkCountsCaptured(true)
        tree.addNode(directory(seed: 1), name: "fixture")

        var rootChildren: [(node: FileNode, name: String)] = []
        for (offset, name) in directoryNames.enumerated() {
            rootChildren.append((directory(seed: UInt64(offset + 2)), name))
        }
        if trailingFile {
            rootChildren.append((file(seed: 999), "tail-file"))
        }
        tree.addChildren(rootChildren, parentIndex: 0)

        guard oldFilesPerDirectory > 0 else { return tree }
        for offset in directoryNames.indices {
            var children: [(node: FileNode, name: String)] = []
            children.reserveCapacity(oldFilesPerDirectory)
            for child in 0..<oldFilesPerDirectory {
                let seed = UInt64(1_000 + offset * oldFilesPerDirectory + child)
                children.append((file(seed: seed), "old-\(offset)-\(child)"))
            }
            tree.addChildren(children, parentIndex: UInt32(offset + 1))
        }
        return tree
    }

    private func assertDirectChildrenAreContiguous(
        _ tree: FileTree,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let nodes = tree.nodesSnapshot()
        var seenAsChild = Array(repeating: 0, count: nodes.count)
        for parentIndex in nodes.indices {
            let parent = nodes[parentIndex]
            if parent.childCount == 0 {
                #expect(parent.firstChildIndex == FileNode.invalid, sourceLocation: sourceLocation)
                continue
            }
            #expect(parent.firstChildIndex != FileNode.invalid, sourceLocation: sourceLocation)
            let start = Int(parent.firstChildIndex)
            let end = start + Int(parent.childCount)
            #expect(start >= 0 && end <= nodes.count, sourceLocation: sourceLocation)
            guard start >= 0, end <= nodes.count else { continue }
            for childIndex in start..<end {
                #expect(
                    nodes[childIndex].parentIndex == UInt32(parentIndex),
                    sourceLocation: sourceLocation
                )
                seenAsChild[childIndex] += 1
            }
        }
        if nodes.count > 1 {
            for index in 1..<nodes.count {
                #expect(seenAsChild[index] == 1, sourceLocation: sourceLocation)
            }
        }
    }

    /// Compare the new transaction to the exact legacy sequence, including node order,
    /// every stored FileNode field, string-pool bytes, and child-slice structure.
    private func assertMatchesLegacy(
        makeFixture: () -> (tree: FileTree, replacements: [ReplacementSpec]),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let legacy = makeFixture()
        let batched = makeFixture()

        for replacement in legacy.replacements {
            let target = try #require(
                legacy.tree.nodeIndex(forPath: replacement.path),
                sourceLocation: sourceLocation
            )
            legacy.tree.removeChildren(of: target)
            legacy.tree.installSubtree(replacement.staged, at: target)
        }

        let batch = try batched.replacements.map { replacement in
            (
                target: try #require(
                    batched.tree.nodeIndex(forPath: replacement.path),
                    sourceLocation: sourceLocation
                ),
                staged: replacement.staged
            )
        }
        #expect(
            batched.tree.applyStagedReplacements(batch),
            sourceLocation: sourceLocation
        )

        #expect(
            ExactTreeSnapshot(batched.tree) == ExactTreeSnapshot(legacy.tree),
            "batched output must be byte-for-byte structurally equivalent to the legacy sequence",
            sourceLocation: sourceLocation
        )
        assertDirectChildrenAreContiguous(batched.tree, sourceLocation: sourceLocation)
    }

    @Test("Two targets match legacy when one staged tree is large")
    func twoTargetsOneLarge() throws {
        try assertMatchesLegacy {
            let tree = baseTree(
                directoryNames: ["large", "small", "untouched"],
                oldFilesPerDirectory: 4,
                trailingFile: true
            )
            return (tree, [
                ReplacementSpec(
                    path: "/fixture/large",
                    staged: stagedTree(name: "large", fileCount: 5_000, seed: 30_000)
                ),
                ReplacementSpec(
                    path: "/fixture/small",
                    staged: stagedTree(name: "small", fileCount: 3, seed: 40_000)
                ),
            ])
        }
    }

    @Test("Adjacent sibling targets preserve their parent's contiguous child slice")
    func adjacentSiblingTargets() throws {
        try assertMatchesLegacy {
            let tree = baseTree(
                directoryNames: ["before", "left", "right", "after"],
                oldFilesPerDirectory: 2
            )
            return (tree, [
                ReplacementSpec(
                    path: "/fixture/left",
                    staged: stagedTree(name: "left", fileCount: 4, seed: 50_000)
                ),
                ReplacementSpec(
                    path: "/fixture/right",
                    staged: stagedTree(name: "right", fileCount: 5, seed: 60_000)
                ),
            ])
        }
    }

    @Test("Placeholder-only staged tree empties the target")
    func emptyReplacement() throws {
        try assertMatchesLegacy {
            let tree = baseTree(
                directoryNames: ["emptied", "kept"],
                oldFilesPerDirectory: 5
            )
            return (tree, [
                ReplacementSpec(
                    path: "/fixture/emptied",
                    staged: stagedTree(name: "emptied", fileCount: 0, seed: 70_000)
                ),
            ])
        }
    }

    @Test("One hundred scattered targets match the legacy sequence")
    func hundredTargetScatter() throws {
        try assertMatchesLegacy {
            let names = (0..<100).map { "target-\($0)" }
            let tree = baseTree(directoryNames: names, oldFilesPerDirectory: 1)
            let replacements = names.enumerated().map { offset, name in
                ReplacementSpec(
                    path: "/fixture/\(name)",
                    staged: stagedTree(
                        name: name,
                        fileCount: offset.isMultiple(of: 7) ? 0 : 2,
                        seed: UInt64(80_000 + offset * 10)
                    )
                )
            }
            return (tree, replacements)
        }
    }

    @Test("Target at the array's final index can gain children")
    func targetAtLastIndex() throws {
        try assertMatchesLegacy {
            let tree = FileTree(stagingCapacityHint: 4)
            tree.setRootPath("/fixture")
            tree.addNode(directory(seed: 1), name: "fixture")
            tree.addChildren([
                (file(seed: 2), "before"),
                (directory(seed: 3), "last"),
            ], parentIndex: 0)
            return (tree, [
                ReplacementSpec(
                    path: "/fixture/last",
                    staged: stagedTree(name: "last", fileCount: 2, seed: 90_000)
                ),
            ])
        }
    }

    @Test("Cancellation before rebuild leaves the exact old tree")
    func cancellationBeforeRebuildIsUntouched() throws {
        let tree = baseTree(
            directoryNames: ["target", "kept"],
            oldFilesPerDirectory: 20
        )
        let before = ExactTreeSnapshot(tree)
        let target = try #require(tree.nodeIndex(forPath: "/fixture/target"))
        let committed = tree.applyStagedReplacements(
            [(target, stagedTree(name: "target", fileCount: 10, seed: 100_000))],
            shouldCancel: { true }
        )
        #expect(!committed)
        #expect(ExactTreeSnapshot(tree) == before)
    }

    @Test("Cancellation during the shared mark pass leaves the exact old tree")
    func cancellationDuringRebuildIsUntouched() throws {
        let tree = baseTree(
            directoryNames: ["target", "kept"],
            oldFilesPerDirectory: 20_000
        )
        let before = ExactTreeSnapshot(tree)
        let target = try #require(tree.nodeIndex(forPath: "/fixture/target"))
        var polls = 0
        let committed = tree.applyStagedReplacements(
            [(target, stagedTree(name: "target", fileCount: 10, seed: 110_000))],
            shouldCancel: {
                polls += 1
                return polls >= 5
            }
        )
        #expect(!committed)
        #expect(polls >= 5, "the cancellation closure must be polled during the long pass")
        #expect(ExactTreeSnapshot(tree) == before)
    }
}

@Suite("Subtree Rescan Abandonment Tests")
struct SubtreeRescanAbandonmentTests {
    private func makeMockTree() async -> (MockFilesystemProvider, FileTree) {
        let mock = MockFilesystemProvider()
        mock.inodeMap["/vol"] = (device: 1, inode: 1)
        mock.inodeMap["/vol/a"] = (device: 1, inode: 2)
        mock.inodeMap["/vol/b"] = (device: 1, inode: 3)
        mock.directories["/vol"] = [
            MockFilesystemProvider.dir(name: "a", inode: 2),
            MockFilesystemProvider.dir(name: "b", inode: 3),
        ]
        mock.directories["/vol/a"] = [
            MockFilesystemProvider.file(name: "old-a.txt", size: 10, inode: 10),
        ]
        mock.directories["/vol/b"] = [
            MockFilesystemProvider.file(name: "old-b.txt", size: 20, inode: 20),
        ]
        let tree = FileTree()
        await FileScanner(filesystem: mock).scan(
            path: "/vol",
            progress: ScanProgress(),
            tree: tree
        )
        return (mock, tree)
    }

    @Test("Mixed valid and unresolved paths abandon before mutating the valid target")
    func mixedUnresolvedBatchIsUntouched() async {
        let (mock, tree) = await makeMockTree()
        let before = ExactTreeSnapshot(tree)
        mock.directories["/vol/a"]?.append(
            MockFilesystemProvider.file(name: "new-a.txt", size: 30, inode: 30)
        )

        let report = await FileScanner(filesystem: mock).rescanSubtrees(
            ["/vol/a", "/outside/not-in-tree"],
            tree: tree,
            progress: ScanProgress()
        )

        #expect(report.unresolvedPaths == ["/outside/not-in-tree"])
        #expect(ExactTreeSnapshot(tree) == before)
    }

    @Test("A target that collapses to the scan root abandons before mutation")
    func rootLevelTargetIsUntouched() async {
        let (mock, tree) = await makeMockTree()
        let before = ExactTreeSnapshot(tree)

        let report = await FileScanner(filesystem: mock).rescanSubtrees(
            ["/vol/deleted/deep/path"],
            tree: tree,
            progress: ScanProgress()
        )

        #expect(report.unresolvedPaths.isEmpty)
        #expect(report.rescannedRoots == ["/vol"])
        #expect(ExactTreeSnapshot(tree) == before)
    }
}
