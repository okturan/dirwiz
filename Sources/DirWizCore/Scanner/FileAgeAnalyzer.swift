import Foundation

public struct AgeBucket: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let minDays: Int
    public let maxDays: Int?
    public var fileCount: Int
    public var totalSize: UInt64
    public var percentage: Double
}

public struct FileAgeResult: Sendable {
    public let buckets: [AgeBucket]
    public let totalFiles: Int
    public let totalSize: UInt64
    public let oldestFileDate: Date?
    public let newestFileDate: Date?
    public let scanDate: Date
}

/// Accumulates per-file age statistics as nodes are visited during a tree walk.
/// Extracted so `FileAgeAnalyzer.analyze(tree:)` and `CombinedFileStatsAnalyzer`
/// can feed the same node stream through identical bucket logic without
/// duplicating it.
struct AgeAccumulator {
    private var counts = [Int](repeating: 0, count: 6)
    private var sizes = [UInt64](repeating: 0, count: 6)
    private var totalFiles = 0
    private var totalSize: UInt64 = 0
    private var oldest: UInt32 = UInt32.max
    private var newest: UInt32 = 0

    mutating func add(node: FileNode, now: UInt32) {
        let secondsPerDay: UInt32 = 86400
        let size = node.displaySize
        let mod = node.modifiedDate

        // Bucket index: 5 = unknown (modifiedDate == 0)
        let bucket: Int
        if mod == 0 {
            bucket = 5
        } else {
            let ageDays = mod <= now ? (now - mod) / secondsPerDay : 0
            if ageDays < 30 {
                bucket = 0
            } else if ageDays < 90 {
                bucket = 1
            } else if ageDays < 365 {
                bucket = 2
            } else if ageDays < 730 {
                bucket = 3
            } else {
                bucket = 4
            }
            // Track oldest/newest among files with known dates
            if mod < oldest { oldest = mod }
            if mod > newest { newest = mod }
        }

        counts[bucket] += 1
        sizes[bucket] += size
        totalFiles += 1
        totalSize += size
    }

    func finalize() -> FileAgeResult {
        let defs: [(id: String, label: String, minDays: Int, maxDays: Int?)] = [
            ("recent_30d",  "< 30 days",    0,    30),
            ("30_90d",      "30-90 days",   30,   90),
            ("90d_1y",      "90 days-1 year", 90,  365),
            ("1_2y",        "1-2 years",    365,  730),
            ("2y_plus",     "2+ years",     730,  nil),
            ("unknown",     "Unknown",      0,    nil),
        ]

        let buckets = defs.enumerated().map { i, def in
            AgeBucket(
                id: def.id,
                label: def.label,
                minDays: def.minDays,
                maxDays: def.maxDays,
                fileCount: counts[i],
                totalSize: sizes[i],
                percentage: totalSize > 0 ? Double(sizes[i]) / Double(totalSize) * 100.0 : 0.0
            )
        }

        let oldestDate: Date? = oldest < UInt32.max ? Date(timeIntervalSince1970: TimeInterval(oldest)) : nil
        let newestDate: Date? = newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil

        return FileAgeResult(
            buckets: buckets,
            totalFiles: totalFiles,
            totalSize: totalSize,
            oldestFileDate: oldestDate,
            newestFileDate: newestDate,
            scanDate: Date()
        )
    }
}

public struct FileAgeAnalyzer: Sendable {
    public init() {}

    public func analyze(tree: FileTree) async -> FileAgeResult {
        let nodes = tree.nodesSnapshot()
        let now = UInt32(Date().timeIntervalSince1970)
        var accumulator = AgeAccumulator()

        let completed = FileTree.forEachFileInSnapshot(nodes) { _, node in
            accumulator.add(node: node, now: now)
        }
        guard completed else { return emptyResult() }

        return accumulator.finalize()
    }

    func emptyResult() -> FileAgeResult {
        FileAgeResult(
            buckets: [],
            totalFiles: 0,
            totalSize: 0,
            oldestFileDate: nil,
            newestFileDate: nil,
            scanDate: Date()
        )
    }
}
