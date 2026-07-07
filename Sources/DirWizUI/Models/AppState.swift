import SwiftUI
import DirWizCore
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
    var hardlinkTask: Task<Void, Never>? {
        get { analysisCoordinator.hardlinkTask }
        set { analysisCoordinator.hardlinkTask = newValue }
    }

    /// Temporal diff overlay state (snapshot, kinds, strengths, generation).
    public var temporalDiff = TemporalDiffState()

    /// Scan lifecycle state and active scanner ownership.
    public var scanSession = ScanSession()

    /// Long-running analysis task ownership.
    public var analysisCoordinator = AnalysisCoordinator()

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
    public var isBundleSizingRunning: Bool = false

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
    public var scanStartTime: CFAbsoluteTime {
        get { scanSession.startTime }
        set { scanSession.startTime = newValue }
    }

    /// Total elapsed seconds for the last completed scan. Zero if no scan has finished yet.
    public var scanDuration: TimeInterval {
        get { scanSession.duration }
        set { scanSession.duration = newValue }
    }

    /// Whether Full Disk Access is granted.
    public var hasFullDiskAccess: Bool = false

    // MARK: - Internal State (used by extensions in other files)

    /// The currently active scanner. Set by both ContentView.startScan() and rescanVolume()
    /// so the Cancel button always targets the right scanner.
    public var activeScanner: FileScanner? {
        get { scanSession.activeScanner }
        set { scanSession.activeScanner = newValue }
    }

    /// Token incremented on each new scan; used to discard stale async results.
    public var scanToken: UInt64 {
        get { scanSession.token }
        set { scanSession.token = newValue }
    }
    var duplicateToken: UInt64 = 0
    var duplicateTask: Task<Void, Never>? {
        get { analysisCoordinator.duplicateTask }
        set { analysisCoordinator.duplicateTask = newValue }
    }
    var recencyToken: UInt64 = 0
    var recencyTask: Task<Void, Never>?
    var temporalDiffToken: UInt64 = 0
    var temporalDiffTask: Task<Void, Never>?
    @ObservationIgnored var snapshotBuildTask: Task<Void, Never>?
    var spaceAnalysisTask: Task<Void, Never>? {
        get { analysisCoordinator.spaceAnalysisTask }
        set { analysisCoordinator.spaceAnalysisTask = newValue }
    }
    var iCloudAnalysisTask: Task<Void, Never>? {
        get { analysisCoordinator.iCloudAnalysisTask }
        set { analysisCoordinator.iCloudAnalysisTask = newValue }
    }
    var apfsQueryTask: Task<Void, Never>? {
        get { analysisCoordinator.apfsQueryTask }
        set { analysisCoordinator.apfsQueryTask = newValue }
    }
    var cloneCheckTask: Task<Void, Never>? {
        get { analysisCoordinator.cloneCheckTask }
        set { analysisCoordinator.cloneCheckTask = newValue }
    }
    var bundleSizingTask: Task<Void, Never>? {
        get { analysisCoordinator.bundleSizingTask }
        set { analysisCoordinator.bundleSizingTask = newValue }
    }

    public init() {}

    public enum HeavyTaskKind: String, Sendable, CaseIterable {
        case duplicateScan
        case hardlinkScan
        case spaceAnalysis
        case iCloudAnalysis
        case apfsQuery
        case cloneCheck
        case bundleSizing

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
            case .bundleSizing:
                return "Resolving app bundle sizes"
            }
        }

        /// Single source of truth mapping each case to its running flag on `AppState`.
        @MainActor
        func isRunning(in state: AppState) -> Bool {
            switch self {
            case .duplicateScan: return state.duplicate.isDuplicateScanRunning
            case .hardlinkScan: return state.isHardlinkScanRunning
            case .spaceAnalysis: return state.isSpaceAnalysisRunning
            case .iCloudAnalysis: return state.isICloudAnalysisRunning
            case .apfsQuery: return state.isAPFSQueryRunning
            case .cloneCheck: return state.isCloneCheckRunning
            case .bundleSizing: return state.isBundleSizingRunning
            }
        }
    }

    public var activeHeavyTask: HeavyTaskKind? {
        HeavyTaskKind.allCases.first { $0.isRunning(in: self) }
    }

    public var activeHeavyTaskStatusText: String? {
        activeHeavyTask?.statusText
    }

    public func canStartHeavyTask(_ kind: HeavyTaskKind) -> Bool {
        guard fileTree != nil, !scanProgress.isScanning else { return false }
        return !kind.isRunning(in: self) && activeHeavyTaskExcluding(kind) == nil
    }

    private func activeHeavyTaskExcluding(_ excluded: HeavyTaskKind) -> HeavyTaskKind? {
        HeavyTaskKind.allCases.first { $0 != excluded && $0.isRunning(in: self) }
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
        selectedNodeIndex = nil
        fileTypeStats = []
        extensionPalette = ExtensionPalette()
        recencyFactors = []
        recencyGeneration = 0
        isRecencyOverlayEnabled = false
        isRecencyQueryRunning = false
        scanSession.invalidate()
        duplicateToken &+= 1
        recencyToken &+= 1
        recencyTask?.cancel()
        recencyTask = nil
        temporalDiffTask?.cancel()
        temporalDiffTask = nil
        temporalDiffToken &+= 1
        snapshotBuildTask?.cancel()
        snapshotBuildTask = nil
        analysisCoordinator.cancelAll()
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
        isBundleSizingRunning = false
        fsEventsMonitor?.stop()
        fsEventsMonitor = nil
        fsChanges = []
        isFSMonitoringActive = false
        scanSession.resetTiming()
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
