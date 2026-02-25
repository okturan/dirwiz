import SwiftUI

/// Central observable state for the application.
@Observable
public final class AppState {
    /// The scanned file tree.
    public var fileTree: FileTree?

    /// Scan progress state.
    public var scanProgress = ScanProgress()

    /// Currently selected node in tree view / treemap.
    public var selectedNodeIndex: UInt32?

    /// Root node for treemap display (navigation into subdirectories).
    public var treemapRootIndex: UInt32 = 0

    /// Navigation path for treemap breadcrumb — always canonical (root → current).
    public var treemapPath: [UInt32] = [0]

    /// Selected volume URL to scan.
    public var selectedVolume: URL?

    /// Available volumes.
    public var availableVolumes: [VolumeInfo] = []

    /// Active tab in detail area.
    public var activeTab: DetailTab = .treeView

    /// Extension size stats computed after scan (per-extension-hash).
    public var extensionStats: [ExtensionStat] = []

    /// Per-extension-name stats for the Extensions tab (individual file types).
    public var fileTypeStats: [FileTypeStat] = []

    /// WinDirStat-style per-extension color palette (top 17 by size).
    public var extensionPalette = ExtensionPalette()

    /// Duplicate file groups (populated after duplicate scan).
    public var duplicateGroups: [DuplicateGroup] = []

    /// Per-node reclaim score (0-100). Files are always 0.
    public var reclaimScores: [UInt8] = []

    /// Per-node Spotlight recency factor [0,1] (1=recently used, 0=stale/unindexed).
    public var recencyFactors: [Float] = []

    /// Bumped each time recencyFactors is updated, for GPU change detection.
    public var recencyGeneration: UInt64 = 0

    /// Whether the recency heatmap overlay is active.
    public var isRecencyOverlayEnabled: Bool = false

    /// Whether a Spotlight recency query is in progress.
    public var isRecencyQueryRunning: Bool = false

    // MARK: - Temporal Diff

    /// Snapshot loaded from disk for comparison (nil = none taken yet).
    public var temporalSnapshot: TemporalSnapshot?

    /// Whether the temporal diff overlay is currently active.
    public var isTemporalDiffEnabled: Bool = false

    /// Whether a snapshot save/build is in progress.
    public var isSnapshotBuilding: Bool = false

    /// Bumped each time diff results are applied (GPU change detection).
    public var temporalDiffGeneration: UInt64 = 0

    /// Per-node diff kind (TemporalDiffKind.rawValue). Files are always .none.
    public var temporalDiffKinds: [UInt8] = []

    /// Per-node blend strength [0,1] for the diff tint.
    public var temporalDiffStrengths: [Float] = []

    /// Surviving ancestors → count/bytes of deleted descendants (for tooltips).
    public var temporalDiffDeletedCounts: [UInt32: DeletedSummary] = [:]

    /// Whether duplicate scan is in progress.
    public var isDuplicateScanRunning: Bool = false

    /// Whether Full Disk Access is granted.
    public var hasFullDiskAccess: Bool = false

    // MARK: - Navigation History

    private var backStack: [UInt32] = []
    private var forwardStack: [UInt32] = []

    /// Token incremented on each new scan; used to discard stale async results.
    private var recencyToken: UInt64 = 0
    private var temporalDiffToken: UInt64 = 0
    private var temporalDiffTask: Task<Void, Never>?

    public var canNavigateBack: Bool { !backStack.isEmpty }
    public var canNavigateForward: Bool { !forwardStack.isEmpty }
    public var canNavigateUp: Bool { treemapPath.count > 1 }

    public init() {}

    // MARK: - Navigation

    /// Set the treemap root to a directory, rebuilding the canonical path from the parent chain.
    public func setTreemapRoot(_ nodeIndex: UInt32, recordHistory: Bool = true) {
        guard let tree = fileTree else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(nodeIndex)
        guard i < nodes.count, nodes[i].isDirectory else { return }

        if recordHistory {
            backStack.append(treemapRootIndex)
            forwardStack.removeAll()
        }

        treemapRootIndex = nodeIndex
        treemapPath = Self.buildPath(to: nodeIndex, nodes: nodes)
    }

