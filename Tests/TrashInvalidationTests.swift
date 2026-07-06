import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Regression coverage for the treemap-stale-after-trash bug: `removeSubtree`
/// renumbers every node index, so `trashNode` must invalidate all index-keyed
/// overlay state (search results, recency factors, temporal diff arrays) and
/// force a treemap layout revision bump.
@MainActor
@Suite("Trash Invalidation Tests")
struct TrashInvalidationTests {

    private static let layout: [String: UInt64] = [
        "docs/readme.txt": 100,
        "docs/notes.md": 200,
        "images/photo.jpg": 500,
    ]

    /// Scan a real temp tree on disk into a fresh AppState-owned FileTree, so
    /// `TreeActions.trash` can call the real `FileManager.trashItem`.
    private func makeScannedFixture() async throws -> (cleanup: () -> Void, state: AppState) {
        let (path, cleanup) = try createTempTree(Self.layout)

        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)

        let state = AppState()
        state.fileTree = tree
        return (cleanup, state)
    }

    /// Index of a real leaf file (non-directory) node in the scanned tree.
    private func leafFileIndex(in tree: FileTree) -> UInt32? {
        let nodes = tree.nodesSnapshot()
        guard let idx = nodes.firstIndex(where: { !$0.isDirectory }) else { return nil }
        return UInt32(idx)
    }

    @Test("Successful trash bumps layout revision and clears index-keyed overlays")
    func successfulTrashInvalidatesOverlays() async throws {
        let (cleanup, state) = try await makeScannedFixture()
        defer { cleanup() }

        guard let tree = state.fileTree, let fileIndex = leafFileIndex(in: tree) else {
            Issue.record("Expected a leaf file in the scanned tree")
            return
        }

        let revisionBefore = state.scanProgress.treeLayoutRevision
        state.search.searchResults = [fileIndex]
        state.recencyFactors = [0.5, 0.5, 0.5, 0.5, 0.5]
        let generationBefore = state.recencyGeneration
        state.isRecencyOverlayEnabled = true
        state.temporalDiff.temporalDiffKinds = [0, 1, 0, 0, 0]
        state.temporalDiff.temporalDiffStrengths = [0, 0.5, 0, 0, 0]

        let result = await state.trashNode(at: fileIndex)

        #expect(result.success, "Trash of a real temp file should succeed: \(result.error ?? "")")
        #expect(state.scanProgress.treeLayoutRevision > revisionBefore)
        #expect(state.search.searchResults.isEmpty)
        #expect(state.recencyFactors.isEmpty)
        #expect(state.recencyGeneration > generationBefore)
        #expect(!state.isRecencyOverlayEnabled)
        #expect(state.temporalDiff.temporalDiffKinds.isEmpty)
        #expect(state.temporalDiff.temporalDiffStrengths.isEmpty)
        #expect(state.selectedNodeIndex == nil)
    }

    @Test("Failed trash does not bump revision or clear seeded state")
    func failedTrashIsNoOp() async throws {
        let (cleanup, state) = try await makeScannedFixture()
        defer { cleanup() }

        let revisionBefore = state.scanProgress.treeLayoutRevision
        state.search.searchResults = [7]
        state.recencyFactors = [0.5, 0.5]
        let generationBefore = state.recencyGeneration
        state.isRecencyOverlayEnabled = true

        // Out-of-bounds index — TreeActions.trash reports failure without touching the tree.
        let result = await state.trashNode(at: UInt32.max)

        #expect(!result.success)
        #expect(state.scanProgress.treeLayoutRevision == revisionBefore)
        #expect(state.search.searchResults == [7])
        #expect(state.recencyFactors == [0.5, 0.5])
        #expect(state.recencyGeneration == generationBefore)
        #expect(state.isRecencyOverlayEnabled)
    }
}
