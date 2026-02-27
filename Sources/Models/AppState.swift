import SwiftUI
import Quartz

/// Central observable state for the application.
/// All properties are MainActor-isolated — the compiler enforces that mutations
/// only happen on the main thread. Background work uses `Task.detached` +
/// `MainActor.run` to funnel results back.
@MainActor
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

    /// Navigation state (treemap root, breadcrumb path, back/forward stacks).
    public var navigation = NavigationState()

    /// Search state (query, results, in-progress flag).
    public var search = SearchState()

    /// Duplicate scan state (groups, checked paths, progress).
    public var duplicate = DuplicateState()

    /// Hardlink groups (populated after hardlink scan).
    public var hardlinkGroups: [HardlinkGroup] = []
    public var hardlinkExpandedGroups: Set<UUID> = []
    public var hardlinkProgress: (processed: Int, total: Int) = (0, 0)
    public var isHardlinkScanRunning: Bool = false
    var hardlinkToken: UInt64 = 0
    @ObservationIgnored var hardlinkTask: Task<Void, Never>?

    /// Temporal diff overlay state (snapshot, kinds, strengths, generation).
    public var temporalDiff = TemporalDiffState()

    /// Selected volume URL to scan.
    public var selectedVolume: URL?

    /// Available volumes.
    public var availableVolumes: [VolumeInfo] = []

    /// Active tab in detail area.
    public var activeTab: DetailTab = .treeView

    /// Per-extension-name stats for the Extensions tab (individual file types).
    public var fileTypeStats: [FileTypeStat] = []

    /// WinDirStat-style per-extension color palette (top 17 by size).
    public var extensionPalette = ExtensionPalette()

    /// Per-node Spotlight recency factor [0,1] (1=recently used, 0=stale/unindexed).
    public var recencyFactors: [Float] = []

    /// Bumped each time recencyFactors is updated, for GPU change detection.
    public var recencyGeneration: UInt64 = 0

    /// Whether the recency heatmap overlay is active.
    public var isRecencyOverlayEnabled: Bool = false

    /// Whether a Spotlight recency query is in progress.
    public var isRecencyQueryRunning: Bool = false

    // MARK: - Space Analysis

    /// Results of the space categorization analysis.
    public var spaceAnalysis: SpaceAnalysisResult?
    public var spaceAnalysisProgress: (completed: Int, total: Int) = (0, 0)
    public var isSpaceAnalysisRunning: Bool = false

    /// File age analysis results.
    public var fileAgeResult: FileAgeResult?
    public var isFileAgeRunning: Bool = false

    /// Size distribution analysis results.
    public var sizeDistribution: SizeDistributionResult?
    public var isSizeDistRunning: Bool = false

    // MARK: - iCloud

    /// iCloud analysis results.
    public var iCloudResult: iCloudAnalysisResult?
    public var isICloudAnalysisRunning: Bool = false

    // MARK: - APFS Intelligence

    /// Purgeable space info for the scanned volume.
    public var purgeableSpace: PurgeableSpaceInfo?

    /// Time Machine local snapshots.
    public var tmSnapshots: TMSnapshotInfo?
    public var isAPFSQueryRunning: Bool = false

    /// Clone check results for duplicate groups.
    public var cloneResults: [CloneCheckResult] = []
    public var isCloneCheckRunning: Bool = false

    // MARK: - FSEvents Monitoring

    /// Active FSEvents monitor for the scanned directory.
    @ObservationIgnored public var fsEventsMonitor: FSEventsMonitor?

    /// Accumulated filesystem changes since scan.
    public var fsChanges: [DirectoryChangeSummary] = []
    public var isFSMonitoringActive: Bool = false

    // MARK: - Storage Trends

    /// Historical scan summaries.
    public var storageTrendHistory: [ScanSummary] = []

    // MARK: - Scan Timing

    /// Wall-clock time when the most recent scan started (CFAbsoluteTime).
    public var scanStartTime: CFAbsoluteTime = 0

    /// Total elapsed seconds for the last completed scan. Zero if no scan has finished yet.
    public var scanDuration: TimeInterval = 0

    /// Whether Full Disk Access is granted.
    public var hasFullDiskAccess: Bool = false

    // MARK: - Internal State (used by extensions in other files)

    /// The currently active scanner. Set by both ContentView.startScan() and rescanVolume()
    /// so the Cancel button always targets the right scanner.
    @ObservationIgnored public var activeScanner: FileScanner?

    /// Token incremented on each new scan; used to discard stale async results.
    public var scanToken: UInt64 = 0
    var duplicateToken: UInt64 = 0
    @ObservationIgnored var duplicateTask: Task<Void, Never>?
    var recencyToken: UInt64 = 0
    var recencyTask: Task<Void, Never>?
    var temporalDiffToken: UInt64 = 0
    var temporalDiffTask: Task<Void, Never>?
    @ObservationIgnored var snapshotBuildTask: Task<Void, Never>?
    @ObservationIgnored var spaceAnalysisTask: Task<Void, Never>?
    @ObservationIgnored var iCloudAnalysisTask: Task<Void, Never>?
    @ObservationIgnored var apfsQueryTask: Task<Void, Never>?
    @ObservationIgnored var cloneCheckTask: Task<Void, Never>?

    public init() {}

    public enum HeavyTaskKind: String, Sendable, CaseIterable {
        case duplicateScan
        case hardlinkScan
        case spaceAnalysis
        case iCloudAnalysis
        case apfsQuery
        case cloneCheck

        var statusText: String {
            switch self {
            case .duplicateScan:
                return "Scanning duplicates"
            case .hardlinkScan:
                return "Scanning hardlinks"
            case .spaceAnalysis:
                return "Running insights analysis"
            case .iCloudAnalysis:
                return "Checking iCloud status"
            case .apfsQuery:
                return "Querying volume info"
            case .cloneCheck:
                return "Checking APFS clones"
            }
        }
    }

    public var activeHeavyTask: HeavyTaskKind? {
        if duplicate.isDuplicateScanRunning { return .duplicateScan }
        if isHardlinkScanRunning { return .hardlinkScan }
        if isSpaceAnalysisRunning { return .spaceAnalysis }
        if isICloudAnalysisRunning { return .iCloudAnalysis }
        if isAPFSQueryRunning { return .apfsQuery }
        if isCloneCheckRunning { return .cloneCheck }
        return nil
    }

    public var activeHeavyTaskStatusText: String? {
        activeHeavyTask?.statusText
    }

    public func canStartHeavyTask(_ kind: HeavyTaskKind) -> Bool {
        guard fileTree != nil, !scanProgress.isScanning else { return false }

        switch kind {
        case .duplicateScan:
            return !duplicate.isDuplicateScanRunning && activeHeavyTaskExcluding(kind) == nil
        case .hardlinkScan:
            return !isHardlinkScanRunning && activeHeavyTaskExcluding(kind) == nil
        case .spaceAnalysis:
            return !isSpaceAnalysisRunning && activeHeavyTaskExcluding(kind) == nil
        case .iCloudAnalysis:
            return !isICloudAnalysisRunning && activeHeavyTaskExcluding(kind) == nil
        case .apfsQuery:
            return !isAPFSQueryRunning && activeHeavyTaskExcluding(kind) == nil
        case .cloneCheck:
            return !isCloneCheckRunning && activeHeavyTaskExcluding(kind) == nil
        }
    }

    private func activeHeavyTaskExcluding(_ excluded: HeavyTaskKind) -> HeavyTaskKind? {
        for kind in HeavyTaskKind.allCases where kind != excluded {
            switch kind {
            case .duplicateScan where duplicate.isDuplicateScanRunning:
                return kind
            case .hardlinkScan where isHardlinkScanRunning:
                return kind
            case .spaceAnalysis where isSpaceAnalysisRunning:
                return kind
            case .iCloudAnalysis where isICloudAnalysisRunning:
                return kind
            case .apfsQuery where isAPFSQueryRunning:
                return kind
            case .cloneCheck where isCloneCheckRunning:
                return kind
            default:
                continue
            }
        }
        return nil
    }

    /// Reset navigation state for a new scan.
    public func resetForNewScan() {
        navigation.reset()
        search.reset()
        duplicate.reset()
        temporalDiff.reset()
        hardlinkGroups = []
        hardlinkExpandedGroups = []
        hardlinkProgress = (0, 0)
        isHardlinkScanRunning = false
        hardlinkToken &+= 1
        hardlinkTask?.cancel()
        hardlinkTask = nil
        selectedNodeIndex = nil
        fileTypeStats = []
        extensionPalette = ExtensionPalette()
        recencyFactors = []
        recencyGeneration = 0
        isRecencyOverlayEnabled = false
        isRecencyQueryRunning = false
        scanToken &+= 1
        duplicateToken &+= 1
        duplicateTask?.cancel()
        duplicateTask = nil
        recencyToken &+= 1
        recencyTask?.cancel()
        recencyTask = nil
        temporalDiffTask?.cancel()
        temporalDiffTask = nil
        temporalDiffToken &+= 1
        snapshotBuildTask?.cancel()
        snapshotBuildTask = nil
        spaceAnalysisTask?.cancel()
        spaceAnalysisTask = nil
        iCloudAnalysisTask?.cancel()
        iCloudAnalysisTask = nil
        apfsQueryTask?.cancel()
        apfsQueryTask = nil
        cloneCheckTask?.cancel()
        cloneCheckTask = nil
        spaceAnalysis = nil
        spaceAnalysisProgress = (0, 0)
        isSpaceAnalysisRunning = false
        fileAgeResult = nil
        isFileAgeRunning = false
        sizeDistribution = nil
        isSizeDistRunning = false
        iCloudResult = nil
        isICloudAnalysisRunning = false
        purgeableSpace = nil
        tmSnapshots = nil
        isAPFSQueryRunning = false
        cloneResults = []
        isCloneCheckRunning = false
        fsEventsMonitor?.stop()
        fsEventsMonitor = nil
        fsChanges = []
        isFSMonitoringActive = false
        scanStartTime = 0
        scanDuration = 0
        // Create a fresh ScanProgress so old scanner finalizations write to the
        // abandoned instance and cannot corrupt the new scan's counters.
        scanProgress = ScanProgress()
    }
}

