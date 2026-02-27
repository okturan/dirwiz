import Foundation

/// iCloud file download status.
public enum iCloudStatus: String, Sendable, CaseIterable {
    case downloaded = "Downloaded"
    case cloudOnly = "Cloud Only"
    case downloading = "Downloading"
    case unknown = "Unknown"
}

/// A group of iCloud files with the same status.
public struct iCloudFileGroup: Identifiable, Sendable {
    public let id: String
    public let status: iCloudStatus
    public var fileCount: Int
    public var totalSize: UInt64
    public var paths: [String]
}

/// Full iCloud analysis result.
public struct iCloudAnalysisResult: Sendable {
    public let groups: [iCloudFileGroup]
    public let totalLocalSize: UInt64
    public let evictableSize: UInt64
    public let cloudOnlySize: UInt64
    public let scanDate: Date

    public var totalICloudSize: UInt64 {
        groups.reduce(0) { $0 + $1.totalSize }
    }
}

public struct iCloudAnalyzer: Sendable {
    public init() {}

    /// Known iCloud Drive container paths.
    private static let iCloudPrefixes: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/Library/Mobile Documents/",
            home + "/Library/CloudStorage/"
        ]
    }()

    /// Analyze iCloud Drive files for download status.
    public func analyze(tree: FileTree) async -> iCloudAnalysisResult {
        let snapshot = tree.pathBuildingSnapshot()
        let nodes = snapshot.nodes

        let maxPathsPerGroup = 20

        var downloadedPaths: [String] = []
        var cloudOnlyPaths: [String] = []
        var downloadingPaths: [String] = []
        var unknownPaths: [String] = []

        var downloadedSize: UInt64 = 0
        var cloudOnlySize: UInt64 = 0
        var downloadingSize: UInt64 = 0
        var unknownSize: UInt64 = 0

        var downloadedCount = 0
        var cloudOnlyCount = 0
        var downloadingCount = 0
        var unknownCount = 0

        for i in 0..<nodes.count {
            let node = nodes[i]
            guard !node.isDirectory else { continue }

            let path = FileTree.pathFromSnapshot(
                at: UInt32(i), nodes: nodes,
                stringPool: snapshot.stringPool, rootPath: snapshot.rootPath
            )

            guard Self.isICloudPath(path) else { continue }

            let size = node.displaySize
            let status = Self.queryStatus(path: path)

            switch status {
            case .downloaded:
                downloadedSize += size
                downloadedCount += 1
                if downloadedPaths.count < maxPathsPerGroup { downloadedPaths.append(path) }
            case .cloudOnly:
                cloudOnlySize += size
                cloudOnlyCount += 1
                if cloudOnlyPaths.count < maxPathsPerGroup { cloudOnlyPaths.append(path) }
            case .downloading:
                downloadingSize += size
                downloadingCount += 1
                if downloadingPaths.count < maxPathsPerGroup { downloadingPaths.append(path) }
            case .unknown:
                unknownSize += size
                unknownCount += 1
                if unknownPaths.count < maxPathsPerGroup { unknownPaths.append(path) }
            }
        }

        var groups: [iCloudFileGroup] = []

        let allCases: [(iCloudStatus, UInt64, Int, [String])] = [
            (.downloaded, downloadedSize, downloadedCount, downloadedPaths),
            (.cloudOnly, cloudOnlySize, cloudOnlyCount, cloudOnlyPaths),
            (.downloading, downloadingSize, downloadingCount, downloadingPaths),
            (.unknown, unknownSize, unknownCount, unknownPaths),
        ]

        for (status, size, count, paths) in allCases where count > 0 {
            groups.append(iCloudFileGroup(
                id: status.rawValue,
                status: status,
                fileCount: count,
                totalSize: size,
                paths: paths
            ))
        }

        return iCloudAnalysisResult(
            groups: groups,
            totalLocalSize: downloadedSize,
            evictableSize: downloadedSize,
            cloudOnlySize: cloudOnlySize,
            scanDate: Date()
        )
    }

    /// Evict a file from local storage (keeps in iCloud).
    public func evict(path: String) async throws {
        try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
    }

    /// Evict multiple files. Returns count of successful evictions.
    public func batchEvict(paths: [String]) async throws -> Int {
        var successes = 0
        for path in paths {
            do {
                try await evict(path: path)
                successes += 1
            } catch {
                // Continue with remaining files.
            }
        }
        return successes
    }

    // MARK: - Private

    private static func isICloudPath(_ path: String) -> Bool {
        for prefix in iCloudPrefixes {
            if path.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func queryStatus(path: String) -> iCloudStatus {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]) else {
            return .unknown
        }

        if let isDownloading = values.ubiquitousItemIsDownloading, isDownloading {
            return .downloading
        }

        if let downloadStatus = values.ubiquitousItemDownloadingStatus {
            switch downloadStatus {
            case .current:
                return .downloaded
            case .notDownloaded:
                return .cloudOnly
            default:
                return .unknown
            }
        }

        return .unknown
    }
}
