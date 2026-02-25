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

    /// Duplicate file groups (populated after duplicate scan).
    public var duplicateGroups: [DuplicateGroup] = []

    /// Whether duplicate scan is in progress.
    public var isDuplicateScanRunning: Bool = false

    /// Whether Full Disk Access is granted.
    public var hasFullDiskAccess: Bool = false

    // MARK: - Navigation History

    private var backStack: [UInt32] = []
    private var forwardStack: [UInt32] = []

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
        duplicateGroups = []
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
                category: colorMap.category(forHash: hash),
                totalSize: size,
                fileCount: countByExt[ext] ?? 0,
                percentage: totalSize > 0 ? Double(size) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }
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
