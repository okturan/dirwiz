import Foundation
import Testing
@testable import DirWizLib

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
}
