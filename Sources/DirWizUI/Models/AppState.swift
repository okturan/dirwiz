import SwiftUI
import DirWizCore
import Quartz

/// Test-visible breadcrumb trail for diagnosing scan-supervision failures without
/// inferring an async path from whichever assertion happened to fire last.
struct ScanSupervisionTrace: Equatable, Sendable {
    var journalReplayOutcome = "not attempted"
    var plannerDecision = "not reached"
    var abandonmentReason: String?
    var coldFallbackReason: String?
}

/// Central observable state for the application.
/// All properties are MainActor-isolated - the compiler enforces that mutations
/// only happen on the main thread. Background work uses `Task.detached` +
/// `MainActor.run` to funnel results back.
@MainActor
@Observable
public final class AppState {
    /// The scanned file tree.
    public var fileTree: FileTree?

    /// Scan progress state.
    public var scanProgress = ScanProgress()

    /// Currently selected node in tree view / treemap. `didSet` persists the current
    /// selection + treemap root into the per-volume session (plan 038, `AppState+Scan.swift`)
    /// so the next launch can restore "where you were" - every call site across the app
    /// (tree clicks, keyboard nav, search, treemap, trash-restore) assigns this property
    /// directly rather than through a single function, so `didSet` is the one choke point
    /// that sees them all.
    public var selectedNodeIndex: UInt32? {
        didSet {
            guard !isRejectingWarmPatchSelection else { return }
            // FileScanner's transactional warm splice changes every downstream index
            // atomically. Reject the tiny commit-to-invalidation interaction window:
            // the event's index belongs to the old layout, while fileTree already holds
            // the new layout. The canonical invalidator clears this flag before
            // restoring the durable path-keyed selection.
            if isWarmPatchCommitInProgress {
                isRejectingWarmPatchSelection = true
                selectedNodeIndex = oldValue
                isRejectingWarmPatchSelection = false
                return
            }
            recordWarmPatchSelection()
            saveSelectionAndRootSession()
        }
    }

    /// Coordinator for Quick Look panel - holds data source / controller conformance.
    public let quickLookCoordinator = QLPreviewCoordinator()

    /// Navigation state (treemap root, breadcrumb path, back/forward stacks).
    public var navigation = NavigationState()

    /// Search state (query, results, in-progress flag).
    public var search = SearchState()

    /// Duplicate scan state (groups, checked paths, progress).
    public var duplicate = DuplicateState()

    /// Hardlink scan state (groups, expanded UI state, progress).
    public var hardlink = HardlinkState()
    var hardlinkToken: UInt64 = 0
    var hardlinkTask: Task<Void, Never>? {
        get { analysisCoordinator.hardlinkTask }
        set { analysisCoordinator.hardlinkTask = newValue }
    }

    /// Temporal diff overlay state (snapshot, kinds, strengths, generation).
    public var temporalDiff = TemporalDiffState()

    /// Scan lifecycle state and active scanner ownership.
    public var scanSession = ScanSession()

    /// Diagnostics only: reset for each admitted scan flow, then populated at the actual
    /// replay/decision/abandonment boundaries. Kept out of observation so collecting
    /// evidence cannot perturb view updates or supervision timing.
    @ObservationIgnored var scanSupervisionTrace = ScanSupervisionTrace()

    /// Long-running analysis task ownership.
    public var analysisCoordinator = AnalysisCoordinator()

    /// Selected volume URL to scan.
    public var selectedVolume: URL? {
        didSet {
            guard selectedVolume?.path != oldValue?.path else { return }
            // Never carry one disk's free-space sample or latched warning into another
            // disk while its first statfs is still pending.
            menuBarVolumeGauge = nil
            isLowSpace = false
        }
    }

    /// Mount scope for the next scan selection. This is deliberately session-only:
    /// relaunch and ordinary volume selection return to one-volume-at-a-time semantics.
    public var selectedMountTraversalScope: MountTraversalScope = .selectedVolume

    /// Available volumes.
    public var availableVolumes: [VolumeInfo] = []

    /// Invalidates a deferred availability recovery when a newer mount-list fact arrives. Recovery
    /// waits only for an already-committing living-view splice, which cannot safely be cancelled.
    @ObservationIgnored var volumeAvailabilityGeneration: UInt64 = 0

    public var isCombinedVolumeSelection: Bool {
        selectedMountTraversalScope == .combinedVolumes
    }

