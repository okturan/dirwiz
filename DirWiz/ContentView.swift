import SwiftUI
import AppKit
import DirWizCore
import DirWizUI

/// Root view with NavigationSplitView layout.
struct ContentView: View {
    @Bindable var appState: AppState

    @State private var showLegend: Bool = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var splitRatio: CGFloat = 0.4
    @State private var exportAlertTitle: String = ""
    @State private var exportAlertMessage: String = ""
    @State private var showExportAlert: Bool = false
    @State private var showSkippedDirsPopover: Bool = false
    @State private var showSkippedMountsPopover: Bool = false
    @State private var showWarmStartHistoryPopover: Bool = false

    @State private var showPinSheet = false
    @State private var pinName = ""

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
            } detail: {
                detailContent
            }
            .navigationTitle("")
            .sheet(isPresented: $showPinSheet) { pinSheet }
            .sheet(isPresented: $appState.showAllFileTypes) {
                VStack(spacing: 0) {
                    HStack {
                        Text("All file types").font(.headline)
                        Spacer()
                        Button("Done") { appState.showAllFileTypes = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                    Divider()
                    ExtensionListView(
                        fileTypeStats: appState.fileTypeStats,
                        totalSize: appState.fileTree?.rootDisplaySize ?? 0,
                        extensionPalette: appState.extensionPalette,
                        onDrillDown: { stat in
                            let model = ExtensionRowModel(
                                id: stat.extensionHash, rawName: stat.extensionName,
                                color: .zero, totalSize: 0, fileCount: 0)
                            appState.showAllFileTypes = false
                            appState.drillDownToExtension(
                                hash: model.id, displayName: model.displayName)
                        }
                    )
                }
                .frame(width: 720, height: 560)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 6) {
                        // Recency heatmap spinner + toggle
                        if appState.isRecencyQueryRunning {
                            ProgressView()
                                .controlSize(.small)
                                .help("Querying Spotlight for file recency…")
                        }
                        Toggle(isOn: Binding(
                            get: { appState.isRecencyOverlayEnabled },
                            set: { enabled in
                                appState.isRecencyOverlayEnabled = enabled
                                if enabled { appState.startRecencyQueryIfNeeded() }
                            }
                        )) {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .help("Recency Heatmap - dim files unused for 2+ years (Cmd+Opt+R)")
                        .keyboardShortcut("r", modifiers: [.command, .option])
                        .disabled(!appState.scanProgress.scanComplete)

                        Divider().frame(height: 16)

                        // Take Snapshot
                        if appState.temporalDiff.isSnapshotBuilding {
                            ProgressView()
                                .controlSize(.small)
                                .help("Saving snapshot…")
                        } else {
                            Button {
                                pinName = ""
                                showPinSheet = true
                            } label: {
                                Image(systemName: "camera")
                            }
                            .help("Pin this moment on the timeline (Cmd+Opt+S)")
                            .keyboardShortcut("s", modifiers: [.command, .option])
                            .disabled(!appState.scanProgress.scanComplete)
                        }

                        // Temporal Diff toggle
                        Toggle(isOn: Binding(
                            get: { appState.temporalDiff.isTemporalDiffEnabled },
                            set: { enabled in
                                appState.temporalDiff.isTemporalDiffEnabled = enabled
                                if enabled { appState.startTemporalDiff() }
                            }
                        )) {
                            Image(systemName: "timelapse")
                        }
                        .help("Temporal Diff - highlight changes since snapshot (Cmd+Opt+D)")
                        .keyboardShortcut("d", modifiers: [.command, .option])
                        .disabled(
                            !appState.scanProgress.scanComplete
                                || appState.temporalDiff.temporalSnapshot == nil
                                || appState.temporalDiff.temporalSnapshot?.meta.rootPath != appState.fileTree?.path(at: 0)
                        )
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Export CSV...") { exportReport() }
                            .keyboardShortcut("e", modifiers: [.command, .option])
                        Button("Export JSON...") { exportJSON() }
                            .keyboardShortcut("j", modifiers: [.command, .option])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export Report (Cmd+Opt+E)")
                    .disabled(
                        appState.fileTree == nil
                            || appState.isWarmPatchCommitInProgress
                    )
                }
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $showLegend) {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help("Toggle Legend (Cmd+Opt+L)")
                    .keyboardShortcut("l", modifiers: [.command, .option])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchRequested)) { _ in
                appState.activeTab = .search
            }
            .alert(exportAlertTitle, isPresented: $showExportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportAlertMessage)
            }

            Divider()

            footerBar
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VolumePickerView(appState: appState, onScan: startScan, onFullRescan: startFullRescan)

            if !appState.hasFullDiskAccess {
                fullDiskAccessBanner
            }

            if appState.scanProgress.isScanning {
                ScanProgressView(scanProgress: appState.scanProgress, onCancel: cancelScan)
            }

            Spacer()

            if let badge = appState.staleBadgeText {
                staleBadge(text: badge)
            } else if appState.scanProgress.scanComplete {
                scanSummary
            } else if let summary = appState.lastScanSummary {
                // warm-start-observability: `restoreOnLaunch`'s cache-rejected-at-launch
                // path sets `lastScanSummary` without ever running a scan (nothing
                // completed, so `scanComplete` stays false and the branch above never
                // fires) - without this branch, that summary would be set but literally
                // never shown anywhere.
                launchNoticeSummary(text: summary)
            }
        }
        .onAppear { appState.hasFullDiskAccess = checkFullDiskAccess() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Re-check when the user returns from System Settings after granting FDA.
            appState.hasFullDiskAccess = checkFullDiskAccess()
        }
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access not granted")
                    .font(.system(size: 11, weight: .medium))
                // The skipped count folds in here rather than as a second warning line in
                // the scan summary - one alarm, one action (skipped-dirs-honesty).
                Text(fdaBannerDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.3)), alignment: .bottom)
    }

    private var fdaBannerDetail: String {
        let skipped = appState.scanProgress.skippedDirectories
        guard skipped > 0 else { return "Results will be incomplete" }
        return "Results will be incomplete - \(skipped) folder\(skipped == 1 ? "" : "s") couldn't be read"
    }

    private var scanSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                if appState.scanProgress.isCancelled {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Scan Cancelled")
                        .font(.callout.bold())
                } else if appState.scanProgress.error != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Scan Error")
                        .font(.callout.bold())
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(appState.isBundleSizingRunning ? "Sizing Bundles" : "Scan Complete")
                        .font(.callout.bold())
                }
            }
            if let summary = appState.lastScanSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.isFSMonitoringActive || !appState.fsChanges.isEmpty {
                livePill
            }
            if let tree = appState.fileTree {
                Text("\(SizeFormatter.shared.formatCount(tree.count)) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SizeFormatter.shared.format(tree.rootDisplaySize))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // Skipped-dirs line: only the quiet (FDA-granted) style renders here. The
            // FDA-missing case folds into `fullDiskAccessBanner` above - one alarm, one
            // action - instead of a second independent warning (skipped-dirs-honesty).
            if SkippedDirsPresentation.style(
                fdaGranted: appState.hasFullDiskAccess,
                skippedCount: appState.scanProgress.skippedDirectories
            ) == .quietInfo {
                skippedDirsQuietLine
            }
            if appState.scanProgress.skippedMounts > 0 {
                skippedMountsQuietLine
            }
            warmStartHistoryLine
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// warm-start-observability: shown in place of `scanSummary` when `restoreOnLaunch`
    /// discovered a rejected cache without ever running a scan - `lastScanSummary` is set
    /// but `scanProgress.scanComplete` never flips true (nothing completed), so the full
    /// `scanSummary` block (which assumes a finished scan: elapsed time, item counts)
    /// would be dishonest here. Deliberately minimal: just the explanation, plus the same
    /// history affordance every other state-summary view offers.
    private func launchNoticeSummary(text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            warmStartHistoryLine
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// warm-start-observability: quiet, always-available affordance for "why has this
    /// been cold-scanning lately" - reuses the skipped-dirs-honesty popover pattern.
    /// Shown whenever a volume is selected; the popover itself handles the
    /// empty-history case.
    @ViewBuilder
    private var warmStartHistoryLine: some View {
        if let identity = appState.selectedScanPersistenceIdentity {
            Button {
                showWarmStartHistoryPopover.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.caption2)
                    Text("Scan history")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showWarmStartHistoryPopover, arrowEdge: .trailing) {
                warmStartHistoryPopover(identity: identity)
            }
        }
    }

    private func warmStartHistoryPopover(identity: String) -> some View {
        let entries = WarmStartHistory.load(for: identity).reversed()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recent Scan Decisions")
                .font(.system(size: 12, weight: .semibold))
            Text("Whether each recent scan of this volume ran instantly (warm) or from scratch (cold), and why.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if entries.isEmpty {
                Text("No scan history yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            warmStartHistoryRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func warmStartHistoryRow(_ entry: WarmStartHistory.Entry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: entry.wasWarm ? "bolt.fill" : "arrow.clockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(entry.wasWarm ? .blue : .secondary)
                Text(entry.wasWarm ? "Warm" : "Cold")
                    .font(.system(size: 11, weight: .medium))
                Text(Self.historyDateFormatter.string(from: entry.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let reason = entry.reason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let historyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// The FDA-granted skipped-dirs presentation: these locations are SIP-protected and
    /// unfixable, so the line is informational (secondary styling, no orange) and opens
    /// an explainer popover listing the recorded paths.
    private var skippedDirsQuietLine: some View {
        let count = appState.scanProgress.skippedDirectories
        return Button {
            showSkippedDirsPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("\(count) system-protected folder\(count == 1 ? "" : "s") skipped")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSkippedDirsPopover, arrowEdge: .trailing) {
            skippedDirsPopover
        }
    }

    private var skippedDirsPopover: some View {
        let paths = appState.scanProgress.skippedDirectoryPaths
        let count = appState.scanProgress.skippedDirectories
        return VStack(alignment: .leading, spacing: 8) {
            Text("System-Protected Folders")
                .font(.system(size: 12, weight: .semibold))
            Text("macOS protects these locations even from apps with Full Disk Access. Every disk utility skips them; their contents are not included in totals.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(paths, id: \.self) { path in
                        Text(abbreviateHomePath(path))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if count > paths.count {
                        Text("… and \(count - paths.count) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 420)
    }

    /// Mount boundaries are an intentional scan-scope choice, not a permission failure.
    /// Keep their explanation separate from the FDA/SIP presentation above.
    private var skippedMountsQuietLine: some View {
        let count = appState.scanProgress.skippedMounts
        return Button {
            showSkippedMountsPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "externaldrive.badge.minus")
                    .font(.caption2)
                Text("\(count) mounted filesystem\(count == 1 ? "" : "s") kept separate")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSkippedMountsPopover, arrowEdge: .trailing) {
            skippedMountsPopover
        }
    }

    private var skippedMountsPopover: some View {
        let paths = appState.scanProgress.skippedMountPaths
        let count = appState.scanProgress.skippedMounts
        return VStack(alignment: .leading, spacing: 8) {
            Text("Mounted Filesystems Kept Separate")
                .font(.system(size: 12, weight: .semibold))
            Text("This scan contains only the selected volume. Mounted drives and disk images do not contribute to its totals.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.availableVolumes.count > 1 {
                Text("Choose All Volumes in the sidebar to build one combined map.")
                    .font(.system(size: 11, weight: .medium))
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(paths, id: \.self) { path in
                        Text(abbreviateHomePath(path))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if count > paths.count {
                        Text("… and \(count - paths.count) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 420)
    }

    private func abbreviateHomePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Shown in place of `scanSummary` while a restored cache is on screen and not yet
    /// freshened - the tree/treemap below stay fully interactive the whole time (see the
    /// `isScanning && staleViewAsOf == nil` gate on `detailContent`).
    private func staleBadge(text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            warmStartHistoryLine
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// Live "N folders changed · Refresh" row shown inside `scanSummary` once
    /// Living-view status. Monitoring auto-starts after every completed scan and
    /// accumulated changes splice themselves in once `LiveRefreshPolicy` says so - this
    /// pill exists to make that visible and reversible, not to be the trigger.
    ///
    /// This replaces the old "N folders changed · Refresh" badge and reverses plan 037's
    /// decision 3a. Every state names its own reason: a view that quietly stops updating is
    /// worse than one that never updated, because you cannot tell the difference.
    private var livePill: some View {
        HStack(spacing: 6) {
            Image(systemName: liveIcon)
                .font(.caption)
                .foregroundStyle(liveTint)
            Text(appState.livingViewStatus())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if appState.isApplyingChanges {
                ProgressView().controlSize(.small)
            } else if case .storm = appState.liveRefreshDecision {
                // Splicing this many directories is slower than rescanning outright.
                Button("Full Rescan") { appState.startFullRescan() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else if appState.liveRefreshPaused && !appState.fsChanges.isEmpty {
                Button("Apply") {
                    Task { await appState.applyAccumulatedChanges() }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!appState.canStartHeavyTask(.applyChanges))
            }

            Button(action: { appState.toggleLiveRefreshPaused() }) {
                Image(systemName: appState.liveRefreshPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(appState.liveRefreshPaused
                  ? "Resume automatic updates"
                  : "Pause automatic updates (keeps watching)")
        }
    }

    private var liveIcon: String {
        if appState.liveRefreshPaused { return "pause.circle" }
        switch appState.liveRefreshDecision {
        case .storm:    return "exclamationmark.triangle"
        case .deferred: return "clock"
        default:        return "circle.fill"
        }
    }

    private var liveTint: Color {
        if appState.liveRefreshPaused { return .secondary }
        switch appState.liveRefreshDecision {
        case .storm:    return .orange
        case .deferred: return .secondary
        default:        return .green
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            // Left: full path of the selected node
            if let idx = appState.selectedNodeIndex,
               let tree = appState.fileTree {
                let path = tree.path(at: idx)
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            // Right: scan duration and item count
            if appState.scanDuration > 0 {
                Text(String(format: "Scanned in %.1fs", appState.scanDuration))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let tree = appState.fileTree {
                Text("\(SizeFormatter.shared.formatCount(tree.count)) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.bar)
    }

    // MARK: - Detail

    private var detailContent: some View {
        GeometryReader { detailGeo in
            let legendVisible = showLegend && detailGeo.size.width >= 740
            HStack(spacing: 0) {
            // Main content area with resizable split.
            VStack(spacing: 0) {
                tabBar
                Divider()

                GeometryReader { geo in
                    let dividerHeight: CGFloat = 6
                    let collapsed = appState.isTreemapPaneCollapsed
                    let bannerHeight: CGFloat = (appState.temporalDiff.isTemporalDiffEnabled
                        && appState.temporalDiff.temporalSnapshot != nil) ? 28 : 0
                    // Product-UI craft: never let a fixed treemap floor steal the table on
                    // short windows. Share height by ratio, clamp both panes, and assign
                    // EXPLICIT heights (no competing minHeight that overflows the reader).
                    let available = max(0, geo.size.height - dividerHeight - bannerHeight)
                    let minTop = min(140, max(88, available * 0.32))
                    let minBottom = collapsed ? 0 : min(96, max(56, available * 0.28))
                    let maxTop = collapsed
                        ? available
                        : max(minTop, available - minBottom)
                    let requestedTop = available * splitRatio
                    let topHeight = collapsed
                        ? available
                        : min(max(minTop, requestedTop), maxTop)
                    let bottomHeight = collapsed ? 0 : max(0, available - topHeight)

                    VStack(spacing: 0) {
                        // Top: table or scanning placeholder.
                        Group {
                            // A restored stale view has real content to show even while
                            // the background refresh runs - only the ordinary empty-start
                            // scan (no `staleViewAsOf`) blanks the pane for the placeholder.
                            if appState.scanProgress.isScanning && appState.staleViewAsOf == nil {
                                scanningPlaceholder
                            } else {
                                switch appState.activeTab {
                                case .treeView:
                                    TreeTableView(appState: appState)
                                case .duplicates:
                                    DuplicateFilesView(appState: appState)
                                case .hardlinks:
                                    HardlinkView(appState: appState)
                                case .search:
                                    SearchView(appState: appState)
                                case .insights:
                                    InsightsView(appState: appState)
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: topHeight, alignment: .top)
                        .clipped()

                        // Resizable drag divider; doubles as the collapse/restore control.
                        splitDivider(totalHeight: geo.size.height)

                        // Kept visible while collapsed: the Clear button - and the fact
                        // that a diff overlay is active at all - must never be unreachable
                        // just because the map it paints is hidden.
                        if appState.temporalDiff.isTemporalDiffEnabled,
                           let snap = appState.temporalDiff.temporalSnapshot {
                            diffStatusBanner(snapshot: snap)
                                .frame(height: bannerHeight)
                        }

                        // Bottom: treemap. Removed from the hierarchy entirely while
                        // collapsed - the renderer relayouts on reappearance through its
                        // normal change detection, so nothing special is needed here.
                        if !collapsed {
                            InteractiveTreemapView(appState: appState)
                                .frame(width: geo.size.width, height: bottomHeight)
                                .clipped()
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
                    .coordinateSpace(name: "splitView")
                }
            }

            // Right sidebar: legend.
            if legendVisible {
                Divider()
                ExtensionLegend(
                    palette: appState.extensionPalette,
                    totalSize: appState.fileTree?.rootDisplaySize ?? 0,
                    renderStyle: appState.treemapRenderStyle,
                    foldersColorScheme: appState.foldersColorScheme,
                    onSelect: { model in
                        appState.drillDownToExtension(hash: model.id, displayName: model.displayName)
                    },
                    onSeeAll: { appState.showAllFileTypes = true }
                )
                .frame(width: 220)
            }
        }
        // FileScanner swaps the flat node array transactionally, then AppState clears
        // and remaps every index-keyed consumer in the same MainActor turn after the
        // scanner returns. Suppress the brief commit-to-invalidation interaction window
        // across the whole detail surface: an old row/search/treemap index must never be
        // resolved against the newly-renumbered tree (especially by destructive menus).
        .disabled(appState.isWarmPatchCommitInProgress)
        .allowsHitTesting(!appState.isWarmPatchCommitInProgress)
        }
    }

    // MARK: - Split Divider

    private func splitDivider(totalHeight: CGFloat) -> some View {
        let collapsed = appState.isTreemapPaneCollapsed
        return Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                // No resize cursor while collapsed: there is nothing to resize, and the
                // cursor would promise a drag that does nothing.
                guard !collapsed else { return }
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .named("splitView"))
                    .onChanged { value in
                        guard !collapsed else { return }
                        let newRatio = value.location.y / totalHeight
                        let clamped = max(0.1, min(0.85, newRatio))
                        // Quantize to ~0.5% so SwiftUI is not forced to relayout on every
                        // mouse pixel - the map stretch-previews; the table does not need
                        // sub-pixel pane updates at 120Hz.
                        let quantized = (clamped * 200).rounded() / 200
                        guard abs(quantized - splitRatio) >= 0.005 else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            splitRatio = quantized
                        }
                    }
            )
            .onTapGesture(count: 2) { toggleTreemapPane() }
            .overlay(
                Button(action: toggleTreemapPane) {
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 14)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show treemap" : "Hide treemap (double-click the divider also toggles)")
            )
    }

    /// Collapse keeps `splitRatio` untouched, so restoring returns to the layout the user
    /// had tuned rather than to a default.
    private func toggleTreemapPane() {
        withAnimation(.easeInOut(duration: 0.15)) {
            appState.isTreemapPaneCollapsed.toggle()
        }
    }

    private static let diffDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func diffStatusBanner(snapshot: TemporalSnapshot) -> some View {
        let dateStr = Self.diffDateFormatter.string(from: snapshot.meta.createdAt)
        return HStack(spacing: 6) {
            Image(systemName: "timelapse")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("Comparing to")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            checkpointPicker(current: snapshot, currentLabel: dateStr)

            Text("·")
                .foregroundStyle(.tertiary)
            Text(snapshot.meta.rootPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Clear") {
                appState.temporalDiff.isTemporalDiffEnabled = false
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.08))
    }

    /// Naming a moment is what pins it: retention never thins a named checkpoint, so the
    /// sheet is the difference between "a point that may be thinned away" and "a point that
    /// will still be here next year".
    private var pinSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pin this moment")
                .font(.headline)
            Text("Named checkpoints are kept forever. Unnamed ones are thinned over time.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("e.g. Before cleaning Downloads", text: $pinName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack {
                Button("Cancel") { showPinSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Unnamed") {
                    showPinSheet = false
                    appState.takeSnapshot()
                }
                Button("Pin") {
                    let name = pinName.trimmingCharacters(in: .whitespacesAndNewlines)
                    showPinSheet = false
                    // An all-whitespace name is not a name; treat it as an ordinary
                    // checkpoint rather than pinning something the user cannot identify.
                    appState.takeSnapshot(name: name.isEmpty ? nil : name)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    /// Choose which recorded checkpoint the diff overlay compares against.
    ///
    /// Newest first, with each entry's own delta so the list reads as a timeline rather than
    /// a pile of dates. The footer shows what the history costs on disk - keeping history
    /// silently consuming space is exactly the thing this app exists to expose.
    private func checkpointPicker(current: TemporalSnapshot, currentLabel: String) -> some View {
        let checkpoints = appState.temporalDiff.availableCheckpoints
        return Menu {
            if checkpoints.isEmpty {
                Text("No other checkpoints recorded")
            } else {
                ForEach(checkpoints) { checkpoint in
                    Button {
                        appState.selectDiffBaseline(checkpoint)
                    } label: {
                        let isCurrent = checkpoint.id == current.meta.id
                        Text((isCurrent ? "✓ " : "")
                             + (checkpoint.isPinned ? "★ " : "")
                             + checkpointLabel(checkpoint))
                    }
                }
                Divider()
                Text("\(checkpoints.count) checkpoints · "
                     + SizeFormatter.shared.format(appState.temporalDiff.storeBytes) + " on disk")
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentLabel)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear { appState.refreshCheckpointList() }
        .help("Compare against a different recorded checkpoint")
    }

    private func checkpointLabel(_ checkpoint: SnapshotCheckpoint) -> String {
        var parts = [Self.diffDateFormatter.string(from: checkpoint.createdAt)]
        if let name = checkpoint.name { parts.append(name) }
        if let summary = checkpoint.summary, summary.totalDelta != 0 {
            let sign = summary.totalDelta > 0 ? "+" : "−"
            parts.append(sign + SizeFormatter.shared.format(UInt64(abs(summary.totalDelta))))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                Button(action: { appState.activeTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: appState.activeTab == tab ? .semibold : .regular))
                        // Without this a narrow window wraps "Extensions" to "Extension/s".
                        // The bar scrolls instead; a tab name must never break mid-word.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(
                            appState.activeTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Scanning Placeholder

    private var scanningPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning filesystem...")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(SizeFormatter.shared.formatCount(appState.scanProgress.totalItems)) items found")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Actions

    private func startScan() {
        appState.startSelectedVolumeScan()
    }

    private func startFullRescan() {
        appState.startFullRescan()
    }

    private func cancelScan() {
        appState.cancelScan()
    }

    // MARK: - Export Report

    private func exportReport() {
        guard !appState.isWarmPatchCommitInProgress,
              let tree = appState.fileTree else { return }

        let panel = NSSavePanel()
        panel.title = "Export Report"
        panel.nameFieldStringValue = "DirWiz Report.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let rootIndex = appState.navigation.treemapRootIndex
        let csv = CSVExporter().export(tree: tree, rootIndex: rootIndex)

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportAlertTitle = "Export Successful"
            exportAlertMessage = "Report saved to \(url.lastPathComponent)."
        } catch {
            exportAlertTitle = "Export Failed"
            exportAlertMessage = error.localizedDescription
        }
        showExportAlert = true
    }

    // MARK: - JSON Export

    private func exportJSON() {
        guard !appState.isWarmPatchCommitInProgress,
              appState.fileTree != nil else { return }

        let panel = NSSavePanel()
        panel.title = "Export JSON Report"
        panel.nameFieldStringValue = "DirWiz Report.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await appState.exportJSON(to: url)
                await MainActor.run {
                    exportAlertTitle = "Export Successful"
                    exportAlertMessage = "JSON report saved to \(url.lastPathComponent)."
                    showExportAlert = true
                }
            } catch {
                await MainActor.run {
                    exportAlertTitle = "Export Failed"
                    exportAlertMessage = error.localizedDescription
                    showExportAlert = true
                }
            }
        }
    }
}