// MARK: - Supporting Types

public enum DetailTab: String, CaseIterable, Identifiable {
    case treeView = "Tree View"
    case extensions = "Extensions"
    case duplicates = "Duplicates"
    case hardlinks = "Hardlinks"
    case search = "Search"
    case spaceAnalysis = "Space"
    case insights = "Insights"

    public var id: String { rawValue }
}

public struct VolumeInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let totalCapacity: UInt64
    public let availableCapacity: UInt64
    public let usedCapacity: UInt64

    public init(url: URL, values: URLResourceValues? = nil) {
        self.url = url
        self.id = url.path

        let v = values ?? (try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]))

        self.name = v?.volumeName ?? url.lastPathComponent
        let total = UInt64(v?.volumeTotalCapacity ?? 0)
        // Prefer APFS-aware "important usage" capacity, but fall back to
        // the basic available capacity for non-APFS volumes (exFAT, HFS+, etc.)
        // where the APFS key returns nil.
        let available: UInt64
        if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = UInt64(important)
        } else {
            available = UInt64(v?.volumeAvailableCapacity ?? 0)
        }
        self.totalCapacity = total
        self.availableCapacity = available
        self.usedCapacity = total > available ? total - available : 0
    }
}

/// Per-extension-name stat for the file types list.
public struct FileTypeStat: Identifiable, Sendable {
    public let id = UUID()
    public let extensionName: String
    public let extensionHash: UInt32
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
