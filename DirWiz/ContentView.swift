import SwiftUI
import AppKit
import DirWizLib

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
                    Button { exportReport() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export Report as CSV (Cmd+Opt+E)")
                    .keyboardShortcut("e", modifiers: [.command, .option])
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
            VolumePickerView(appState: appState, onScan: startScan)

            if !appState.hasFullDiskAccess {
                fullDiskAccessBanner
            }

            if appState.scanProgress.isScanning {
                ScanProgressView(scanProgress: appState.scanProgress, onCancel: cancelScan)
            }

            Spacer()

            if appState.scanProgress.scanComplete {
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
                    Text("Scan Complete")
                        .font(.callout.bold())
                }
            }
            if let tree = appState.fileTree {
                Text("\(SizeFormatter.shared.formatCount(tree.count)) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(SizeFormatter.shared.format(tree.nodes.first?.displaySize ?? 0))
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
                                        totalSize: appState.fileTree?.nodes.first?.displaySize ?? 0,
                                        extensionPalette: appState.extensionPalette
                                    )
                                case .duplicates:
                                    DuplicateFilesView(appState: appState)
                                case .hardlinks:
                                    HardlinkView(appState: appState)
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
                    totalSize: appState.fileTree?.nodes.first?.displaySize ?? 0
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
        let csv = buildCSV(tree: tree, rootIndex: rootIndex)

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

    /// Walk the tree depth-first from `rootIndex`, collecting the top 500 rows sorted
    /// largest-first (children already pre-sorted by sortAllChildren()).
    private func buildCSV(tree: FileTree, rootIndex: UInt32) -> String {
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()

        struct StackEntry { var index: UInt32; var depth: Int }
        var stack: [StackEntry] = [StackEntry(index: rootIndex, depth: 0)]
        var lines: [String] = ["Path,Type,Size (bytes),Size (human),Extension,Depth"]
        lines.reserveCapacity(502)

        while !stack.isEmpty && lines.count <= 500 {
            let entry = stack.removeLast()
            let i = Int(entry.index)
            guard i < nodes.count else { continue }
            let node = nodes[i]

            let path = FileTree.pathFromSnapshot(
                at: entry.index, nodes: nodes, stringPool: stringPool, rootPath: rootPath
            )
            let ext: String
            if node.isDirectory {
                ext = ""
            } else {
                let nameStart = Int(node.nameOffset)
                let nameEnd = min(nameStart + Int(node.nameLength), stringPool.count)
                if let name = String(data: stringPool[nameStart..<nameEnd], encoding: .utf8),
                   let dot = name.range(of: ".", options: .backwards),
                   dot.lowerBound != name.startIndex {
                    ext = String(name[name.index(after: dot.lowerBound)...])
                } else {
                    ext = ""
                }
            }

            lines.append([
                csvQuote(path),
                node.isDirectory ? "directory" : "file",
                "\(node.fileSize)",
                csvQuote(SizeFormatter.shared.format(node.fileSize)),
                csvQuote(ext),
                "\(entry.depth)",
            ].joined(separator: ","))

            guard node.isDirectory, node.firstChildIndex != FileNode.invalid,
                  node.childCount > 0 else { continue }
            let start = Int(node.firstChildIndex)
            let end = min(start + Int(node.childCount), nodes.count)
            guard start < end else { continue }
            // Push in reverse so largest (first child) comes off stack first.
            for ci in stride(from: end - 1, through: start, by: -1) {
                stack.append(StackEntry(index: UInt32(ci), depth: entry.depth + 1))
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func csvQuote(_ value: String) -> String {
        // Prefix with a tab to neutralize spreadsheet formula injection
        // (filenames starting with =, +, -, @ are treated as formulas in Excel/Sheets).
        let safe: String
        if let first = value.first, "=+-@\t".contains(first) {
            safe = "\t" + value
        } else {
            safe = value
        }
        guard safe.contains(",") || safe.contains("\"") || safe.contains("\n") else {
            return safe
        }
        return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
