import Foundation

public struct SizeBucket: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let minSize: UInt64
    public let maxSize: UInt64?
    public var fileCount: Int
    public var totalSize: UInt64
}

public struct SizePercentiles: Sendable {
    public let p50: UInt64
    public let p90: UInt64
    public let p95: UInt64
    public let p99: UInt64
}

public struct SizeDistributionResult: Sendable {
    public let buckets: [SizeBucket]
    public let percentiles: SizePercentiles
    public let totalFiles: Int
    public let totalSize: UInt64
    public let meanSize: UInt64
    public let medianSize: UInt64
}

/// Accumulates per-file sizes as nodes are visited during a tree walk, then
/// produces the exact bucket/percentile math on `finalize()`. Extracted so
/// `SizeDistributionAnalyzer.analyze(tree:)` and `CombinedFileStatsAnalyzer`
/// can feed the same node stream through identical (unchanged) sort-based
/// percentile logic without duplicating it.
struct SizeAccumulator {
    private var fileSizes: [UInt64] = []

    init(reservingCapacity capacity: Int = 0) {
        if capacity > 0 {
            fileSizes.reserveCapacity(capacity)
        }
    }

    mutating func add(node: FileNode) {
        fileSizes.append(node.displaySize)
    }

    /// Nearest-rank percentile on a sorted array.
    private func percentile(sorted: [UInt64], p: Int) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = (p * sorted.count + 99) / 100  // ceiling division
        let index = min(rank, sorted.count) - 1
        return sorted[max(index, 0)]
    }

    /// Map a file size to the appropriate bucket index.
    private func bucketIndex(for size: UInt64) -> Int {
        switch size {
        case 0:                          return 0
        case 1..<1_024:                  return 1
        case 1_024..<10_240:             return 2
        case 10_240..<102_400:           return 3
        case 102_400..<1_048_576:        return 4
        case 1_048_576..<10_485_760:     return 5
        case 10_485_760..<104_857_600:   return 6
        case 104_857_600..<1_073_741_824: return 7
        default:                         return 8
        }
    }

    mutating func finalize() -> SizeDistributionResult {
        if Task.isCancelled { return emptyResult() }

        let totalFiles = fileSizes.count
        guard totalFiles > 0 else { return emptyResult() }

        // Bucket definitions: (id, label, minSize inclusive, maxSize exclusive or nil)
        let defs: [(id: String, label: String, min: UInt64, max: UInt64?)] = [
            ("0b",        "0 bytes",       0,                    1),
            ("1b_1kb",    "1 B - 1 KB",    1,                    1_024),
            ("1_10kb",    "1-10 KB",       1_024,                10_240),
            ("10_100kb",  "10-100 KB",     10_240,               102_400),
            ("100kb_1mb", "100 KB - 1 MB", 102_400,              1_048_576),
            ("1_10mb",    "1-10 MB",       1_048_576,            10_485_760),
            ("10_100mb",  "10-100 MB",     10_485_760,           104_857_600),
            ("100mb_1gb", "100 MB - 1 GB", 104_857_600,          1_073_741_824),
            ("1gb_plus",  "1 GB+",         1_073_741_824,        nil),
        ]

        var counts = [Int](repeating: 0, count: defs.count)
        var bucketSizes = [UInt64](repeating: 0, count: defs.count)
        var totalSize: UInt64 = 0

        for size in fileSizes {
            totalSize += size
            let idx = bucketIndex(for: size)
            counts[idx] += 1
            bucketSizes[idx] += size
        }

        let buckets = defs.enumerated().map { i, def in
            SizeBucket(
                id: def.id,
                label: def.label,
                minSize: def.min,
                maxSize: def.max,
                fileCount: counts[i],
                totalSize: bucketSizes[i]
            )
        }

        // Sort for percentile computation
        fileSizes.sort()

        if Task.isCancelled { return emptyResult() }

        let p50 = percentile(sorted: fileSizes, p: 50)
        let p90 = percentile(sorted: fileSizes, p: 90)
        let p95 = percentile(sorted: fileSizes, p: 95)
        let p99 = percentile(sorted: fileSizes, p: 99)
        let median = p50
        let mean = totalSize / UInt64(totalFiles)

        return SizeDistributionResult(
            buckets: buckets,
            percentiles: SizePercentiles(p50: p50, p90: p90, p95: p95, p99: p99),
            totalFiles: totalFiles,
            totalSize: totalSize,
            meanSize: mean,
            medianSize: median
        )
    }

    func emptyResult() -> SizeDistributionResult {
        SizeDistributionResult(
            buckets: [],
            percentiles: SizePercentiles(p50: 0, p90: 0, p95: 0, p99: 0),
            totalFiles: 0,
            totalSize: 0,
            meanSize: 0,
            medianSize: 0
        )
    }
}

public struct SizeDistributionAnalyzer: Sendable {
    public init() {}

    public func analyze(tree: FileTree) async -> SizeDistributionResult {
        let nodes = tree.nodesSnapshot()
        var accumulator = SizeAccumulator(reservingCapacity: nodes.count)

        let completed = FileTree.forEachFileInSnapshot(nodes) { _, node in
            accumulator.add(node: node)
        }
        guard completed else { return accumulator.emptyResult() }

        return accumulator.finalize()
    }
}
