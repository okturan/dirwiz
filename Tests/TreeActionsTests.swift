import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

@Suite("TreeActions Tests")
struct TreeActionsTests {

    let actions = TreeActions()

    // MARK: - Helpers

    private func scanDirectory(_ path: String) async -> FileTree {
        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)
        return tree
    }

    /// Find a child node by name under a given parent index.
    private func findChild(named name: String, under parent: UInt32, in tree: FileTree) -> (index: UInt32, node: FileNode)? {
        let range = tree.children(of: parent)
        for i in range {
            if tree.name(at: UInt32(i)) == name {
                return (UInt32(i), tree.nodesSnapshot()[i])
            }
        }
        return nil
    }

    private func setModificationDate(_ date: Date, atPath path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    // MARK: - applyPreset: keepNewest

    @Test("keepNewest keeps the newest-mtime path and returns the rest for trashing")
    func keepNewestKeepsNewest() async throws {
        let (root, cleanup) = try createTempTree(["older.bin": 100, "newer.bin": 100])
        defer { cleanup() }

        let older = URL(fileURLWithPath: root).appendingPathComponent("older.bin").path
        let newer = URL(fileURLWithPath: root).appendingPathComponent("newer.bin").path
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), atPath: older)
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_100), atPath: newer)

        let tree = await scanDirectory(root)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [older, newer])

        let result = actions.applyPreset(.keepNewest, to: group, preferredDirectory: nil, tree: tree)
        #expect(result == [older], "Newer file should be kept; older nominated for trash")
    }

    @Test("keepNewest with tied newest dates deterministically keeps the first-listed path")
    func keepNewestTieBreaksToFirstListed() async throws {
        let (root, cleanup) = try createTempTree(["a.bin": 100, "b.bin": 100])
        defer { cleanup() }

        let a = URL(fileURLWithPath: root).appendingPathComponent("a.bin").path
        let b = URL(fileURLWithPath: root).appendingPathComponent("b.bin").path
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        try setModificationDate(sameDate, atPath: a)
        try setModificationDate(sameDate, atPath: b)

        let tree = await scanDirectory(root)
        // `applyPreset` resolves ties via `Collection.max(by:)`, which only replaces its
        // running result on a *strict* increase, so on a tie the first-encountered
        // maximal element wins. Pinning this so a future refactor that flips the
        // tie-break direction is caught here instead of on live data.
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [a, b])

        let result = actions.applyPreset(.keepNewest, to: group, preferredDirectory: nil, tree: tree)
        #expect(result == [b], "First-listed path (a) should win the tie and be kept")
    }

    // MARK: - applyPreset: keepOldest

    @Test("keepOldest keeps the oldest known-date path")
    func keepOldestKeepsOldest() async throws {
        let (root, cleanup) = try createTempTree(["older.bin": 100, "newer.bin": 100])
        defer { cleanup() }

        let older = URL(fileURLWithPath: root).appendingPathComponent("older.bin").path
        let newer = URL(fileURLWithPath: root).appendingPathComponent("newer.bin").path
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), atPath: older)
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_100), atPath: newer)

        let tree = await scanDirectory(root)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [newer, older])

        let result = actions.applyPreset(.keepOldest, to: group, preferredDirectory: nil, tree: tree)
        #expect(result == [newer], "Older file should be kept; newer nominated for trash")
    }

    @Test("keepOldest fails closed when no member has a known modified date")
    func keepOldestFailsClosedWithoutKnownDates() throws {
        let tree = FileTree()
        tree.setRootPath("/fake-root")
        var rootNode = FileNode()
        rootNode.isDirectory = true
        _ = tree.addNode(rootNode, name: "fake-root")

        // modifiedDate defaults to 0 (unknown) for both children — the case this guards.
        let fileA = FileNode(fileSize: 100, allocatedSize: 100)
        let fileB = FileNode(fileSize: 100, allocatedSize: 100)
        let firstChild = tree.addChildren([
            (node: fileA, name: "a.bin"),
            (node: fileB, name: "b.bin"),
        ], parentIndex: 0)

        let pathA = tree.path(at: firstChild)
        let pathB = tree.path(at: firstChild + 1)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [pathA, pathB])

        let result = actions.applyPreset(.keepOldest, to: group, preferredDirectory: nil, tree: tree)
        #expect(result.isEmpty, "No known modified date means no unambiguous keep-file — must return []")
    }

    // MARK: - applyPreset: keepLargest

    @Test("keepLargest keeps the path with the largest allocated size")
    func keepLargestKeepsLargest() async throws {
        // Sizes deliberately differ (real duplicate groups share a size) so the
        // allocated-size comparison has an unambiguous answer in isolation; `group.fileSize`
        // itself is not read by `applyPreset`, only each path's resolved node metadata is.
        let (root, cleanup) = try createTempTree(["small.bin": 100, "large.bin": 20_000])
        defer { cleanup() }

        let small = URL(fileURLWithPath: root).appendingPathComponent("small.bin").path
        let large = URL(fileURLWithPath: root).appendingPathComponent("large.bin").path

        let tree = await scanDirectory(root)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [small, large])

        let result = actions.applyPreset(.keepLargest, to: group, preferredDirectory: nil, tree: tree)
        #expect(result == [small], "Largest allocated file should be kept; smaller nominated for trash")
    }

    // MARK: - applyPreset: keepInDirectory

    @Test("keepInDirectory keeps the path under the preferred directory")
    func keepInDirectoryKeepsMatchingPrefix() async throws {
        let (root, cleanup) = try createTempTree(["dirA/f.bin": 100, "dirB/f.bin": 100])
        defer { cleanup() }

        let pathA = URL(fileURLWithPath: root).appendingPathComponent("dirA/f.bin").path
        let pathB = URL(fileURLWithPath: root).appendingPathComponent("dirB/f.bin").path
        let preferredDir = URL(fileURLWithPath: root).appendingPathComponent("dirB").path

        let tree = await scanDirectory(root)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [pathA, pathB])

        let result = actions.applyPreset(.keepInDirectory, to: group, preferredDirectory: preferredDir, tree: tree)
        #expect(result == [pathA], "Path under dirB should be kept; dirA path nominated for trash")
    }

    @Test("keepInDirectory fails closed when no path matches the preferred directory")
    func keepInDirectoryFailsClosedWithoutMatch() async throws {
        let (root, cleanup) = try createTempTree(["dirA/f.bin": 100, "dirB/f.bin": 100])
        defer { cleanup() }

        let pathA = URL(fileURLWithPath: root).appendingPathComponent("dirA/f.bin").path
        let pathB = URL(fileURLWithPath: root).appendingPathComponent("dirB/f.bin").path
        let nonMatchingDir = URL(fileURLWithPath: root).appendingPathComponent("dirC").path

        let tree = await scanDirectory(root)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [pathA, pathB])

        let result = actions.applyPreset(.keepInDirectory, to: group, preferredDirectory: nonMatchingDir, tree: tree)
        #expect(result.isEmpty, "No matching directory means no unambiguous keep-file — must return []")
    }

    @Test("keepInDirectory fails closed when no preferred directory is given")
    func keepInDirectoryFailsClosedWithoutDirectory() async throws {
        let (root, cleanup) = try createTempTree(["dirA/f.bin": 100, "dirB/f.bin": 100])
        defer { cleanup() }

        let pathA = URL(fileURLWithPath: root).appendingPathComponent("dirA/f.bin").path
        let pathB = URL(fileURLWithPath: root).appendingPathComponent("dirB/f.bin").path

        let tree = await scanDirectory(root)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [pathA, pathB])

        let result = actions.applyPreset(.keepInDirectory, to: group, preferredDirectory: nil, tree: tree)
        #expect(result.isEmpty, "Nil preferred directory means no unambiguous keep-file — must return []")
    }

    // MARK: - applyPreset: stale / degenerate groups

    @Test("A group containing a path absent from the tree fails closed")
    func staleGroupMemberFailsClosed() async throws {
        let (root, cleanup) = try createTempTree(["a.bin": 100])
        defer { cleanup() }

        let validPath = URL(fileURLWithPath: root).appendingPathComponent("a.bin").path
        let stalePath = URL(fileURLWithPath: root).appendingPathComponent("gone.bin").path

        let tree = await scanDirectory(root)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [validPath, stalePath])

        let result = actions.applyPreset(.keepNewest, to: group, preferredDirectory: nil, tree: tree)
        #expect(result.isEmpty, "A path that no longer resolves to a tree node means the scan is stale — must return []")
    }

    @Test("A group with fewer than two paths returns no trash candidates")
    func tooFewPathsReturnsEmpty() async throws {
        let (root, cleanup) = try createTempTree(["a.bin": 100])
        defer { cleanup() }

        let validPath = URL(fileURLWithPath: root).appendingPathComponent("a.bin").path
        let tree = await scanDirectory(root)
        let group = DuplicateGroup(fileSize: 100, hash: 0, paths: [validPath])

        let result = actions.applyPreset(.keepNewest, to: group, preferredDirectory: nil, tree: tree)
        #expect(result.isEmpty)
    }

    // MARK: - zeroNodeSize

    @Test("zeroNodeSize subtracts fileSize and allocatedSize independently up the ancestor chain")
    func zeroNodeSizePropagatesIndependentDeltas() async throws {
        let (root, cleanup) = try createTempTree(["a/f.txt": 100])
        defer { cleanup() }

        let tree = await scanDirectory(root)

        guard let (dirIndex, _) = findChild(named: "a", under: 0, in: tree),
              let (leafIndex, leafNode) = findChild(named: "f.txt", under: dirIndex, in: tree) else {
            Issue.record("Expected to find scanned nodes for a/f.txt")
            return
        }
        guard let dirNodeBefore = tree.node(at: dirIndex), let rootNodeBefore = tree.node(at: 0) else {
            Issue.record("Expected ancestor nodes to exist")
            return
        }

        let leafFileSize = leafNode.fileSize
        let leafAllocatedSize = leafNode.allocatedSize
        // The bug this test pins: the old code subtracted a single `displaySize` value
        // from *both* ancestor aggregates. That's only invisible when fileSize ==
        // allocatedSize, so require they actually diverge here (sub-block file, rounded
        // up on allocation) — otherwise this test would pass whether or not the fix
        // is present.
        try #require(leafFileSize != leafAllocatedSize, "Fixture must have divergent logical/allocated sizes to exercise the bug")

        let dirFileSizeBefore = dirNodeBefore.fileSize
        let dirAllocatedSizeBefore = dirNodeBefore.allocatedSize
        let rootFileSizeBefore = rootNodeBefore.fileSize
        let rootAllocatedSizeBefore = rootNodeBefore.allocatedSize

        tree.zeroNodeSize(at: leafIndex)

        let leafAfter = tree.node(at: leafIndex)
        #expect(leafAfter?.fileSize == 0)
        #expect(leafAfter?.allocatedSize == 0)

        let dirAfter = tree.node(at: dirIndex)
        #expect(dirAfter?.fileSize == dirFileSizeBefore - leafFileSize)
        #expect(dirAfter?.allocatedSize == dirAllocatedSizeBefore - leafAllocatedSize)

        let rootAfter = tree.node(at: 0)
        #expect(rootAfter?.fileSize == rootFileSizeBefore - leafFileSize)
        #expect(rootAfter?.allocatedSize == rootAllocatedSizeBefore - leafAllocatedSize)
    }

    // MARK: - DuplicateContentVerifier O_NOFOLLOW

    @Test("A symlinked path fails byte-identity verification instead of being followed")
    func symlinkedPathFailsVerification() throws {
        let content = Data(repeating: 0xAB, count: 8192)
        let (root, cleanup) = try createTempTree(["orig.bin": UInt64(content.count)])
        defer { cleanup() }

        let origURL = URL(fileURLWithPath: root).appendingPathComponent("orig.bin")
        try content.write(to: origURL)
        let realCopyURL = URL(fileURLWithPath: root).appendingPathComponent("real_copy.bin")
        try content.write(to: realCopyURL)
        let linkURL = URL(fileURLWithPath: root).appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: origURL)

        let realDuplicateStillVerifies = DuplicateContentVerifier.areByteIdentical(
            origURL.path, realCopyURL.path, expectedSize: UInt64(content.count)
        )
        #expect(realDuplicateStillVerifies, "Two real identical files should still verify as byte-identical")

        let symlinkVerifies = DuplicateContentVerifier.areByteIdentical(
            origURL.path, linkURL.path, expectedSize: UInt64(content.count)
        )
        #expect(!symlinkVerifies, "A path that has become a symlink must fail verification (O_NOFOLLOW), not be compared via its followed target")
    }

    // MARK: - batchTrash(paths:tree:)

    @Test("Batch trash of files in different directories removes both from disk and updates root size")
    func batchTrashRemovesMultipleFilesAndUpdatesRootSize() async throws {
        let (root, cleanup) = try createTempTree(["dirA/f1.bin": 1000, "dirB/f2.bin": 2000, "dirC/keep.bin": 500])
        defer { cleanup() }

        let path1 = URL(fileURLWithPath: root).appendingPathComponent("dirA/f1.bin").path
        let path2 = URL(fileURLWithPath: root).appendingPathComponent("dirB/f2.bin").path

        let tree = await scanDirectory(root)
        guard let rootNodeBefore = tree.node(at: 0) else {
            Issue.record("Expected root node")
            return
        }
        let rootSizeBefore = rootNodeBefore.displaySize

        // Resolve-before-each-trash is the core regression this pins: with stale-index
        // resolution (pre-resolving both paths up front), the second trash would operate
        // on a renumbered index and either fail or remove the wrong node.
        let batch = await actions.batchTrash(paths: [path1, path2], tree: tree)

        #expect(batch.successCount == 2)
        #expect(batch.failureCount == 0)
        #expect(!FileManager.default.fileExists(atPath: path1))
        #expect(!FileManager.default.fileExists(atPath: path2))

        guard let rootNodeAfter = tree.node(at: 0) else {
            Issue.record("Expected root node after batch trash")
            return
        }
        #expect(rootNodeAfter.displaySize == rootSizeBefore - batch.totalFreed)
    }

    @Test("Batch trash distinguishes resolved-but-gone failures from never-in-tree failures, while other paths still succeed")
    func batchTrashDistinguishesFailureModes() async throws {
        let (root, cleanup) = try createTempTree(["good.bin": 100, "goneFromDisk.bin": 100])
        defer { cleanup() }

        let goodPath = URL(fileURLWithPath: root).appendingPathComponent("good.bin").path
        let goneFromDiskPath = URL(fileURLWithPath: root).appendingPathComponent("goneFromDisk.bin").path
        let neverInTreePath = URL(fileURLWithPath: root).appendingPathComponent("ghost.bin").path

        let tree = await scanDirectory(root)

        // Delete AFTER scanning: it still resolves inside the tree, but the filesystem
        // trash call itself fails — distinct from a path that never resolves at all.
        try FileManager.default.removeItem(atPath: goneFromDiskPath)

        let batch = await actions.batchTrash(paths: [goodPath, goneFromDiskPath, neverInTreePath], tree: tree)

        #expect(batch.successCount == 1)
        #expect(batch.failureCount == 2)

        guard let goodResult = batch.results.first(where: { $0.originalPath == goodPath }),
              let goneResult = batch.results.first(where: { $0.originalPath == goneFromDiskPath }),
              let neverResult = batch.results.first(where: { $0.originalPath == neverInTreePath }) else {
            Issue.record("Expected a result for each of the three paths")
            return
        }

        #expect(goodResult.success)
        #expect(!goneResult.success)
        #expect(
            goneResult.error != "Path not found in tree",
            "Resolves-but-gone must fail via the filesystem trash error, not the tree-resolution guard"
        )
        #expect(!neverResult.success)
        #expect(neverResult.error == "Path not found in tree")
    }

    @Test("Batch-trashing one file leaves its sibling resolvable by path with its original size intact")
    func batchTrashPreservesSiblingAfterRenumbering() async throws {
        let (root, cleanup) = try createTempTree(["dir/a.bin": 1000, "dir/b.bin": 2000])
        defer { cleanup() }

        let pathA = URL(fileURLWithPath: root).appendingPathComponent("dir/a.bin").path
        let pathB = URL(fileURLWithPath: root).appendingPathComponent("dir/b.bin").path

        let tree = await scanDirectory(root)
        guard let dirIndexBefore = findChild(named: "dir", under: 0, in: tree)?.index,
              let (_, nodeBBefore) = findChild(named: "b.bin", under: dirIndexBefore, in: tree) else {
            Issue.record("Expected to find dir/b.bin before trash")
            return
        }
        let bSizeBefore = nodeBBefore.displaySize

        let batch = await actions.batchTrash(paths: [pathA], tree: tree)
        #expect(batch.successCount == 1)

        guard let dirIndexAfter = findChild(named: "dir", under: 0, in: tree)?.index,
              let (_, nodeBAfter) = findChild(named: "b.bin", under: dirIndexAfter, in: tree) else {
            Issue.record("Expected dir/b.bin to still resolve by path after its sibling was trashed")
            return
        }
        #expect(nodeBAfter.displaySize == bSizeBefore)
        #expect(FileManager.default.fileExists(atPath: pathB))
    }

    @Test("Empty batch returns an empty result without mutating the tree")
    func batchTrashEmptyPathsIsNoOp() async throws {
        let (root, cleanup) = try createTempTree(["a.bin": 100])
        defer { cleanup() }

        let tree = await scanDirectory(root)
        guard let rootBefore = tree.node(at: 0) else {
            Issue.record("Expected root node")
            return
        }
        let sizeBefore = rootBefore.displaySize

        let batch = await actions.batchTrash(paths: [], tree: tree)

        #expect(batch.results.isEmpty)
        #expect(batch.successCount == 0)
        #expect(batch.failureCount == 0)
        #expect(tree.node(at: 0)?.displaySize == sizeBefore)
    }
}
