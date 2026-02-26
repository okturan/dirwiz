import SwiftUI
import DirWizLib

/// Root view with NavigationSplitView layout.
struct ContentView: View {
    @Bindable var appState: AppState

    @State private var showLegend: Bool = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var splitRatio: CGFloat = 0.4

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
                        if appState.isSnapshotBuilding {
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
                            get: { appState.isTemporalDiffEnabled },
                            set: { enabled in
                                appState.isTemporalDiffEnabled = enabled
                                if enabled { appState.startTemporalDiff() }
                            }
                        )) {
                            Image(systemName: "timelapse")
                        }
                        .help("Temporal Diff — highlight changes since snapshot (Cmd+Opt+D)")
                        .keyboardShortcut("d", modifiers: [.command, .option])
                        .disabled(!appState.scanProgress.scanComplete || appState.temporalSnapshot == nil)
                    }
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

            Divider()

            footerBar
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VolumePickerView(appState: appState, onScan: startScan)

            if appState.scanProgress.isScanning {
                ScanProgressView(scanProgress: appState.scanProgress, onCancel: cancelScan)
            }

            Spacer()

            if appState.scanProgress.scanComplete {
                scanSummary
            }
        }
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
                    Text("Scan Complete")
                        .font(.callout.bold())
                }
            }
            if let tree = appState.fileTree {
                Text("\(SizeFormatter.shared.formatCount(tree.count)) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SizeFormatter.shared.format(tree.nodes.first?.fileSize ?? 0))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(String(format: "%.1fs elapsed", appState.scanProgress.elapsedTime))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
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
                            if appState.scanProgress.isScanning {
                                scanningPlaceholder
                            } else {
                                switch appState.activeTab {
                                case .treeView:
                                    TreeTableView(appState: appState)
                                case .extensions:
                                    ExtensionListView(
                                        fileTypeStats: appState.fileTypeStats,
                                        totalSize: appState.fileTree?.nodes.first?.fileSize ?? 0,
                                        extensionPalette: appState.extensionPalette
                                    )
                                case .duplicates:
                                    DuplicateFilesView(appState: appState)
                                case .search:
                                    SearchView(appState: appState)
                                }
                            }
                        }
                        .frame(height: max(60, geo.size.height * splitRatio))
                        .clipped()

                        // Resizable drag divider.
                        splitDivider(totalHeight: geo.size.height)

                        // Temporal diff status banner.
                        if appState.isTemporalDiffEnabled,
                           let snap = appState.temporalSnapshot {
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
                    totalSize: appState.fileTree?.nodes.first?.fileSize ?? 0
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
                appState.isTemporalDiffEnabled = false
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
        guard let volumeURL = appState.selectedVolume else { return }
        // Cancel any existing scan (user may rescan without waiting).
        appState.activeScanner?.cancel()
        let scanner = FileScanner()
        appState.activeScanner = scanner
        let path = volumeURL.path

        // Create tree upfront so the UI can observe it growing during scan.
        let tree = FileTree()
        appState.fileTree = tree
        appState.resetForNewScan()
        appState.activeTab = .treeView
        appState.scanStartTime = CFAbsoluteTimeGetCurrent()

        let token = appState.scanToken
        Task {
            await scanner.scan(path: path, progress: appState.scanProgress, tree: tree)
            await MainActor.run {
                // Discard completion if a newer scan was started while we ran.
                guard appState.scanToken == token else { return }
                appState.scanDuration = CFAbsoluteTimeGetCurrent() - appState.scanStartTime
                appState.activeScanner = nil
                appState.setTreemapRoot(0, recordHistory: false)
                appState.computeExtensionStats()
            }
        }
    }

    private func cancelScan() {
        appState.activeScanner?.cancel()
    }
}