    /// Identity of the currently selected scan target, including scope. This is used for
    /// diagnostics before a matching tree necessarily exists.
    public var selectedScanPersistenceIdentity: String? {
        guard let selectedVolume else { return nil }
        return selectedMountTraversalScope.persistenceIdentity(for: selectedVolume.path)
    }

    /// Select one concrete volume and restore the default same-device boundary.
    public func selectVolume(_ url: URL) {
        selectedVolume = url
        selectedMountTraversalScope = .selectedVolume
    }

    /// Select the explicit one-map overview. The scan root is `/`; scope, not path alone,
    /// distinguishes this from an individual boot-volume scan.
    public func selectCombinedVolumes() {
        selectedVolume = URL(fileURLWithPath: "/", isDirectory: true)
        selectedMountTraversalScope = .combinedVolumes
    }

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

    /// How the treemap paints its rectangles. A user preference, not scan state - it is
    /// deliberately NOT reset by `resetForNewScan()`, and persists across launches.
    public var treemapRenderStyle: TreemapRenderStyle = .cushion {
        didSet {
            guard treemapRenderStyle != oldValue else { return }
            defaults.set(treemapRenderStyle.rawValue, forKey: AppState.renderStyleKey)
        }
    }

    /// The Folders depth palette, a user setting (Settings window). Nord is the shipped
    /// default - the winner of the native review on real volume trees.
    public var foldersColorScheme: FoldersColorScheme = .nord {
        didSet {
            guard foldersColorScheme != oldValue else { return }
            defaults.set(foldersColorScheme.rawValue, forKey: AppState.foldersColorSchemeKey)
        }
    }

    /// The Folders surface, a user setting independent from palette: it controls
    /// boundaries, parent chrome, title rows, and nesting pad only. Fine Lines is the
    /// shipped default - the review winner alongside Nord.
    public var foldersSurfaceStyle: FoldersSurfaceStyle = .fineLines {
        didSet {
            guard foldersSurfaceStyle != oldValue else { return }
            defaults.set(foldersSurfaceStyle.rawValue, forKey: AppState.foldersSurfaceStyleKey)
        }
    }

    /// Presents the full file-type table. It used to be a whole tab, which duplicated the
    /// always-visible sidebar legend; the legend is now the only file-type surface and this
    /// sheet is its "see everything" affordance.
    public var showAllFileTypes: Bool = false

    static let renderStyleKey = "DirWizTreemapRenderStyle"
    static let foldersColorSchemeKey = "DirWizFoldersColorScheme"
    static let foldersSurfaceStyleKey = "DirWizFoldersSurfaceStyle"

    // MARK: - Menu Bar Presence

    /// The item can be removed independently once background residency is disabled.
    public var showsMenuBarItem: Bool = true {
        didSet {
            guard !isLoadingMenuBarPreferences, showsMenuBarItem != oldValue else { return }
            defaults.set(showsMenuBarItem, forKey: AppState.showsMenuBarItemKey)
            if !showsMenuBarItem, keepsRunningInMenuBar {
                keepsRunningInMenuBar = false
            }
        }
    }

    /// Default-on residency: closing the last window keeps the existing living view alive.
    public var keepsRunningInMenuBar: Bool = true {
        didSet {
            guard !isLoadingMenuBarPreferences, keepsRunningInMenuBar != oldValue else { return }
            defaults.set(keepsRunningInMenuBar, forKey: AppState.keepsRunningInMenuBarKey)
            if keepsRunningInMenuBar, !showsMenuBarItem {
                showsMenuBarItem = true
            }
        }
    }

    public var showsFreeSpaceInMenuBar: Bool = false {
        didSet {
            guard !isLoadingMenuBarPreferences, showsFreeSpaceInMenuBar != oldValue else { return }
            defaults.set(showsFreeSpaceInMenuBar, forKey: AppState.showsFreeSpaceInMenuBarKey)
        }
    }

    public var lowSpaceNotificationsEnabled: Bool = false {
        didSet {
            guard !isLoadingMenuBarPreferences, lowSpaceNotificationsEnabled != oldValue else { return }
            defaults.set(lowSpaceNotificationsEnabled, forKey: AppState.lowSpaceNotificationsEnabledKey)
            if lowSpaceNotificationsEnabled {
                requestNotificationAuthorization?()
                rearmLowSpacePolicyForNotificationEnable()
                refreshMenuBarVolumeStats()
            }
        }
    }

    /// Percentage arm of min(configured percent, 25 GiB). Stored as a whole-number percent.
    public var lowSpaceThresholdPercent: Double = 10 {
        didSet {
            guard !isLoadingMenuBarPreferences, lowSpaceThresholdPercent != oldValue else { return }
            defaults.set(lowSpaceThresholdPercent, forKey: AppState.lowSpaceThresholdPercentKey)
        }
    }

