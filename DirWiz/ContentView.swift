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
    @State private var showWarmStartHistoryPopover: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
            } detail: {
                detailContent
            }
            .navigationTitle("")
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
                        .help("Recency Heatmap — dim files unused for 2+ years (Cmd+Opt+R)")
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
                                appState.takeSnapshot()
                            } label: {
                                Image(systemName: "camera")
                            }
                            .help("Take Snapshot for Temporal Diff (Cmd+Opt+S)")
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
                        .help("Temporal Diff — highlight changes since snapshot (Cmd+Opt+D)")
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
                    .disabled(appState.fileTree == nil)
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
                // fires) — without this branch, that summary would be set but literally
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
                // the scan summary — one alarm, one action (skipped-dirs-honesty).
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
        return "Results will be incomplete — \(skipped) folder\(skipped == 1 ? "" : "s") couldn't be read"
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
            Text(String(format: "%.1fs elapsed", appState.scanProgress.elapsedTime))
                .font(.caption)
                .foregroundStyle(.secondary)
            // Skipped-dirs line: only the quiet (FDA-granted) style renders here. The
            // FDA-missing case folds into `fullDiskAccessBanner` above — one alarm, one
            // action — instead of a second independent warning (skipped-dirs-honesty).
            if SkippedDirsPresentation.style(
                fdaGranted: appState.hasFullDiskAccess,
                skippedCount: appState.scanProgress.skippedDirectories
            ) == .quietInfo {
                skippedDirsQuietLine
            }
            warmStartHistoryLine
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// warm-start-observability: shown in place of `scanSummary` when `restoreOnLaunch`
    /// discovered a rejected cache without ever running a scan — `lastScanSummary` is set
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
    /// been cold-scanning lately" — reuses the skipped-dirs-honesty popover pattern.
    /// Shown whenever a volume is selected; the popover itself handles the
    /// empty-history case.
    @ViewBuilder
    private var warmStartHistoryLine: some View {
        if let path = appState.selectedVolume?.path {
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
                warmStartHistoryPopover(path: path)
            }
        }
    }

    private func warmStartHistoryPopover(path: String) -> some View {
        let entries = WarmStartHistory.load(for: path).reversed()
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

    private func abbreviateHomePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Shown in place of `scanSummary` while a restored cache is on screen and not yet
    /// freshened — the tree/treemap below stay fully interactive the whole time (see the
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
    /// accumulated changes splice themselves in once `LiveRefreshPolicy` says so — this
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
            Text(liveLabel)
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

    private var liveLabel: String {
        let pending = appState.fsChanges.count
        if appState.liveRefreshPaused {
            return pending > 0
                ? "Paused · \(pending) folders pending"
                : "Paused"
        }
        switch appState.liveRefreshDecision {
        case .storm(let count):
            return "\(SizeFormatter.shared.formatCount(count)) folders changed — too many to patch"
        case .deferred(let reason):
            switch reason {
            case .temporalDiffActive: return "\(pending) pending · waiting for the diff overlay"
            case .scanning:           return "\(pending) pending · scanning"
            case .heavyTaskRunning:   return "\(pending) pending · waiting for analysis"
            case .paused:             return "Paused"
            }
        case .waitingForQuiescence, .waitingForInterval:
            return "\(pending) folders changed · updating shortly"
        case .apply:
            return "\(pending) folders changed · updating"
        case .idle:
            if let last = appState.lastLiveApplyAt {
                let ago = Int(CFAbsoluteTimeGetCurrent() - last)
                return ago < 5 ? "Live · just updated" : "Live · updated \(ago)s ago"
            }
            return "Live"
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
        HStack(spacing: 0) {
            // Main content area with resizable split.
            VStack(spacing: 0) {
                tabBar
                Divider()

                GeometryReader { geo in
                    VStack(spacing: 0) {
                        // Top: table or scanning placeholder.
                        Group {
                            // A restored stale view has real content to show even while
                            // the background refresh runs — only the ordinary empty-start
                            // scan (no `staleViewAsOf`) blanks the pane for the placeholder.
                            if appState.scanProgress.isScanning && appState.staleViewAsOf == nil {
                                scanningPlaceholder
                            } else {
                                switch appState.activeTab {
                                case .treeView:
                                    TreeTableView(appState: appState)
                                case .extensions:
                                    ExtensionListView(
                                        fileTypeStats: appState.fileTypeStats,
                                        totalSize: appState.fileTree?.rootDisplaySize ?? 0,
                                        extensionPalette: appState.extensionPalette,
                                        onDrillDown: { stat in
                                            let model = ExtensionRowModel(
                                                id: stat.extensionHash,
                                                rawName: stat.extensionName,
                                                color: .zero, totalSize: 0, fileCount: 0
                                            )
                                            appState.drillDownToExtension(
                                                hash: model.id, displayName: model.displayName
                                            )
                                        }
                                    )
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
                        .frame(height: max(60, geo.size.height * splitRatio))
                        .clipped()

                        // Resizable drag divider.
                        splitDivider(totalHeight: geo.size.height)

                        // Temporal diff status banner.
                        if appState.temporalDiff.isTemporalDiffEnabled,
                           let snap = appState.temporalDiff.temporalSnapshot {
                            diffStatusBanner(snapshot: snap)
                        }

                        // Bottom: treemap.
                        InteractiveTreemapView(appState: appState)
                            .frame(minHeight: 100)
                    }
                    .coordinateSpace(name: "splitView")
                }
            }

            // Right sidebar: legend.
            if showLegend {
                Divider()
                ExtensionLegend(
                    palette: appState.extensionPalette,
                    totalSize: appState.fileTree?.rootDisplaySize ?? 0,
                    onSelect: { model in
                        appState.drillDownToExtension(hash: model.id, displayName: model.displayName)
                    },
                    onSeeAll: { appState.activeTab = .extensions }
                )
                .frame(width: 220)
            }
        }
    }

    // MARK: - Split Divider

    private func splitDivider(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .named("splitView"))
                    .onChanged { value in
                        let newRatio = value.location.y / totalHeight
                        splitRatio = max(0.1, min(0.85, newRatio))
                    }
            )
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
            Text("Comparing to snapshot from \(dateStr)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(snapshot.meta.rootPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
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

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases) { tab in
                Button(action: { appState.activeTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: appState.activeTab == tab ? .semibold : .regular))
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
        guard let tree = appState.fileTree else { return }

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
        guard appState.fileTree != nil else { return }

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
