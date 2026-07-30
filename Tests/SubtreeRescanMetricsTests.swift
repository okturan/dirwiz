import Testing
@testable import DirWizCore

@Suite("Subtree Rescan Metrics Tests")
struct SubtreeRescanMetricsTests {

    private func makeScannedFixture() async -> (
        scanner: FileScanner,
        filesystem: MockFilesystemProvider,
        tree: FileTree
    ) {
        let filesystem = MockFilesystemProvider()
        filesystem.inodeMap["/vol"] = (device: 1, inode: 1)
        filesystem.inodeMap["/vol/a"] = (device: 1, inode: 2)
        filesystem.inodeMap["/vol/b"] = (device: 1, inode: 3)
        filesystem.directories["/vol"] = [
            MockFilesystemProvider.dir(name: "a", inode: 2),
            MockFilesystemProvider.dir(name: "b", inode: 3),
        ]
        filesystem.directories["/vol/a"] = [
            MockFilesystemProvider.file(name: "old-a", size: 1, inode: 4),
        ]
        filesystem.directories["/vol/b"] = [
            MockFilesystemProvider.file(name: "old-b", size: 1, inode: 5),
        ]

        let scanner = FileScanner(filesystem: filesystem)
        let tree = FileTree()
        await scanner.scan(path: "/vol", progress: ScanProgress(), tree: tree)
        return (scanner, filesystem, tree)
    }

    @Test("A committed rescan reports phase timings and exact work counts")
    func committedRescanMetrics() async {
        let fixture = await makeScannedFixture()
        #expect(fixture.tree.count == 5)

        fixture.filesystem.directories["/vol/a"] = [
            MockFilesystemProvider.file(name: "new-a", size: 2, inode: 6),
            MockFilesystemProvider.file(name: "new-b", size: 3, inode: 7),
        ]

        let report = await fixture.scanner.rescanSubtrees(
            ["/vol/a"],
            tree: fixture.tree,
            progress: ScanProgress()
        )
        let metrics = report.metrics

        #expect(!report.wasCancelled)
        #expect(report.unresolvedPaths.isEmpty)
        #expect(metrics.beforeNodeCount == 5)
        #expect(metrics.stagedNodeCount == 3)
        #expect(metrics.appendedNodeCount == 2)
        #expect(metrics.removedNodeCount == 1)
        #expect(metrics.afterNodeCount == 6)
        #expect(metrics.requestedPathCount == 1)
        #expect(metrics.rescannedRootCount == 1)
        #expect(metrics.plannedRootCount == 1)
        #expect(metrics.stagedRootCount == 1)
        #expect(metrics.resolvedTargetCount == 1)
        #expect(metrics.structurallyReplacedRootCount == 1)
        #expect(metrics.appliedRootCount == 1)

        #expect(metrics.preflightAndPlanningSeconds >= 0)
        #expect(metrics.phaseAStagingSeconds >= 0)
        #expect(metrics.phaseBTargetResolutionSeconds >= 0)
        #expect(metrics.phaseBStructuralCompactionSeconds >= 0)
        #expect(metrics.postCommitMetadataSeconds >= 0)
        #expect(metrics.aggregateRecomputeSeconds >= 0)
        #expect(metrics.totalSeconds >= metrics.phaseAStagingSeconds)
        #expect(metrics.totalSeconds >= metrics.phaseBStructuralCompactionSeconds)
    }

    @Test("An abandoned rescan reports preflight only and preserves the tree")
    func abandonedRescanMetrics() async {
        let fixture = await makeScannedFixture()
        let beforeCount = fixture.tree.count
        let beforeNames = fixture.tree.stringPoolSnapshot()

        let report = await fixture.scanner.rescanSubtrees(
            ["/outside"],
            tree: fixture.tree,
            progress: ScanProgress()
        )
        let metrics = report.metrics

        #expect(report.unresolvedPaths == ["/outside"])
        #expect(fixture.tree.count == beforeCount)
        #expect(fixture.tree.stringPoolSnapshot() == beforeNames)
        #expect(metrics.beforeNodeCount == 5)
        #expect(metrics.afterNodeCount == 5)
        #expect(metrics.requestedPathCount == 1)
        #expect(metrics.rescannedRootCount == 0)
        #expect(metrics.plannedRootCount == 0)
        #expect(metrics.stagedRootCount == 0)
        #expect(metrics.appliedRootCount == 0)
        #expect(metrics.phaseAStagingSeconds == 0)
        #expect(metrics.phaseBTargetResolutionSeconds == 0)
        #expect(metrics.phaseBStructuralCompactionSeconds == 0)
        #expect(metrics.postCommitMetadataSeconds == 0)
        #expect(metrics.aggregateRecomputeSeconds == 0)
        #expect(metrics.preflightAndPlanningSeconds >= 0)
        #expect(metrics.totalSeconds >= metrics.preflightAndPlanningSeconds)
    }

    @Test("The report initializer remains source compatible")
    func backwardCompatibleReportInitializer() {
        let report = SubtreeRescanReport(
            requestedPaths: ["/a"],
            rescannedRoots: ["/a"],
            unresolvedPaths: []
        )

        #expect(!report.wasCancelled)
        #expect(report.metrics.totalSeconds == 0)
        #expect(report.metrics.beforeNodeCount == 0)
        #expect(report.metrics.appliedRootCount == 0)
    }
}
