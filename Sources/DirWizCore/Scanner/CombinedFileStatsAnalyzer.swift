import Foundation

/// Produces both `FileAgeResult` and `SizeDistributionResult` from a single tree
/// walk. `FileAgeAnalyzer` and `SizeDistributionAnalyzer` are both simple
/// per-file aggregations over every node in the snapshot; walking the snapshot
/// twice to get both results is redundant node traffic. This type takes one
/// snapshot and does one `forEachFileInSnapshot` pass, feeding both analyzers'
/// accumulators, then delegates all bucket/percentile math to their existing,
/// unchanged accumulation logic.
public struct CombinedFileStatsAnalyzer: Sendable {
    public init() {}

    public func analyze(tree: FileTree) async -> (fileAge: FileAgeResult, sizeDistribution: SizeDistributionResult) {
        let nodes = tree.nodesSnapshot()
        let now = UInt32(Date().timeIntervalSince1970)

        var ageAccumulator = AgeAccumulator()
        var sizeAccumulator = SizeAccumulator(reservingCapacity: nodes.count)

        let completed = FileTree.forEachFileInSnapshot(nodes) { _, node in
            ageAccumulator.add(node: node, now: now)
            sizeAccumulator.add(node: node)
        }
        guard completed else {
            return (FileAgeAnalyzer().emptyResult(), sizeAccumulator.emptyResult())
        }

        return (ageAccumulator.finalize(), sizeAccumulator.finalize())
    }
}
