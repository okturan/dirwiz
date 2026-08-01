import Foundation
import Testing
@testable import DirWizCore
@testable import DirWizUI

@MainActor
@Suite("AppState Statistics Tests")
struct AppStateStatsTests {

    @Test("computeExtensionStats groups normalized last extensions and empty extensions")
    func computeExtensionStatsGroupsExtensions() {
        let tree = FileTree()
        tree.setRootPath("/tmp/dirwiz-app-state-stats-\(UUID().uuidString)")

        var root = FileNode()
        root.isDirectory = true
        _ = tree.addNode(root, name: "root")

        let children: [(node: FileNode, name: String)] = [
            (FileNode(fileSize: 10, allocatedSize: 12), "README.MD"),
            (FileNode(fileSize: 8), "notes.md"),
            (FileNode(fileSize: 7), "archive.TAR.GZ"),
            (FileNode(fileSize: 4), ".gitignore"),
            (FileNode(fileSize: 6), "trailing."),
            (FileNode(fileSize: 5), "LICENSE"),
        ]
        _ = tree.addChildren(children, parentIndex: 0)
        tree.propagateSizes()

        let state = AppState()
        state.fileTree = tree

        state.computeExtensionStats()

        let statsByExtension = Dictionary(uniqueKeysWithValues: state.fileTypeStats.map { ($0.extensionName, $0) })

        #expect(statsByExtension["md"]?.totalSize == 20)
        #expect(statsByExtension["md"]?.fileCount == 2)
        #expect(statsByExtension["md"]?.extensionHash == extensionHash(".md"))
        #expect(statsByExtension["md"]?.category == .code)

        #expect(statsByExtension["gz"]?.totalSize == 7)
        #expect(statsByExtension["gz"]?.fileCount == 1)

        #expect(statsByExtension["gitignore"]?.totalSize == 4)
        #expect(statsByExtension["gitignore"]?.fileCount == 1)

        #expect(statsByExtension[""]?.totalSize == 11)
        #expect(statsByExtension[""]?.fileCount == 2)
        #expect(statsByExtension[""]?.extensionHash == 0)

        #expect(state.fileTypeStats.first?.extensionName == "md")
    }

    /// The renderer used to compare only `ExtensionPalette.generation`. Replacing the palette
    /// during scan reset restarted that counter at zero, so two different consecutive scans both
    /// published generation 1. SwiftUI then left the old volume's color assignments in the Metal
    /// coordinator and every extension unique to the new volume fell back grey.
    @Test("Consecutive scans keep palette revision monotonic across reset")
    func paletteRevisionSurvivesTreeReset() {
        let state = AppState()
        state.fileTree = treeWithOneFile(name: "archive.zst")
        state.computeExtensionStats(loadTemporalSnapshot: false)
        let firstGeneration = state.extensionPalette.generation

        state.resetTreeDerivedState()
        state.fileTree = treeWithOneFile(name: "movie.mkv")
        state.computeExtensionStats(loadTemporalSnapshot: false)

        #expect(state.extensionPalette.generation > firstGeneration,
                "a new tree's palette must not collide with the previous scan's revision")
        #expect(state.extensionPalette.entries.first?.extensionName == "mkv")
        #expect(state.extensionPalette.color(forHash: extensionHash(".mkv"))
                    != ExtensionPalette.fallbackColor)
    }

    private func treeWithOneFile(name: String) -> FileTree {
        let tree = FileTree()
        tree.setRootPath("/tmp/dirwiz-palette-revision")
        var root = FileNode()
        root.isDirectory = true
        _ = tree.addNode(root, name: "root")
        _ = tree.addChildren([(FileNode(fileSize: 10, allocatedSize: 12), name)], parentIndex: 0)
        tree.propagateSizes()
        return tree
    }
}
