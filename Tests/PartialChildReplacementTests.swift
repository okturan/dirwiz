import Foundation
import Testing
@testable import DirWizCore

/// §3 of selective-child-rescan: transactional partial child replacement on FileTree.
@Suite("FileTree Partial Child Replacement")
struct PartialChildReplacementTests {

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

    private func file(seed: UInt64, size: UInt64? = nil) -> FileNode {
        let resolved = size ?? (seed * 10 + 1)
        return FileNode(
            fileSize: resolved,
            allocatedSize: resolved,
            inode: 20_000 + seed,
            extensionHash: UInt32(truncatingIfNeeded: seed * 41),
            device: Int32(truncatingIfNeeded: seed + 7),
            modifiedDate: UInt32(truncatingIfNeeded: seed + 200)
        )
    }

    private func stagedAdditions(
        targetName: String,
        children: [(name: String, seed: UInt64, isDirectory: Bool)]
    ) -> FileTree {
        let staged = FileTree(stagingCapacityHint: children.count + 1)
        staged.addNode(directory(seed: 1), name: targetName)
        guard !children.isEmpty else { return staged }
        let encoded: [(node: FileNode, name: String)] = children.map { child in
            if child.isDirectory {
                return (directory(seed: child.seed), child.name)
            }
            return (file(seed: child.seed), child.name)
        }
        staged.addChildren(encoded, parentIndex: 0)
        return staged
    }

    /// Root with one target directory containing named children (files or nested dirs).
    private func treeWithTargetChildren(
        _ childSpecs: [(name: String, seed: UInt64, nested: [(name: String, seed: UInt64)]?)]
    ) -> (tree: FileTree, target: UInt32, childIndexByName: [String: UInt32]) {
        let tree = FileTree(stagingCapacityHint: 64)
        tree.setRootPath("/fixture")
        tree.setCaseSensitivity(true)
        tree.addNode(directory(seed: 1), name: "fixture")
        tree.addChildren([(directory(seed: 2), "target")], parentIndex: 0)
        let target = UInt32(1)

        let topLevel: [(node: FileNode, name: String)] = childSpecs.map { spec in
            if spec.nested != nil {
                return (directory(seed: spec.seed), spec.name)
            }
            return (file(seed: spec.seed), spec.name)
        }
        tree.addChildren(topLevel, parentIndex: target)

        var childIndexByName: [String: UInt32] = [:]
        for child in tree.children(of: target) {
            childIndexByName[tree.name(at: UInt32(child))] = UInt32(child)
        }

        for spec in childSpecs {
            guard let nested = spec.nested,
                  let parent = childIndexByName[spec.name],
                  !nested.isEmpty
            else { continue }
            tree.addChildren(
                nested.map { (file(seed: $0.seed), $0.name) },
                parentIndex: parent
            )
        }

        return (tree, target, childIndexByName)
    }

    private func childNames(of tree: FileTree, parent: UInt32) -> [String] {
        tree.children(of: parent).map { tree.name(at: UInt32($0)) }
    }