    /// Navigate up one level in treemap.
    public func navigateUp() {
        guard treemapPath.count > 1 else { return }
        let parentIndex = treemapPath[treemapPath.count - 2]
        backStack.append(treemapRootIndex)
        forwardStack.removeAll()
        treemapRootIndex = parentIndex
        treemapPath.removeLast()
    }

    /// Navigate to a specific level in breadcrumb.
    public func navigateTo(pathIndex: Int) {
        guard pathIndex < treemapPath.count else { return }
        let target = treemapPath[pathIndex]
        backStack.append(treemapRootIndex)
        forwardStack.removeAll()
        treemapRootIndex = target
        treemapPath = Array(treemapPath.prefix(pathIndex + 1))
    }

    /// Go back to previously viewed directory.
    public func navigateBack() {
        guard let prev = backStack.popLast() else { return }
        guard let tree = fileTree else { return }
        forwardStack.append(treemapRootIndex)
        treemapRootIndex = prev
        treemapPath = Self.buildPath(to: prev, nodes: tree.nodesSnapshot())
    }

    /// Go forward after navigating back.
    public func navigateForward() {
        guard let next = forwardStack.popLast() else { return }
        guard let tree = fileTree else { return }
        backStack.append(treemapRootIndex)
        treemapRootIndex = next
        treemapPath = Self.buildPath(to: next, nodes: tree.nodesSnapshot())
    }

    /// Navigate to the volume root.
    public func navigateHome() {
        guard treemapRootIndex != 0 else { return }
        backStack.append(treemapRootIndex)
        forwardStack.removeAll()
        treemapRootIndex = 0
        treemapPath = [0]
    }

    /// Navigate treemap to show a specific node (from search or tree view).
    /// For files, navigates to the parent directory. For directories, navigates to it.
    public func showNodeInTreemap(_ nodeIndex: UInt32) {
        guard let tree = fileTree else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(nodeIndex)
        guard i < nodes.count else { return }

        let node = nodes[i]
        let targetDir: UInt32
        if node.isDirectory {
            targetDir = nodeIndex
        } else if node.parentIndex != FileNode.invalid {
            targetDir = node.parentIndex
        } else {
            return
        }

        setTreemapRoot(targetDir)
        selectedNodeIndex = nodeIndex
    }

    /// Reset navigation state for a new scan.
    public func resetForNewScan() {
        backStack.removeAll()
        forwardStack.removeAll()
        treemapRootIndex = 0
        treemapPath = [0]
        selectedNodeIndex = nil
        extensionStats = []
        fileTypeStats = []
        extensionPalette = ExtensionPalette()
        duplicateGroups = []
        reclaimScores = []
        recencyFactors = []
        recencyGeneration = 0
        isRecencyOverlayEnabled = false
        isRecencyQueryRunning = false
        recencyToken &+= 1
        temporalDiffKinds = []
        temporalDiffStrengths = []
        temporalDiffDeletedCounts = [:]
        temporalDiffGeneration = 0
        isTemporalDiffEnabled = false
        temporalDiffTask?.cancel()
        temporalDiffTask = nil
        temporalDiffToken &+= 1
    }

    // MARK: - Path Building

    /// Build canonical path from root (0) to the given node index by walking parent chain.
    static func buildPath(to index: UInt32, nodes: [FileNode]) -> [UInt32] {
        var path: [UInt32] = []
        var current = index
        while current != FileNode.invalid {
            let i = Int(current)
            guard i < nodes.count else { break }
            path.append(current)
            current = nodes[i].parentIndex
        }
        path.reverse()
        return path.isEmpty ? [0] : path
    }

    // MARK: - Statistics Computation

