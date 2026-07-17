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
                Text("Results will be incomplete")
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
            if !appState.fsChanges.isEmpty {
                changeBadge
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
            if appState.scanProgress.skippedDirectories > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("\(appState.scanProgress.skippedDirectories) directories unreadable")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .help("Some directories could not be read due to permission restrictions. Enable Full Disk Access in System Settings for complete results.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
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
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// Live "N folders changed · Refresh" row shown inside `scanSummary` once
    /// `FSEventsMonitor` (started via Insights' "Watch Changes") has accumulated changes.
    /// One click applies them in place via `AppState.applyAccumulatedChanges()` — never
    /// automatic (plan 037, decision 3a). Count = `fsChanges.count`, the per-directory
    /// summaries the monitor tracks — the same set `applyAccumulatedChanges` feeds into
    /// its splice before any outermost-root collapsing.
    private var changeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.blue)
            Text("\(appState.fsChanges.count) folders changed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if appState.isApplyingChanges {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Refresh") {
                    Task { await appState.applyAccumulatedChanges() }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!appState.canStartHeavyTask(.applyChanges))
            }
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
                                            appState.search.extensionFilter = stat.extensionHash
                                            appState.search.extensionFilterName = stat.extensionName.isEmpty
                                                ? "(no ext)"
                                                : ".\(stat.extensionName)"
                                            appState.search.searchQuery = ""
                                            appState.activeTab = .search
                                        }
                                    )
                                case .duplicates:
                                    DuplicateFilesView(appState: appState)
                                case .hardlinks:
                                    HardlinkView(appState: appState)
                                case .search:
                                    SearchView(appState: appState)
                                case .spaceAnalysis:
                                    SpaceAnalysisView(appState: appState)
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
                    totalSize: appState.fileTree?.rootDisplaySize ?? 0
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