    public var growthNotificationsEnabled: Bool = false {
        didSet {
            guard !isLoadingMenuBarPreferences, growthNotificationsEnabled != oldValue else { return }
            defaults.set(growthNotificationsEnabled, forKey: AppState.growthNotificationsEnabledKey)
            if growthNotificationsEnabled { requestNotificationAuthorization?() }
        }
    }

    public var growthNotificationThresholdGiB: Double = 10 {
        didSet {
            guard !isLoadingMenuBarPreferences, growthNotificationThresholdGiB != oldValue else { return }
            defaults.set(growthNotificationThresholdGiB, forKey: AppState.growthNotificationThresholdGiBKey)
        }
    }

    /// Latest single-statfs sample, shared by the panel label and notification policy.
    public internal(set) var menuBarVolumeGauge: MenuBarVolumeGauge?
    public internal(set) var isLowSpace = false

    /// The executable shell installs these hooks. Tests and DirWizUI never import
    /// UserNotifications, keeping policy and persistence independent from OS prompts.
    @ObservationIgnored public var requestNotificationAuthorization: (() -> Void)?
    @ObservationIgnored public var postMenuBarNotification: ((MenuBarNotificationEvent) -> Void)?

    @ObservationIgnored var lowSpacePolicyStates: [String: LowSpacePolicy.State] = [:]
    @ObservationIgnored var isLoadingMenuBarPreferences = true
    public internal(set) var recentVolumePaths: [String] = []

    static let showsMenuBarItemKey = "DirWizShowsMenuBarItem"
    static let keepsRunningInMenuBarKey = "DirWizKeepsRunningInMenuBar"
    static let showsFreeSpaceInMenuBarKey = "DirWizShowsFreeSpaceInMenuBar"
    static let lowSpaceNotificationsEnabledKey = "DirWizLowSpaceNotificationsEnabled"
    static let lowSpaceThresholdPercentKey = "DirWizLowSpaceThresholdPercent"
    static let growthNotificationsEnabledKey = "DirWizGrowthNotificationsEnabled"
    static let growthNotificationThresholdGiBKey = "DirWizGrowthNotificationThresholdGiB"
    static let lowSpacePolicyStatesKey = "DirWizLowSpacePolicyStates"
    static let recentVolumePathsKey = "DirWizRecentVolumePaths"

    /// Whether the bottom treemap pane is collapsed to give the detail pane full height.
    /// A layout preference like `treemapRenderStyle`: persisted, and NOT reset by
    /// `resetForNewScan()` - a new scan must not spring the map back open.
    public var isTreemapPaneCollapsed: Bool = false {
        didSet {
            guard isTreemapPaneCollapsed != oldValue else { return }
            defaults.set(isTreemapPaneCollapsed, forKey: AppState.treemapCollapsedKey)
        }
    }

    static let treemapCollapsedKey = "DirWizTreemapPaneCollapsed"

    static func loadRenderStyle(_ defaults: UserDefaults) -> TreemapRenderStyle {
        guard let raw = defaults.string(forKey: renderStyleKey),
              let style = TreemapRenderStyle(rawValue: raw) else { return .cushion }
        return style
    }

    static func loadFoldersColorScheme(_ defaults: UserDefaults) -> FoldersColorScheme {
        FoldersColorScheme(rawValue: defaults.integer(forKey: foldersColorSchemeKey)) ?? .nord
    }

    static func loadFoldersSurfaceStyle(_ defaults: UserDefaults) -> FoldersSurfaceStyle {
        FoldersSurfaceStyle(rawValue: defaults.integer(forKey: foldersSurfaceStyleKey)) ?? .fineLines
    }

    static func loadLowSpacePolicyStates(
        _ defaults: UserDefaults
    ) -> [String: LowSpacePolicy.State] {
        guard let data = defaults.data(forKey: lowSpacePolicyStatesKey),
              let decoded = try? JSONDecoder().decode(
                  [String: LowSpacePolicy.State].self,
                  from: data
              ) else { return [:] }
        return decoded
    }

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

