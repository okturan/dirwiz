import SwiftUI
import Quartz

/// Central observable state for the application.
@Observable
public final class AppState {
    /// The scanned file tree.
    public var fileTree: FileTree?

    /// Scan progress state.
    public var scanProgress = ScanProgress()

    /// Currently selected node in tree view / treemap.
    public var selectedNodeIndex: UInt32?

    /// Coordinator for Quick Look panel — holds data source / controller conformance.
    public let quickLookCoordinator = QLPreviewCoordinator()

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

    /// Duplicates tab UI state: checked file paths.
    public var duplicateCheckedPaths: Set<String> = []

    /// Duplicates tab UI state: expanded duplicate group IDs.
    public var duplicateExpandedGroups: Set<UUID> = []

    /// Duplicates tab UI state: progress of current duplicate scan.
    public var duplicateProgress: (processed: Int, total: Int) = (0, 0)

    /// Search tab UI state: current query text.
    public var searchQuery: String = ""

    /// Search tab UI state: current matched node indices.
    public var searchResults: [UInt32] = []

    /// Search tab UI state: whether search is currently running.
    public var isSearching: Bool = false

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

    // MARK: - Scan Timing

    /// Wall-clock time when the most recent scan started (CFAbsoluteTime).
    public var scanStartTime: CFAbsoluteTime = 0

    /// Total elapsed seconds for the last completed scan. Zero if no scan has finished yet.
    public var scanDuration: TimeInterval = 0

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

    // MARK: - Internal State (used by extensions in other files)

    var backStack: [UInt32] = []
    var forwardStack: [UInt32] = []

    /// Token incremented on each new scan; used to discard stale async results.
    var recencyToken: UInt64 = 0
    var temporalDiffToken: UInt64 = 0
    var temporalDiffTask: Task<Void, Never>?

    public var canNavigateBack: Bool { !backStack.isEmpty }
    public var canNavigateForward: Bool { !forwardStack.isEmpty }
    public var canNavigateUp: Bool { treemapPath.count > 1 }

    public init() {}

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
        duplicateCheckedPaths = []
        duplicateExpandedGroups = []
        duplicateProgress = (0, 0)
        searchQuery = ""
        searchResults = []
        isSearching = false
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
        scanStartTime = 0
        scanDuration = 0
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
}
