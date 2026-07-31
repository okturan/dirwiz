import Foundation
import Testing
@testable import DirWizCore

@Suite("Warm-start staged-item estimate growth")
struct WarmStartItemEstimateGrowthTests {
    @Test("A cached small root can grow far beyond its staged-item estimate")
    func cachedSmallRootGrowthCanMateriallyUndershoot() async throws {
        let (root, cleanup) = try createTempTree([
            "churn/seed.txt": 1,
            "stable/seed.txt": 1,
        ])
        defer { cleanup() }

        let tree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: tree
        )

        let churnRoot = root + "/churn"
        let cachedEstimate = WarmStartPlanner.estimatedPatchItemCount(
            forChangedPaths: [churnRoot],
            cachedTree: tree
        )
        #expect(cachedEstimate == 2, "the cached root contains one directory and one file")

        let churnURL = URL(fileURLWithPath: churnRoot)
        for index in 0..<200 {
            try Data(count: 1).write(
                to: churnURL.appendingPathComponent("new-\(index).dat")
            )
        }

        let report = await FileScanner().rescanSubtrees(
            [churnRoot],
            tree: tree,
            progress: ScanProgress()
        )
        let actualStagedItems = try #require(
            report.metrics.rootStaging.first?.actualStagedItemCount
        )

        #expect(actualStagedItems == 202)
        #expect(
            actualStagedItems > cachedEstimate * 100,
            "growth can make the cached estimate materially low"
        )
    }

    @Test("Exact staged-item budget is inclusive")
    func exactStagedItemBudgetStillCommits() async throws {
        let (root, cleanup) = try createTempTree(["churn/seed.txt": 1])
        defer { cleanup() }

        let tree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: tree
        )
        let churnRoot = root + "/churn"
        try Data(count: 1).write(
            to: URL(fileURLWithPath: churnRoot).appendingPathComponent("new.dat")
        )

        let report = await FileScanner().rescanSubtrees(
            [churnRoot],
            tree: tree,
            progress: ScanProgress(),
            options: SubtreeRescanOptions(
                priority: .interactive,
                resetsCancellation: true,
                maximumStagedItemCount: 3
            )
        )

        #expect(report.stagedItemBudgetExceeded == nil)
        #expect(report.metrics.appliedRootCount == 1)
        #expect(tree.nodeIndex(forPath: churnRoot + "/new.dat") != nil)
    }

    @Test("One item over budget returns evidence before mutating the cached tree")
    func overBudgetDoesNotEnterPhaseB() async throws {
        let (root, cleanup) = try createTempTree(["churn/seed.txt": 1])
        defer { cleanup() }

        let tree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: tree
        )
        let churnRoot = root + "/churn"
        let treeBefore = summarizeTree(tree)
        try Data(count: 1).write(
            to: URL(fileURLWithPath: churnRoot).appendingPathComponent("new-a.dat")
        )
        try Data(count: 1).write(
            to: URL(fileURLWithPath: churnRoot).appendingPathComponent("new-b.dat")
        )

        let report = await FileScanner().rescanSubtrees(
            [churnRoot],
            tree: tree,
            progress: ScanProgress(),
            options: SubtreeRescanOptions(
                priority: .interactive,
                resetsCancellation: true,
                maximumStagedItemCount: 3
            )
        )

        #expect(
            report.stagedItemBudgetExceeded
                == .init(
                    actualStagedItemCount: 4,
                    maximumStagedItemCount: 3
                )
        )
        #expect(report.metrics.appliedRootCount == 0)
        #expect(report.metrics.rootStaging == [
            .init(path: churnRoot, actualStagedItemCount: 4)
        ])
        #expect(summarizeTree(tree) == treeBefore)
    }
}