    /// True while `applyAccumulatedChanges()` (AppState+Analysis.swift) is splicing the
    /// accumulated `fsChanges` into the displayed tree - drives the change badge's spinner
    /// and slots into `HeavyTaskKind.applyChanges` for the shared exclusivity matrix.
    /// Deliberately NOT `scanProgress.isScanning`: that flag also blanks the detail pane
    /// (`ContentView`'s `isScanning && staleViewAsOf == nil` gate), which would defeat the
    /// point of a patch meant to feel instantaneous and keep the tree browsable throughout.
    public var isApplyingChanges: Bool = false

    // MARK: - Living view (auto-apply)

    /// User preference: pause auto-apply. Persisted, because someone who paused it once
    /// meant it, and having it silently resume next launch would be the same surprise
    /// auto-apply is supposed to avoid.
    public var liveRefreshPaused: Bool = false {
        didSet {
            guard liveRefreshPaused != oldValue else { return }
            defaults.set(liveRefreshPaused, forKey: AppState.livePausedKey)
        }
    }

    static let livePausedKey = "DirWizLiveRefreshPaused"

    /// When the most recent FSEvents batch arrived, and when the last auto-apply finished.
    /// Feed `LiveRefreshPolicy`; also drive the "updated Xs ago" pill.
    @ObservationIgnored public var lastLiveChangeAt: TimeInterval?
    public var lastLiveApplyAt: TimeInterval?

    /// Latest policy verdict, so the pill can explain itself instead of just spinning.
    public var liveRefreshDecision: LiveRefreshPolicy.Decision = .idle

    /// Bumped after each successful auto-apply. `SearchView` observes it to re-run the
    /// current query, so results do not silently describe a tree that no longer exists.
    public var liveRefreshGeneration: UInt64 = 0

    @ObservationIgnored public var liveRefreshTask: Task<Void, Never>?

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

    /// One-line human-readable summary of the most recently completed scan (warm
    /// or cold) - e.g. "Refreshed 3 folders from last scan in 0.4s" or "Scanned
    /// 12,345 items in 2.1s". Rendered in the sidebar's completed-scan block. Nil
    /// until a scan completes; cleared by `resetForNewScan()`.
    public var lastScanSummary: String?

    /// Non-nil while the displayed tree is a restored cache not yet freshened by a
    /// warm patch or cold rescan - drives the "Showing last scan · X ago" badge
    /// (`staleBadgeText`) and tells the scan flow to keep the displayed tree browsable
    /// instead of blanking it while a refresh runs behind it. Set by `restoreOnLaunch()`;
    /// cleared once any refresh (warm or cold) completes. NOT cleared on cancellation -
    /// the stale view and its badge stay put since nothing newer replaced them.
    public var staleViewAsOf: Date?

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

    /// Backing store for `lastScannedVolumePath` persistence (`restoreOnLaunch`,
    /// `AppState+Scan.swift`). Injectable so tests can round-trip against an isolated
    /// suite instead of the app's real `UserDefaults.standard`.
    @ObservationIgnored let defaults: UserDefaults

    /// OS-derived classifier for the warm patch's trailing tier. Injectable because
    /// real test fixtures live under Darwin's own temp root and therefore cannot model
    /// one interactive plus one ephemeral subtree without an explicit boundary.
    @ObservationIgnored let ephemeralPaths: EphemeralPaths

    /// Factory for the one scanner shared by both warm-patch tiers. Production uses the
    /// real filesystem; tests inject a gated provider to stop exactly between the
    /// interactive publication and the deferred splice.
    @ObservationIgnored let warmPatchScannerFactory: @Sendable () -> FileScanner

    /// Journal replay seam for deterministic supervision tests. Production always uses
    /// the real FSEvents journal; tests can hold that prerequisite constant while they
    /// exercise AppState's warm/cold supervision transitions.
    @ObservationIgnored let warmStartJournalReplay:
        @Sendable (_ root: String, _ sinceEventId: UInt64) async -> JournalReplay

    /// Persistence seam for the cold scan's final cache write. Production always uses
    /// `TreeCache.save`; tests can stop at this exact boundary instead of treating the
    /// bundle-sizing flag as proof that the following asynchronous write has finished.
    @ObservationIgnored let coldCacheSave:
        @Sendable (_ tree: FileTree, _ lastEventId: UInt64) throws -> Void

    /// A warm patch mutates the displayed cached tree in place. A superseding scan uses
    /// this bit to detach that tree synchronously before the old scanner can commit after
    /// cancellation and leave newly-renumbered nodes under stale index-keyed UI state.
    @ObservationIgnored var warmPatchMutatesDisplayedTree = false