    private func assertDirectChildrenAreContiguous(_ tree: FileTree) {
        let nodes = tree.nodesSnapshot()
        for parentIndex in nodes.indices {
            let parent = nodes[parentIndex]
            if parent.childCount == 0 {
                #expect(parent.firstChildIndex == FileNode.invalid)
                continue
            }
            let start = Int(parent.firstChildIndex)
            let end = start + Int(parent.childCount)
            #expect(start >= 0 && end <= nodes.count)
            for childIndex in start..<end {
                #expect(nodes[childIndex].parentIndex == UInt32(parentIndex))
                #expect(UInt32(childIndex) > UInt32(parentIndex),
                        "parent index must be lower than child for recomputeAggregates")
            }
        }
    }

    private struct ExactNodeSnapshot: Equatable {
        let name: String
        let parentName: String?
        let childNames: [String]
        let fileSize: UInt64
        let allocatedSize: UInt64
        let inode: UInt64
        let flags: UInt8

        init(tree: FileTree, index: UInt32) {
            let nodes = tree.nodesSnapshot()
            let node = nodes[Int(index)]
            name = tree.name(at: index)
            if node.parentIndex == FileNode.invalid {
                parentName = nil
            } else {
                parentName = tree.name(at: node.parentIndex)
            }
            childNames = tree.children(of: index).map { tree.name(at: UInt32($0)) }
            fileSize = node.fileSize
            allocatedSize = node.allocatedSize
            inode = node.inode
            flags = node.flags
        }
    }

    private func identitySnapshot(_ tree: FileTree) -> [ExactNodeSnapshot] {
        (0..<tree.count).map { ExactNodeSnapshot(tree: tree, index: UInt32($0)) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - 3.1 Partial shapes

    @Test("Addition-only keeps sibling subtrees and installs the newcomer")
    func additionOnly() throws {
        let (tree, target, children) = treeWithTargetChildren([
            (name: "keep-a", seed: 10, nested: [("a1", 11), ("a2", 12)]),
            (name: "keep-b", seed: 20, nested: [("b1", 21)]),
        ])
        let keepABefore = try #require(children["keep-a"])
        let aSubtreeBefore = Set(
            [keepABefore] + tree.children(of: keepABefore).map(UInt32.init)
        ).map { ExactNodeSnapshot(tree: tree, index: $0) }

        let staged = stagedAdditions(
            targetName: "target",
            children: [(name: "new-c", seed: 30, isDirectory: false)]
        )
        #expect(tree.applyStagedReplacements([
            (target: target, removeChildIndices: [], staged: staged),
        ]))

        let targetAfter = try #require(tree.nodeIndex(forPath: "/fixture/target"))
        #expect(childNames(of: tree, parent: targetAfter) == ["keep-a", "keep-b", "new-c"])
        assertDirectChildrenAreContiguous(tree)

        let keepAAfter = try #require(tree.nodeIndex(forPath: "/fixture/target/keep-a"))
        let aSubtreeAfter = ([keepAAfter]
            + tree.children(of: keepAAfter).map(UInt32.init))
            .map { ExactNodeSnapshot(tree: tree, index: $0) }
        #expect(Set(aSubtreeAfter.map(\.name)) == Set(aSubtreeBefore.map(\.name)))
        #expect(aSubtreeAfter.map(\.inode).sorted() == aSubtreeBefore.map(\.inode).sorted())
    }

    @Test("Removal-only drops one child subtree and leaves siblings untouched")
    func removalOnly() throws {
        let (tree, target, children) = treeWithTargetChildren([
            (name: "keep-a", seed: 10, nested: [("a1", 11)]),
            (name: "drop-b", seed: 20, nested: [("b1", 21), ("b2", 22)]),
            (name: "keep-c", seed: 30, nested: nil),
        ])
        let dropB = try #require(children["drop-b"])

        #expect(tree.applyStagedReplacements([
            (
                target: target,
                removeChildIndices: [dropB],
                staged: stagedAdditions(targetName: "target", children: [])
            ),
        ]))

        let targetAfter = try #require(tree.nodeIndex(forPath: "/fixture/target"))
        #expect(childNames(of: tree, parent: targetAfter) == ["keep-a", "keep-c"])
        #expect(tree.nodeIndex(forPath: "/fixture/target/drop-b") == nil)
        #expect(tree.nodeIndex(forPath: "/fixture/target/keep-a/a1") != nil)
        assertDirectChildrenAreContiguous(tree)
    }

    @Test("Mixed remove-and-add preserves a nested kept subtree")
    func mixedRemoveAndAdd() throws {
        let (tree, target, children) = treeWithTargetChildren([
            (name: "keep-a", seed: 10, nested: [("deep", 11)]),
            (name: "drop-b", seed: 20, nested: [("gone", 21)]),
            (name: "keep-c", seed: 30, nested: nil),
        ])
        let dropB = try #require(children["drop-b"])
        // Give the staged directory a nested file so remapping is exercised.
        let staged = FileTree(stagingCapacityHint: 4)
        staged.addNode(directory(seed: 40), name: "target")
        staged.addChildren([(directory(seed: 41), "new-d")], parentIndex: 0)
        staged.addChildren([(file(seed: 42), "inside")], parentIndex: 1)

        #expect(tree.applyStagedReplacements([
            (target: target, removeChildIndices: [dropB], staged: staged),
        ]))

        let targetAfter = try #require(tree.nodeIndex(forPath: "/fixture/target"))
        #expect(childNames(of: tree, parent: targetAfter) == ["keep-a", "keep-c", "new-d"])
        #expect(tree.nodeIndex(forPath: "/fixture/target/keep-a/deep") != nil)
        #expect(tree.nodeIndex(forPath: "/fixture/target/new-d/inside") != nil)
        #expect(tree.nodeIndex(forPath: "/fixture/target/drop-b") == nil)
        assertDirectChildrenAreContiguous(tree)
    }

    // MARK: - 3.2 Degenerate case

    @Test("Nil removeChildIndices matches whole-subtree replacement of the same staged tree")
    func wholeSubtreeIsDegeneratePartial() throws {
        func fixture() -> (tree: FileTree, target: UInt32, staged: FileTree) {
            let (tree, target, _) = treeWithTargetChildren([
                (name: "old-a", seed: 10, nested: [("x", 11)]),
                (name: "old-b", seed: 20, nested: nil),
            ])
            let staged = stagedAdditions(
                targetName: "target",
                children: [
                    (name: "new-a", seed: 50, isDirectory: false),
                    (name: "new-b", seed: 51, isDirectory: false),
                ]
            )
            return (tree, target, staged)
        }

        let full = fixture()
        let partial = fixture()

        #expect(full.tree.applyStagedReplacements([
            (target: full.target, staged: full.staged),
        ]))
        #expect(partial.tree.applyStagedReplacements([
            (target: partial.target, removeChildIndices: nil, staged: partial.staged),
        ]))

        #expect(identitySnapshot(full.tree) == identitySnapshot(partial.tree))
        assertDirectChildrenAreContiguous(partial.tree)
    }

    @Test("Explicit all-children removal equals nil removeChildIndices")
    func explicitAllChildrenEqualsNil() throws {
        func fixture() -> (
            tree: FileTree,
            target: UInt32,
            allChildren: [UInt32],
            staged: FileTree
        ) {
            let (tree, target, children) = treeWithTargetChildren([
                (name: "old-a", seed: 10, nested: nil),
                (name: "old-b", seed: 20, nested: nil),
            ])
            let staged = stagedAdditions(
                targetName: "target",
                children: [(name: "fresh", seed: 99, isDirectory: false)]
            )
            return (tree, target, Array(children.values).sorted(), staged)
        }

        let viaNil = fixture()
        let viaExplicit = fixture()

        #expect(viaNil.tree.applyStagedReplacements([
            (target: viaNil.target, removeChildIndices: nil, staged: viaNil.staged),
        ]))
        #expect(viaExplicit.tree.applyStagedReplacements([
            (
                target: viaExplicit.target,
                removeChildIndices: viaExplicit.allChildren,
                staged: viaExplicit.staged
            ),
        ]))

        #expect(identitySnapshot(viaNil.tree) == identitySnapshot(viaExplicit.tree))
    }

    // MARK: - 3.3 Cancellation

    @Test("Cancellation before rebuild leaves the exact old tree for a partial patch")
    func cancellationBeforeRebuildIsUntouched() throws {
        let (tree, target, children) = treeWithTargetChildren([
            (name: "keep", seed: 10, nested: [("x", 11)]),
            (name: "drop", seed: 20, nested: [("y", 21)]),
        ])
        let before = identitySnapshot(tree)
        let drop = try #require(children["drop"])
        let committed = tree.applyStagedReplacements(
            [
                (
                    target: target,
                    removeChildIndices: [drop],
                    staged: stagedAdditions(
                        targetName: "target",
                        children: [(name: "new", seed: 30, isDirectory: false)]
                    )
                ),
            ],
            shouldCancel: { true }
        )
        #expect(!committed)
        #expect(identitySnapshot(tree) == before)
    }

    @Test("Cancellation during the mark pass leaves the exact old tree")
    func cancellationDuringMarkIsUntouched() throws {
        let nested = (0..<8_000).map { (name: "n-\($0)", seed: UInt64(100 + $0)) }
        let (tree, target, children) = treeWithTargetChildren([
            (name: "keep", seed: 10, nested: nested),
            (name: "drop", seed: 20, nested: nested),
        ])
        let before = identitySnapshot(tree)
        let drop = try #require(children["drop"])
        var polls = 0
        let committed = tree.applyStagedReplacements(
            [
                (
                    target: target,
                    removeChildIndices: [drop],
                    staged: stagedAdditions(
                        targetName: "target",
                        children: [(name: "new", seed: 30, isDirectory: false)]
                    )
                ),
            ],
            shouldCancel: {
                polls += 1
                return polls >= 5
            }
        )
        #expect(!committed)
        #expect(polls >= 5)
        #expect(identitySnapshot(tree) == before)
    }

    // MARK: - 3.4 Aggregate repair

    @Test("recomputeAggregates repairs sizes after a partial commit; propagateSizes would double-count")
    func aggregatesRepairedAfterCommit() throws {
        let tree = FileTree(stagingCapacityHint: 32)
        tree.setRootPath("/fixture")
        // Directories start at size 0 so propagateSizes leaves only child sums.
        var root = FileNode()
        root.isDirectory = true
        var targetNode = FileNode()
        targetNode.isDirectory = true
        tree.addNode(root, name: "fixture")
        tree.addChildren([(targetNode, "target")], parentIndex: 0)
        let target = UInt32(1)
        tree.addChildren(
            [
                (file(seed: 10, size: 100), "keep"),
                (file(seed: 20, size: 200), "drop"),
            ],
            parentIndex: target
        )
        tree.propagateSizes()
        #expect(tree.node(at: 0)?.fileSize == 300)
        #expect(tree.node(at: target)?.fileSize == 300)

        let drop = UInt32(tree.children(of: target).first { tree.name(at: UInt32($0)) == "drop" }!)
        let staged = stagedAdditions(
            targetName: "target",
            children: [(name: "new", seed: 30, isDirectory: false)]
        )
        // Staged nodes start with their own sizes; the added file carries seed*10+1 = 301.
        #expect(tree.applyStagedReplacements([
            (target: target, removeChildIndices: [drop], staged: staged),
        ]))

        // Post-commit aggregates are intentionally stale until repaired.
        tree.recomputeAggregates()
        let targetAfter = try #require(tree.nodeIndex(forPath: "/fixture/target"))
        let keepIndex = try #require(tree.nodeIndex(forPath: "/fixture/target/keep"))
        let newIndex = try #require(tree.nodeIndex(forPath: "/fixture/target/new"))
        let keepSize = try #require(tree.node(at: keepIndex)?.fileSize)
        let newSize = try #require(tree.node(at: newIndex)?.fileSize)
        let expected = keepSize + newSize
        #expect(tree.node(at: targetAfter)?.fileSize == expected)
        #expect(tree.node(at: 0)?.fileSize == expected)

        // Calling propagateSizes on the already-repaired tree would double-count.
        let beforeDouble = tree.node(at: 0)?.fileSize
        tree.propagateSizes()
        #expect(tree.node(at: 0)?.fileSize != beforeDouble)
    }

    // MARK: - Nested targets

    @Test("A nested target under an unchanged entry applies in one compaction")
    func nestedTargetUnderUnchangedEntry() throws {
        let tree = FileTree(stagingCapacityHint: 64)
        tree.setRootPath("/fixture")
        tree.setCaseSensitivity(true)
        tree.addNode(directory(seed: 1), name: "fixture")
        tree.addChildren([(directory(seed: 2), "parent")], parentIndex: 0)
        let parent = UInt32(1)
        tree.addChildren([
            (directory(seed: 3), "keepDir"),
            (file(seed: 4), "other.txt"),
        ], parentIndex: parent)
        let keepDir = try #require(tree.nodeIndex(forPath: "/fixture/parent/keepDir"))
        tree.addChildren([
            (file(seed: 5), "x"),
            (file(seed: 6), "y"),
        ], parentIndex: keepDir)

        let parentStaged = stagedAdditions(
            targetName: "parent",
            children: [(name: "new.txt", seed: 40, isDirectory: false)]
        )
        let keepStaged = stagedAdditions(
            targetName: "keepDir",
            children: [(name: "nested-new.txt", seed: 50, isDirectory: false)]
        )

        #expect(tree.applyStagedReplacements([
            (target: parent, removeChildIndices: [], staged: parentStaged),
            (target: keepDir, removeChildIndices: [], staged: keepStaged),
        ]))
        assertDirectChildrenAreContiguous(tree)

        let namesAtParent = tree.children(of: try #require(tree.nodeIndex(forPath: "/fixture/parent")))
            .map { tree.name(at: UInt32($0)) }
        #expect(Set(namesAtParent) == Set(["keepDir", "other.txt", "new.txt"]))
        let namesAtKeep = tree.children(of: try #require(tree.nodeIndex(forPath: "/fixture/parent/keepDir")))
            .map { tree.name(at: UInt32($0)) }
        #expect(Set(namesAtKeep) == Set(["x", "y", "nested-new.txt"]))
        #expect(tree.node(at: try #require(tree.nodeIndex(forPath: "/fixture/parent/keepDir/x")))?.inode == 20_005)
    }

    @Test("Nested target batch output does not depend on caller order")
    func nestedTargetBatchIsOrderIndependent() throws {
        func build() -> (tree: FileTree, parent: UInt32, child: UInt32) {
            let tree = FileTree(stagingCapacityHint: 64)
            tree.setRootPath("/fixture")
            tree.setCaseSensitivity(true)
            tree.addNode(directory(seed: 1), name: "fixture")
            tree.addChildren([(directory(seed: 2), "parent")], parentIndex: 0)
            let parent = UInt32(1)
            tree.addChildren([(directory(seed: 3), "child")], parentIndex: parent)
            let child = tree.nodeIndex(forPath: "/fixture/parent/child")!
            tree.addChildren([(file(seed: 4), "leaf.txt")], parentIndex: child)
            return (tree, parent, child)
        }
        let parentStaged = stagedAdditions(
            targetName: "parent",
            children: [(name: "p-new.txt", seed: 40, isDirectory: false)]
        )
        let childStaged = stagedAdditions(
            targetName: "child",
            children: [(name: "c-new.txt", seed: 50, isDirectory: false)]
        )

        let parentFirst = build()
        #expect(parentFirst.tree.applyStagedReplacements([
            (target: parentFirst.parent, removeChildIndices: [], staged: parentStaged),
            (target: parentFirst.child, removeChildIndices: [], staged: childStaged),
        ]))
        let childFirst = build()
        #expect(childFirst.tree.applyStagedReplacements([
            (target: childFirst.child, removeChildIndices: [], staged: childStaged),
            (target: childFirst.parent, removeChildIndices: [], staged: parentStaged),
        ]))

        #expect(identitySnapshot(parentFirst.tree) == identitySnapshot(childFirst.tree))
        assertDirectChildrenAreContiguous(parentFirst.tree)
        assertDirectChildrenAreContiguous(childFirst.tree)
    }

    @Test("stagedReplacementViolation names illegal batches without crashing")
    func stagedReplacementViolations() {
        let tree = FileTree(stagingCapacityHint: 8)
        tree.setRootPath("/fixture")
        tree.addNode(directory(seed: 1), name: "fixture")
        tree.addChildren([(directory(seed: 2), "a")], parentIndex: 0)
        let nodes = tree.nodesSnapshot()

        #expect(FileTree.stagedReplacementViolation(
            targets: [(target: 99, removeChildIndices: nil)],
            nodes: nodes
        ) == "staged replacement target is outside the tree")
        #expect(FileTree.stagedReplacementViolation(
            targets: [(target: 1, removeChildIndices: nil), (target: 1, removeChildIndices: [])],
            nodes: nodes
        ) == "staged replacement target is duplicated")
        #expect(FileTree.stagedReplacementViolation(
            targets: [(target: 1, removeChildIndices: [0])],
            nodes: nodes
        ) == "removeChildIndices must name direct children of target")
    }
}
