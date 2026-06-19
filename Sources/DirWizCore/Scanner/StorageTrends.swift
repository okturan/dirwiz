import Foundation

public struct ScanSummary: Codable, Sendable {
    public let date: Date
    public let rootPath: String
    public let totalUsed: UInt64
    public let totalFree: UInt64
    public let totalCapacity: UInt64
    public let fileCount: Int
    public let directoryCount: Int
    public let topDirectories: [DirectorySummary]

    public struct DirectorySummary: Codable, Sendable {
        public let path: String
        public let size: UInt64
    }
}

public struct StorageTrends: Sendable {
    private let storageURL: URL

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.storageURL = home.appendingPathComponent(".dirwiz_trends.json")
    }

    /// Record a scan summary for the given tree and volume.
    public func recordScan(tree: FileTree, volumePath: String) async throws {
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()

        // Count files and directories
        var fileCount = 0
        var directoryCount = 0
        for node in nodes {
            if node.isDirectory {
                directoryCount += 1
            } else {
                fileCount += 1
            }
        }

        // Get volume stats
        let (totalCapacity, totalFree) = volumeStats(for: volumePath)
        let totalUsed = totalCapacity > totalFree ? totalCapacity - totalFree : 0

        // Find top 10 directories by displaySize (children of root)
        var topDirs: [(path: String, size: UInt64)] = []
        if !nodes.isEmpty {
            let root = nodes[0]
            if root.firstChildIndex != FileNode.invalid {
                let start = Int(root.firstChildIndex)
                let end = min(start + Int(root.childCount), nodes.count)
                for ci in start..<end {
                    let child = nodes[ci]
                    guard child.isDirectory else { continue }
                    let display = child.allocatedSize > 0 ? child.allocatedSize : child.fileSize
                    let path = FileTree.pathFromSnapshot(
                        at: UInt32(ci),
                        nodes: nodes,
                        stringPool: stringPool,
                        rootPath: rootPath
                    )
                    topDirs.append((path: path, size: display))
                }
            }
        }
        topDirs.sort { $0.size > $1.size }
        let top10 = topDirs.prefix(10).map {
            ScanSummary.DirectorySummary(path: $0.path, size: $0.size)
        }

        let summary = ScanSummary(
            date: Date(),
            rootPath: rootPath,
            totalUsed: totalUsed,
            totalFree: totalFree,
            totalCapacity: totalCapacity,
            fileCount: fileCount,
            directoryCount: directoryCount,
            topDirectories: top10
        )

        // Load existing history, append, and write back
        var history = (try? await loadHistory()) ?? []
        history.append(summary)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(history)
        try data.write(to: storageURL, options: .atomic)
    }

    /// Load all historical summaries, optionally filtered by root path.
    public func loadHistory(rootPath: String? = nil) async throws -> [ScanSummary] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return []
        }
        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var summaries = try decoder.decode([ScanSummary].self, from: data)
        if let rootPath {
            summaries = summaries.filter { $0.rootPath == rootPath }
        }
        return summaries
    }

    /// Get summaries for the last N days, optionally filtered by root path.
    public func recentHistory(days: Int, rootPath: String? = nil) async throws -> [ScanSummary] {
        let all = try await loadHistory(rootPath: rootPath)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return all.filter { $0.date >= cutoff }
    }

    // MARK: - Private

    private func volumeStats(for path: String) -> (capacity: UInt64, free: UInt64) {
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let capacity = UInt64(values.volumeTotalCapacity ?? 0)
            let free = UInt64(values.volumeAvailableCapacity ?? 0)
            return (capacity, free)
        } catch {
            return (0, 0)
        }
    }
}
