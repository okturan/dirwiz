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
    ///
    /// Scoped to the known iCloud container subtrees instead of walking every node: on a
    /// typical scan (e.g. the whole home directory), iCloud files are a tiny fraction of the
    /// tree, so building a path and issuing a `resourceValues` syscall for every non-iCloud
    /// file was almost entirely wasted work. Also checks `Task.isCancelled` per file — each
    /// file already pays for a syscall, so per-file cancellation is cheap relative to that.
    public func analyze(tree: FileTree) async -> iCloudAnalysisResult {
        let snapshot = tree.pathBuildingSnapshot()
        let nodes = snapshot.nodes
        guard !nodes.isEmpty else { return Self.emptyResult() }

        let subtreeRoots = Self.containerSubtreeRoots(
            nodes: nodes, stringPool: snapshot.stringPool, rootPath: snapshot.rootPath
        )
        guard !subtreeRoots.isEmpty else { return Self.emptyResult() }

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

        var stack = subtreeRoots
        while let index = stack.popLast() {
            if Task.isCancelled { return Self.emptyResult() }

            let i = Int(index)
            guard i < nodes.count else { continue }
            let node = nodes[i]

            if node.isDirectory {
                if node.firstChildIndex != FileNode.invalid {
                    let start = Int(node.firstChildIndex)
                    let end = min(start + Int(node.childCount), nodes.count)
                    for childIndex in start..<end {
                        stack.append(UInt32(childIndex))
                    }
                }
                continue
            }

            // Every file reached from a container subtree root is, by construction, under
            // one of the two iCloud prefixes — no need to re-check the path.
            let path = FileTree.pathFromSnapshot(
                at: index, nodes: nodes,
                stringPool: snapshot.stringPool, rootPath: snapshot.rootPath
            )
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

    // MARK: - Container subtree scoping
    //
    // Not marked `private` so unit tests can exercise the derivation directly via
    // `@testable import` instead of only indirectly through `analyze(tree:)`.

    /// Node indices to walk for iCloud analysis: either specific container directories
    /// located within the scanned tree, or `[0]` (the whole tree) when the scan root itself
    /// is inside a container. Empty means nothing in this tree can be under iCloud, so
    /// `analyze(tree:)` can skip the walk entirely.
    static func containerSubtreeRoots(
        nodes: [FileNode], stringPool: Data, rootPath: String
    ) -> [UInt32] {
        // If the scan root itself is inside (or equal to) a container, everything under it
        // is in scope by transitivity — there's no narrower subtree to find.
        for prefix in iCloudPrefixes where relativeComponents(of: rootPath, from: prefix) != nil {
            return [0]
        }

        var roots: [UInt32] = []
        for prefix in iCloudPrefixes {
            guard let components = relativeComponents(of: prefix, from: rootPath) else { continue }
            if let index = FileTree.descendPath(components, nodes: nodes, stringPool: stringPool) {
                roots.append(index)
            }
        }
        return roots
    }

    /// Path components of `child` relative to `ancestor`, when `ancestor` is `child` itself
    /// or a path-boundary-respecting prefix of it. Returns nil when `ancestor` is not an
    /// ancestor of (or equal to) `child` — including a merely-textual prefix match with no
    /// "/" boundary (e.g. ancestor "/Users/al" must not match child "/Users/alice/...").
    static func relativeComponents(of child: String, from ancestor: String) -> [String]? {
        guard child.hasPrefix(ancestor) else { return nil }
        var rest = child.dropFirst(ancestor.count)
        if ancestor.hasSuffix("/") {
            // Boundary already consumed by the trailing slash (also covers ancestor == "/").
        } else if rest.isEmpty {
            // child == ancestor exactly.
        } else if rest.first == "/" {
            rest = rest.dropFirst()
        } else {
            return nil
        }
        return rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func emptyResult() -> iCloudAnalysisResult {
        iCloudAnalysisResult(
            groups: [],
            totalLocalSize: 0,
            evictableSize: 0,
            cloudOnlySize: 0,
            scanDate: Date()
        )
    }

    // MARK: - Private

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
