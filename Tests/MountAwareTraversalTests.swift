import Foundation
import Testing
@testable import DirWizCore

@Suite("Mount-aware traversal")
struct MountAwareTraversalTests {
    private let root = "/root"

    @Test("Individual scan keeps a foreign mount point but excludes its contents and reports it")
    func selectedVolumeExcludesForeignMount() async {
        let mock = fixture()
        let (tree, progress) = await scan(mock: mock, root: root, scope: .selectedVolume)
        let scannedPaths = paths(tree)

        #expect(scannedPaths.contains("/root/foreign"))
        #expect(!scannedPaths.contains("/root/foreign/external.bin"))
        #expect(scannedPaths.contains("/root/same/local.bin"))
        #expect(tree.rootDisplaySize == 100)
        #expect(progress.skippedMounts == 1)
        #expect(progress.skippedMountPaths == ["/root/foreign"])
        #expect(tree.mountTraversalScope == .selectedVolume)
    }

    @Test("Same-device volume-group stand-in remains traversable")
    func sameDeviceVolumeGroupSurvives() async {
        let mock = fixture()
        let (tree, _) = await scan(mock: mock, root: root, scope: .selectedVolume)

        #expect(paths(tree).contains("/root/System/Volumes/Data/data.bin"))
        #expect(tree.rootDisplaySize == 100)
    }

    @Test("Scanning at the foreign volume makes its device the boundary")
    func foreignVolumeAsRootScansNormally() async {
        let mock = fixture()
        let (tree, progress) = await scan(
            mock: mock,
            root: "/root/foreign",
            scope: .selectedVolume
        )

        #expect(paths(tree).contains("/root/foreign/external.bin"))
        #expect(tree.rootDisplaySize == 900)
        #expect(progress.skippedMounts == 0)
    }

    @Test("Explicit combined scope includes foreign contents")
    func combinedScopeIncludesForeignMount() async {
        let mock = fixture()
        let (tree, progress) = await scan(mock: mock, root: root, scope: .combinedVolumes)

        #expect(paths(tree).contains("/root/foreign/external.bin"))
        #expect(tree.rootDisplaySize == 1_000)
        #expect(progress.skippedMounts == 0)
        #expect(tree.mountTraversalScope == .combinedVolumes)
    }

    @Test("Unknown root device fails open")
    func unknownRootDeviceFailsOpen() async {
        let mock = fixture()
        mock.inodeMap[root] = nil
        let (tree, progress) = await scan(mock: mock, root: root, scope: .selectedVolume)

        #expect(paths(tree).contains("/root/foreign/external.bin"))
        #expect(progress.skippedMounts == 0)
    }

    @Test("A foreign mount with a bundle-like name cannot bypass the device gate")
    func foreignBundleMountIsNotSizedRecursively() async {
        let mock = MockFilesystemProvider()
        mock.inodeMap[root] = (device: 1, inode: 1)
        mock.inodeMap["/root/External.app"] = (device: 2, inode: 30)
        mock.directories[root] = [
            MockFilesystemProvider.dir(name: "External.app", inode: 30, device: 2)
        ]
        mock.directories["/root/External.app"] = [
            MockFilesystemProvider.file(name: "payload.bin", size: 5_000, inode: 31, device: 2)
        ]

        let tree = FileTree()
        let progress = ScanProgress()
        await FileScanner(
            filesystem: mock,
            computeBundleSizes: true,
            deferTreeMaterialization: false,
            mountTraversalScope: .selectedVolume
        ).scan(path: root, progress: progress, tree: tree)

        let mountIndex = tree.nodeIndex(forPath: "/root/External.app")
        #expect(mountIndex != nil)
        #expect(mountIndex.flatMap { tree.node(at: $0) }?.isBundle == false)
        #expect(tree.rootDisplaySize == 0)
        #expect(progress.skippedMountPaths == ["/root/External.app"])
    }