    /// Build extension statistics from the file tree.
    public func computeExtensionStats() {
        guard let tree = fileTree else { return }
        var sizeByHash: [UInt16: UInt64] = [:]
        var countByHash: [UInt16: Int] = [:]
        var sizeByExt: [String: UInt64] = [:]
        var countByExt: [String: Int] = [:]
        let colorMap = ExtensionColorMap.shared

        let snapshot = tree.nodesSnapshot()
        let totalSize = snapshot.first?.fileSize ?? 0

        for i in 0..<snapshot.count {
            let node = snapshot[i]
            guard !node.isDirectory else { continue }

            sizeByHash[node.extensionHash, default: 0] += node.fileSize
            countByHash[node.extensionHash, default: 0] += 1

            // Extract extension name for per-type stats.
            let name = tree.name(at: UInt32(i))
            let ext = Self.extractExtension(from: name)
            sizeByExt[ext, default: 0] += node.fileSize
            countByExt[ext, default: 0] += 1
        }

        // Per-hash stats (for categories legend).
        extensionStats = sizeByHash.map { hash, size in
            ExtensionStat(
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: size,
                fileCount: countByHash[hash] ?? 0,
                percentage: totalSize > 0 ? Double(size) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }

        // Per-extension-name stats (for file types list).
        fileTypeStats = sizeByExt.map { ext, size in
            let hash = extensionHash("file.\(ext)")
            return FileTypeStat(
                extensionName: ext,
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: size,
                fileCount: countByExt[ext] ?? 0,
                percentage: totalSize > 0 ? Double(size) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }

        // Assign WinDirStat-style palette colors based on extension size ranking.
        extensionPalette.assign(from: fileTypeStats)
        computeReclaimScores()
        loadSnapshotIfAvailable()
    }

    /// Compute per-directory reclaim score (0-100) using size/staleness/cache/duplicate factors.
    public func computeReclaimScores() {
        guard let tree = fileTree else {
            reclaimScores = []
            return
        }
        let nodes = tree.nodesSnapshot()
        guard !nodes.isEmpty else {
            reclaimScores = []
            return
        }

        // Step 1: Bottom-up pass for cache bytes per node.
        let colorMap = ExtensionColorMap.shared
        var cacheBytesPerNode = Array(repeating: UInt64(0), count: nodes.count)
        for i in stride(from: nodes.count - 1, through: 0, by: -1) {
            let node = nodes[i]
            if !node.isDirectory, colorMap.category(forHash: node.extensionHash) == .caches {
                cacheBytesPerNode[i] = node.fileSize
            }
            let parentIndex = node.parentIndex
            if parentIndex != FileNode.invalid {
                let parentInt = Int(parentIndex)
                if parentInt < cacheBytesPerNode.count {
                    cacheBytesPerNode[parentInt] += cacheBytesPerNode[i]
                }
            }
        }

        // Step 2: Duplicate wasted bytes by directory from duplicateGroups paths.
        var dupWastedByDir: [UInt32: UInt64] = [:]
        if !duplicateGroups.isEmpty {
            var pathToIndex: [String: UInt32] = [:]
            pathToIndex.reserveCapacity(nodes.count)
            for i in 0..<nodes.count {
                pathToIndex[tree.path(at: UInt32(i))] = UInt32(i)
            }

            for group in duplicateGroups where group.paths.count > 1 {
                for path in group.paths.dropFirst() {
                    guard let fileIndex = pathToIndex[path] else { continue }
                    var current = fileIndex
                    var hops = 0
                    while current != FileNode.invalid, hops < nodes.count {
                        let currentInt = Int(current)
                        guard currentInt < nodes.count else { break }
                        let currentNode = nodes[currentInt]
                        if currentNode.isDirectory {
                            dupWastedByDir[current, default: 0] += group.fileSize
                        }
                        current = currentNode.parentIndex
                        hops += 1
                    }
                }
            }
        }

        // Step 3: Max child size per parent (sibling normalization).
        var maxChildSizeByParent: [UInt32: UInt64] = [:]
        maxChildSizeByParent.reserveCapacity(nodes.count / 2)
        for i in 0..<nodes.count {
            let parentIndex = nodes[i].parentIndex
            if parentIndex == FileNode.invalid { continue }
            let childSize = nodes[i].fileSize
            if childSize > (maxChildSizeByParent[parentIndex] ?? 0) {
                maxChildSizeByParent[parentIndex] = childSize
            }
        }

        // Step 4: Direct-file modified timestamps per directory.
        var childTimestamps: [UInt32: [UInt32]] = [:]
        childTimestamps.reserveCapacity(nodes.count / 2)
        for i in 0..<nodes.count {
            let node = nodes[i]
            guard !node.isDirectory else { continue }
            let parentIndex = node.parentIndex
            if parentIndex == FileNode.invalid { continue }
            childTimestamps[parentIndex, default: []].append(node.modifiedDate)
        }

        // Step 5: Final score per directory.
        let nowSeconds = UInt32(Date().timeIntervalSince1970)
        var scores = Array(repeating: UInt8(0), count: nodes.count)

        for i in 0..<nodes.count {
            let node = nodes[i]
            guard node.isDirectory else {
                scores[i] = 0
                continue
            }

            let sizeFactor: Double
            if i == 0 {
                sizeFactor = 1.0
            } else if node.parentIndex == FileNode.invalid {
                sizeFactor = 0
            } else {
                let maxSiblingSize = maxChildSizeByParent[node.parentIndex] ?? 0
                if maxSiblingSize == 0 {
                    sizeFactor = 0
                } else {
                    let numerator = Foundation.log(Double(1 + node.fileSize))
                    let denominator = Foundation.log(Double(1 + maxSiblingSize))
                    let raw = denominator > 0 ? numerator / denominator : 0
                    sizeFactor = min(max(raw, 0), 1)
                }
            }

            let stalenessFactor: Double
            if var timestamps = childTimestamps[UInt32(i)], !timestamps.isEmpty {
                timestamps.sort()
                let medianTimestamp = timestamps[timestamps.count / 2]
                if medianTimestamp == 0 {
                    stalenessFactor = 0
                } else {
                    let ageSeconds = nowSeconds > medianTimestamp ? nowSeconds - medianTimestamp : 0
                    let ageDays = Double(ageSeconds) / 86_400.0
                    stalenessFactor = min(ageDays, 730.0) / 730.0
                }
            } else {
                stalenessFactor = 0
            }

            let totalBytes = node.fileSize
            let cacheFactor: Double = totalBytes > 0
                ? Double(cacheBytesPerNode[i]) / Double(totalBytes)
                : 0

            let dupWasted = dupWastedByDir[UInt32(i)] ?? 0
            let dupFactor: Double = totalBytes > 0
                ? min(Double(dupWasted) / Double(totalBytes), 1.0)
                : 0

            let weighted = (0.35 * sizeFactor) +
                (0.25 * stalenessFactor) +
                (0.25 * cacheFactor) +
                (0.15 * dupFactor)
            let score = Int((weighted * 100.0).rounded())
            scores[i] = UInt8(clamping: min(max(score, 0), 100))
        }

        reclaimScores = scores
    }

    // MARK: - Recency

    /// Apply recency factors — discards stale results from a superseded scan.
    public func applyRecencyFactors(_ factors: [Float], token: UInt64) {
        guard token == recencyToken else { return }
        recencyFactors = factors
        recencyGeneration &+= 1
        isRecencyQueryRunning = false
    }

    /// Start a Spotlight recency query if one is not already running.
    public func startRecencyQueryIfNeeded() {
        guard !isRecencyQueryRunning, let tree = fileTree else { return }
        isRecencyQueryRunning = true
        recencyToken &+= 1
        let token = recencyToken
        let service = RecencyQueryService()
        Task {
            let factors = await service.queryRecency(tree: tree)
            await MainActor.run {
                self.applyRecencyFactors(factors, token: token)
            }
        }
    }

    // MARK: - Temporal Diff

    /// Build a snapshot from the current scan and persist it to disk.
    public func takeSnapshot() {
        guard !isSnapshotBuilding, let tree = fileTree else { return }
        isSnapshotBuilding = true
        Task.detached(priority: .utility) {
            let snapshot = await TemporalDiffService.buildSnapshot(tree: tree)
            try? snapshot.save()
            await MainActor.run {
                self.temporalSnapshot = snapshot
                self.isSnapshotBuilding = false
            }
        }
    }

    /// Try to load a persisted snapshot matching the current scan root.
    public func loadSnapshotIfAvailable() {
        guard let tree = fileTree else { return }
        Task.detached(priority: .background) {
            let rootPath = tree.path(at: 0)
            guard let snapshot = try? TemporalSnapshot.load(for: rootPath) else { return }
            await MainActor.run {
                self.temporalSnapshot = snapshot
            }
        }
    }

    /// Apply a diff result — discards stale results from a superseded scan.
    public func applyTemporalDiff(_ result: TemporalDiffResult, token: UInt64) {
        guard token == temporalDiffToken else { return }
        temporalDiffKinds = result.kinds
        temporalDiffStrengths = result.strengths
        temporalDiffDeletedCounts = result.deletedByNode
        temporalDiffGeneration &+= 1
    }

    /// Start diff computation between the current tree and the loaded snapshot.
    public func startTemporalDiff() {
        guard let snapshot = temporalSnapshot, let tree = fileTree else { return }
        temporalDiffTask?.cancel()
        temporalDiffToken &+= 1
        let token = temporalDiffToken
        temporalDiffTask = Task.detached(priority: .utility) {
            let result = await TemporalDiffService.computeDiff(
                currentTree: tree, snapshot: snapshot)
            await MainActor.run {
                self.applyTemporalDiff(result, token: token)
            }
        }
    }

    private static func extractExtension(from name: String) -> String {
        guard let dotIndex = name.lastIndex(of: ".") else { return "(no ext)" }
        let ext = String(name[name.index(after: dotIndex)...]).lowercased()
        return ext.isEmpty ? "(no ext)" : ext
    }
}

// MARK: - Supporting Types

public enum DetailTab: String, CaseIterable, Identifiable {
    case treeView = "Tree View"
    case extensions = "Extensions"
    case duplicates = "Duplicates"
    case search = "Search"

    public var id: String { rawValue }
}

public struct VolumeInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let totalCapacity: UInt64
    public let availableCapacity: UInt64
    public let usedCapacity: UInt64

    public init(url: URL) {
        self.url = url
        self.id = url.path

        let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])