    /// True only from immediately before a warm patch's transactional compaction until
    /// AppState runs the matching canonical invalidation. Phase A remains interactive;
    /// this closes the otherwise unsafe window where an old-layout click could be
    /// interpreted against newly-renumbered nodes.
    public internal(set) var isWarmPatchCommitInProgress = false
    @ObservationIgnored var isRejectingWarmPatchSelection = false

    /// Path-keyed position kept current while the trailing tier runs. The interactive tree
    /// remains browsable during that pass, so a capture taken only at tier start would
    /// rewind any selection or drill-down made before the second splice.
    @ObservationIgnored var warmPatchExploration: ExplorationCapture?
    @ObservationIgnored var warmPatchExplorationToken: UInt64?

    /// Per-volume, path-keyed exploration session (selection, treemap root, expansion)
    /// persisted across launches - plan 038. Restored by `restoreOnLaunch()`; saved by
    /// `saveSelectionAndRootSession()`/`saveExpandedPathsSession(_:)` (`AppState+Scan.swift`)
    /// and read/written directly by `TreeTableView` for its view-local expansion state.
    /// Shares `defaults` with `lastScannedVolumePath` so injecting one isolated suite in
    /// tests isolates both.
    @ObservationIgnored let sessionStore: SessionStateStore

    public init(
        defaults: UserDefaults = .standard,
        ephemeralPaths: EphemeralPaths = .current(),
        warmPatchScannerFactory: @escaping @Sendable () -> FileScanner = { FileScanner() },
        warmStartJournalReplay: @escaping @Sendable (
            _ root: String,
            _ sinceEventId: UInt64
        ) async -> JournalReplay = { root, eventId in
            await FSEventsJournal.replay(root: root, since: eventId)
        },
        coldCacheSave: @escaping @Sendable (
            _ tree: FileTree,
            _ lastEventId: UInt64
        ) throws -> Void = { tree, eventId in
            try TreeCache.save(tree: tree, lastEventId: eventId)
        }
    ) {
        self.defaults = defaults
        self.sessionStore = SessionStateStore(defaults: defaults)
        self.ephemeralPaths = ephemeralPaths
        self.warmPatchScannerFactory = warmPatchScannerFactory
        self.warmStartJournalReplay = warmStartJournalReplay
        self.coldCacheSave = coldCacheSave
        // Read persisted preferences from the INJECTED store. Doing this here rather than
        // in a property default is what keeps an isolated test suite from writing into the
        // user's real defaults domain (it did, once).
        self.treemapRenderStyle = AppState.loadRenderStyle(defaults)
        self.foldersColorScheme = AppState.loadFoldersColorScheme(defaults)
        self.foldersSurfaceStyle = AppState.loadFoldersSurfaceStyle(defaults)
        self.isTreemapPaneCollapsed = defaults.bool(forKey: AppState.treemapCollapsedKey)
        self.liveRefreshPaused = defaults.bool(forKey: AppState.livePausedKey)
        self.showsMenuBarItem = defaults.object(forKey: AppState.showsMenuBarItemKey) == nil
            ? true : defaults.bool(forKey: AppState.showsMenuBarItemKey)
        self.keepsRunningInMenuBar = defaults.object(forKey: AppState.keepsRunningInMenuBarKey) == nil
            ? true : defaults.bool(forKey: AppState.keepsRunningInMenuBarKey)
        self.showsFreeSpaceInMenuBar = defaults.bool(forKey: AppState.showsFreeSpaceInMenuBarKey)
        self.lowSpaceNotificationsEnabled = defaults.bool(forKey: AppState.lowSpaceNotificationsEnabledKey)
        let threshold = defaults.double(forKey: AppState.lowSpaceThresholdPercentKey)
        self.lowSpaceThresholdPercent = threshold > 0 ? threshold : 10
        self.growthNotificationsEnabled = defaults.bool(forKey: AppState.growthNotificationsEnabledKey)
        let growthThreshold = defaults.double(forKey: AppState.growthNotificationThresholdGiBKey)
        self.growthNotificationThresholdGiB = growthThreshold > 0 ? growthThreshold : 10
        self.recentVolumePaths = defaults.stringArray(forKey: AppState.recentVolumePathsKey) ?? []
        self.lowSpacePolicyStates = AppState.loadLowSpacePolicyStates(defaults)
        self.isLoadingMenuBarPreferences = false
        if self.keepsRunningInMenuBar, !self.showsMenuBarItem {
            self.showsMenuBarItem = true
        }
    }