    @Test("Diagnostic environment resolver forces unrestricted scope")
    func diagnosticOverride() {
        #expect(
            MountTraversalScope.resolved(
                requested: .selectedVolume,
                crossMountsEnvironmentValue: "1"
            ) == .unrestricted
        )
        #expect(
            MountTraversalScope.resolved(
                requested: .selectedVolume,
                crossMountsEnvironmentValue: nil
            ) == .selectedVolume
        )
    }

    @Test("Persistence identity keeps the selected-volume key and separates combined trees")
    func persistenceIdentityIncludesScope() {
        #expect(MountTraversalScope.selectedVolume.persistenceIdentity(for: "/") == "/")
        #expect(
            MountTraversalScope.combinedVolumes.persistenceIdentity(for: "/")
                != MountTraversalScope.selectedVolume.persistenceIdentity(for: "/")
        )
        #expect(
            MountTraversalScope.unrestricted.persistenceIdentity(for: "/")
                != MountTraversalScope.combinedVolumes.persistenceIdentity(for: "/")
        )
    }

    @Test("A foreign changed root cannot bypass the warm or living boundary")
    func foreignChangedRootStaysExcluded() async {
        let mock = fixture()
        let (warmTree, _) = await scan(mock: mock, root: root, scope: .selectedVolume)
        mock.directories["/root/foreign"] = [
            MockFilesystemProvider.file(name: "new-external.bin", size: 2_000, inode: 22, device: 2)
        ]

        let progress = ScanProgress()
        let report = await FileScanner(
            filesystem: mock,
            computeBundleSizes: false,
            deferTreeMaterialization: false
        ).rescanSubtrees(["/root/foreign"], tree: warmTree, progress: progress)
        await MainActor.run { progress.publishCounters() }

        #expect(report.unresolvedPaths.isEmpty)
        #expect(!paths(warmTree).contains("/root/foreign/new-external.bin"))
        #expect(progress.skippedMounts == 1)

        let (coldTree, _) = await scan(mock: mock, root: root, scope: .selectedVolume)
        #expect(paths(warmTree) == paths(coldTree))
        #expect(warmTree.rootDisplaySize == coldTree.rootDisplaySize)
    }

    @Test("Combined tree scope also governs subtree rescans")
    func combinedScopeSurvivesSubtreeRescan() async {
        let mock = fixture()
        let (tree, _) = await scan(mock: mock, root: root, scope: .combinedVolumes)
        mock.directories["/root/foreign"] = [
            MockFilesystemProvider.file(name: "new-external.bin", size: 2_000, inode: 22, device: 2)
        ]

        _ = await FileScanner(
            filesystem: mock,
            computeBundleSizes: false,
            deferTreeMaterialization: false
        ).rescanSubtrees(["/root/foreign"], tree: tree, progress: ScanProgress())

        #expect(paths(tree).contains("/root/foreign/new-external.bin"))
        #expect(!paths(tree).contains("/root/foreign/external.bin"))
    }

    private func fixture() -> MockFilesystemProvider {
        let mock = MockFilesystemProvider()
        mock.inodeMap[root] = (device: 1, inode: 1)
        mock.inodeMap["/root/same"] = (device: 1, inode: 2)
        mock.inodeMap["/root/System"] = (device: 1, inode: 3)
        mock.inodeMap["/root/System/Volumes"] = (device: 1, inode: 4)
        mock.inodeMap["/root/System/Volumes/Data"] = (device: 1, inode: 5)
        mock.inodeMap["/root/foreign"] = (device: 2, inode: 20)

        mock.directories[root] = [
            MockFilesystemProvider.dir(name: "same", inode: 2, device: 1),
            MockFilesystemProvider.dir(name: "System", inode: 3, device: 1),
            MockFilesystemProvider.dir(name: "foreign", inode: 20, device: 2),
        ]
        mock.directories["/root/same"] = [
            MockFilesystemProvider.file(name: "local.bin", size: 60, inode: 6, device: 1)
        ]
        mock.directories["/root/System"] = [
            MockFilesystemProvider.dir(name: "Volumes", inode: 4, device: 1)
        ]
        mock.directories["/root/System/Volumes"] = [
            MockFilesystemProvider.dir(name: "Data", inode: 5, device: 1)
        ]
        mock.directories["/root/System/Volumes/Data"] = [
            MockFilesystemProvider.file(name: "data.bin", size: 40, inode: 7, device: 1)
        ]
        mock.directories["/root/foreign"] = [
            MockFilesystemProvider.file(name: "external.bin", size: 900, inode: 21, device: 2)
        ]
        return mock
    }

    private func scan(
        mock: MockFilesystemProvider,
        root: String,
        scope: MountTraversalScope
    ) async -> (FileTree, ScanProgress) {
        let tree = FileTree()
        let progress = ScanProgress()
        await FileScanner(
            filesystem: mock,
            computeBundleSizes: false,
            deferTreeMaterialization: false,
            mountTraversalScope: scope
        ).scan(path: root, progress: progress, tree: tree)
        return (tree, progress)
    }

    private func paths(_ tree: FileTree) -> Set<String> {
        let snapshot = tree.pathBuildingSnapshot()
        return Set(snapshot.nodes.indices.map {
            FileTree.pathFromSnapshot(
                at: UInt32($0),
                nodes: snapshot.nodes,
                stringPool: snapshot.stringPool,
                rootPath: snapshot.rootPath
            )
        })
    }
}