        self.name = values?.volumeName ?? url.lastPathComponent
        let total = UInt64(values?.volumeTotalCapacity ?? 0)
        // Prefer APFS-aware "important usage" capacity, but fall back to
        // the basic available capacity for non-APFS volumes (exFAT, HFS+, etc.)
        // where the APFS key returns nil.
        let available: UInt64
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = UInt64(important)
        } else {
            available = UInt64(values?.volumeAvailableCapacity ?? 0)
        }
        self.totalCapacity = total
        self.availableCapacity = available
        self.usedCapacity = total > available ? total - available : 0
    }
}

public struct ExtensionStat: Identifiable, Sendable {
    public let id = UUID()
    public let extensionHash: UInt16
    public let category: FileCategory
    public let totalSize: UInt64
    public let fileCount: Int
    public let percentage: Double
}

/// Per-extension-name stat for the file types list.
public struct FileTypeStat: Identifiable, Sendable {
    public let id = UUID()
    public let extensionName: String
    public let extensionHash: UInt16
    public let category: FileCategory
    public let totalSize: UInt64
    public let fileCount: Int
    public let percentage: Double
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id = UUID()
    public let fileSize: UInt64
    public let hash: UInt64
    public let paths: [String]

    public var wastedSpace: UInt64 {
        fileSize * UInt64(max(0, paths.count - 1))
    }

    public var count: Int { paths.count }
}