    public enum HeavyTaskKind: String, Sendable, CaseIterable {
        case duplicateScan
        case hardlinkScan
        case spaceAnalysis
        case iCloudAnalysis
        case apfsQuery
        case cloneCheck
        case bundleSizing
        case applyChanges

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
            case .applyChanges:
                return "Applying filesystem changes"
            }
        }

        /// Single source of truth mapping each case to its running flag on `AppState`.
        @MainActor
        func isRunning(in state: AppState) -> Bool {
            switch self {
            case .duplicateScan: return state.duplicate.isDuplicateScanRunning
            case .hardlinkScan: return state.hardlink.isHardlinkScanRunning
            case .spaceAnalysis: return state.isSpaceAnalysisRunning
            case .iCloudAnalysis: return state.isICloudAnalysisRunning
            case .apfsQuery: return state.isAPFSQueryRunning
            case .cloneCheck: return state.isCloneCheckRunning
            case .bundleSizing: return state.isBundleSizingRunning
            case .applyChanges: return state.isApplyingChanges
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
        resetTreeDerivedState()
        scanSession.invalidate()
        scanSession.resetTiming()
        // Create a fresh ScanProgress so old scanner finalizations write to the
        // abandoned instance and cannot corrupt the new scan's counters.
        scanProgress = ScanProgress()
        lastScanSummary = nil
    }

    /// Clears every piece of state derived from the PREVIOUS tree's contents - index-keyed
    /// overlays (search, recency, temporal diff), per-run analysis results, extension
    /// stats - so a freshly assigned `fileTree` starts from a clean slate. Deliberately
    /// does NOT touch `scanSession`/`scanProgress`/`lastScanSummary`: those track the scan
    /// itself rather than the tree's content, and the cold-refresh-behind-stale completion
    /// swap (`AppState+Scan.swift`) needs to keep tracking its already-in-flight scan across
    /// this reset rather than have it clobbered mid-flight. Shared by `resetForNewScan()`
    /// (called at the START of an ordinary scan, before anything is displayed) and that
    /// swap (called once the background scan is done, so the previously-displayed stale
    /// tree isn't disturbed while it runs).
    func resetTreeDerivedState() {
        navigation.reset()
        search.reset()
        duplicate.reset()
        temporalDiff.reset()
        hardlink.reset()
        hardlinkToken &+= 1
        selectedNodeIndex = nil
        fileTypeStats = []
        // Keep the palette's mutation counter monotonic across consecutive scans. Replacing the
        // value restarted generation at zero; the next assignment returned to generation 1, which
        // could collide with the previous tree and leave its color mapping in the renderer.
        extensionPalette.assign(from: [])
        recencyFactors = []
        recencyGeneration = 0
        isRecencyOverlayEnabled = false
        isRecencyQueryRunning = false
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
        storageTrendHistory = []
        fsEventsMonitor?.stop()
        fsEventsMonitor = nil
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        lastLiveChangeAt = nil
        liveRefreshDecision = .idle
        fsChanges = []
        isFSMonitoringActive = false
        isApplyingChanges = false
    }
}

// MARK: - Supporting Types

extension AppState {
    /// The single drill-down seam shared by the Extensions tab and the sidebar legend.
    ///
    /// It lived as a closure inside ContentView, which put it in the app executable where
    /// the test target cannot reach it - and meant the legend could not reuse it without
    /// copying. Both surfaces now call this, so "clicking a file type" means one thing.
    public func drillDownToExtension(hash: UInt32, displayName: String) {
        // "Other" aggregates many extensions, so there is no single filter to apply.
        // Send the user to the full table instead of a search that cannot be expressed.
        guard hash != ExtensionRowModel.otherID else {
            // "Other" aggregates many extensions, so no single filter expresses it -
            // show the full table instead of a search that is guaranteed empty.
            showAllFileTypes = true
            return
        }
        search.extensionFilter = hash
        search.extensionFilterName = displayName
        // A stale query would silently AND with the new filter and look like "no results".
        search.searchQuery = ""
        activeTab = .search
    }
}

extension AppState {
    /// "Search in this folder": scope search to a subtree and go there.
    ///
    /// Stores the PATH, not the node index - `removeSubtree` renumbers every index, so a
    /// stored index would silently come to mean a different folder after any trash action.
    /// `SearchView` re-resolves the path before each query.
    public func scopeSearch(toPath path: String, name: String) {
        search.setScope(path: path, name: name)
        activeTab = .search
    }
}

public enum DetailTab: String, CaseIterable, Identifiable {
    case treeView = "Tree View"
    case duplicates = "Duplicates"
    case hardlinks = "Hardlinks"
    case search = "Search"
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
