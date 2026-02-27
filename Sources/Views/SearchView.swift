import SwiftUI

/// Everything-like instant file search view.
/// Stores raw matched indices and resolves display data lazily for visible rows only.
public struct SearchView: View {
    @Bindable var appState: AppState

    @State private var filters = SearchFilters()
    @State private var sortOrder: SortOrder = .size
    @State private var sortAscending: Bool = false

    // Raw sorted indices — no pre-built display objects.
    // Cached snapshots for lock-free rendering of visible rows.
    @State private var cachedNodes: [FileNode] = []
    @State private var cachedPool: Data = Data()

    @State private var totalMatches: Int = 0
    @State private var searchTimeMs: Double = 0
    @State private var isCapped: Bool = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration: UInt64 = 0
    @State private var showMoreCount: Int = 200
    @State private var previousQuery: String = ""
    @State private var previousMatchIndices: [UInt32]? = nil
    @State private var previousWasCapped: Bool = false
    @FocusState private var focusedField: FocusField?

    private enum FocusField { case searchBar, resultsList }
    private let pageSize = 200

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        if appState.fileTree == nil {
            ContentUnavailableView(
                "No Data",
                systemImage: "magnifyingglass",
                description: Text("Scan a volume to search files.")
            )
        } else {
            VStack(spacing: 0) {
                searchBar
                Divider()
                filterBar
                Divider()
                headerRow
                Divider()
                resultsList
                Divider()
                statusBar
            }
            .onAppear {
                focusedField = .searchBar
                // Apply extension filter that may have been set via drill-down from Extensions tab.
                if filters.extensionHash != appState.search.extensionFilter {
                    filters.extensionHash = appState.search.extensionFilter
                    previousMatchIndices = nil
                    triggerSearch()
                }
            }
            .onChange(of: appState.search.extensionFilter) { _, newValue in
                filters.extensionHash = newValue
                previousMatchIndices = nil
                triggerSearch()
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search files...", text: $appState.search.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focusedField, equals: .searchBar)
                .onChange(of: appState.search.searchQuery) { _, _ in
                    triggerSearch()
                }

            if appState.search.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if !appState.search.searchQuery.isEmpty {
                Button(action: {
                    appState.search.searchQuery = ""
                    appState.search.searchResults = []
                    totalMatches = 0
                    searchTimeMs = 0
                    previousQuery = ""
                    previousMatchIndices = nil
                    previousWasCapped = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $filters.nodeType) {
                Text("All").tag(SearchFilters.NodeType.all)
                Text("Files").tag(SearchFilters.NodeType.filesOnly)
                Text("Dirs").tag(SearchFilters.NodeType.directoriesOnly)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Picker("Category", selection: $filters.category) {
                Text("Any Category").tag(FileCategory?.none)
                ForEach(FileCategory.allCases) { cat in
                    Text(cat.rawValue).tag(FileCategory?.some(cat))
                }
            }
            .frame(width: 160)

            Picker("Min Size", selection: $filters.minimumSize) {
                Text("Any Size").tag(UInt64(0))
                Text("> 1 KB").tag(UInt64(1_024))
                Text("> 1 MB").tag(UInt64(1_048_576))
                Text("> 10 MB").tag(UInt64(10_485_760))
                Text("> 100 MB").tag(UInt64(104_857_600))
                Text("> 1 GB").tag(UInt64(1_073_741_824))
            }
            .frame(width: 130)

            // Extension drill-down chip — shown when an extension filter is active.
            if appState.search.extensionFilter != nil {
                Button(action: {
                    appState.search.extensionFilter = nil
                    appState.search.extensionFilterName = ""
                }) {
                    HStack(spacing: 4) {
                        Text(appState.search.extensionFilterName)
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Clear extension filter")
            }

            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .onChange(of: filters.nodeType) { _, _ in
            previousMatchIndices = nil
            triggerSearch()
        }
        .onChange(of: filters.category) { _, _ in
            previousMatchIndices = nil
            triggerSearch()
        }
        .onChange(of: filters.minimumSize) { _, _ in
            previousMatchIndices = nil
            triggerSearch()
        }
        // Clear stale node/pool snapshots when a new scan starts so the old
        // tree's memory is released and stale rows are never displayed.
        .onChange(of: appState.scanToken) { _, _ in
            cachedNodes = []
            cachedPool = Data()
            previousMatchIndices = nil
        }
    }

    // MARK: - Sortable Header

    private enum SortOrder: String {
        case name, size, modified
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortButton("Name", key: .name, width: 250, alignment: .leading)
            // Path column header (not sortable — paths are lazy).
            Text("Path")
                .frame(width: 300, alignment: .leading)
            sortButton("Size", key: .size, width: 80, alignment: .trailing)
            sortButton("Modified", key: .modified, width: 100, alignment: .trailing)
            Spacer()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func sortButton(_ title: String, key: SortOrder, width: CGFloat, alignment: Alignment) -> some View {
        Button(action: {
            if sortOrder == key {
                sortAscending.toggle()
            } else {
                sortOrder = key
                sortAscending = key == .name
            }
            resortIndices()
        }) {
            HStack(spacing: 3) {
                Text(title)
                if sortOrder == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let visibleSlice = appState.search.searchResults.prefix(showMoreCount)
                    ForEach(Array(visibleSlice), id: \.self) { idx in
                        resultRowView(idx)
                            .id(idx)
                        Divider().padding(.leading, 8)
                    }

                    if appState.search.searchResults.count > showMoreCount {
                        Button("Show \(min(pageSize, appState.search.searchResults.count - showMoreCount)) more...") {
                            showMoreCount += pageSize
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .padding(.vertical, 8)
                    }
                }
            }
            .focusable()
            .focused($focusedField, equals: .resultsList)
            .onKeyPress(.upArrow) {
                moveResultSelection(by: -1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveResultSelection(by: 1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.space) {
                guard focusedField == .resultsList else { return .ignored }
                toggleQuickLook()
                return .handled
            }
        }
    }

    /// Render a single result row. Display data is resolved lazily from cached snapshots —
    /// only ~30 visible rows pay the cost, not all 10K matches.
    private func resultRowView(_ idx: UInt32) -> some View {
        let i = Int(idx)
        let node = i < cachedNodes.count ? cachedNodes[i] : FileNode()
        let name = Self.extractName(node: node, pool: cachedPool)
        let iconName = node.isDirectory ? "folder.fill" : Self.fileIcon(for: name)

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(node.isDirectory ? .blue : .secondary)
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .frame(width: 250, alignment: .leading)

            // Path — computed lazily per visible row via FileTree.path(at:).
            Text(appState.fileTree?.path(at: idx) ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 300, alignment: .leading)

            Text(SizeFormatter.shared.format(node.fileSize))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 80, alignment: .trailing)

            Text(Self.formatDate(node.modifiedDate))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            appState.selectedNodeIndex == idx
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            appState.showNodeInTreemap(idx)
            appState.activeTab = .treeView
        })
        .onTapGesture {
            appState.selectedNodeIndex = idx
            focusedField = .resultsList
        }
        .contextMenu {
            Button("Reveal in Finder") {
                if let tree = appState.fileTree {
                    let path = tree.path(at: idx)
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
            Button("Copy Path") {
                if let tree = appState.fileTree {
                    let path = tree.path(at: idx)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            Button("Show in Tree View") {
                appState.showNodeInTreemap(idx)
                appState.activeTab = .treeView
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            if totalMatches == 0 && !appState.search.searchQuery.isEmpty && !appState.search.isSearching {
                Text("No results")
                    .foregroundStyle(.secondary)
            } else if totalMatches > 0 {
                if isCapped {
                    Text("\(SizeFormatter.shared.formatCount(min(appState.search.searchResults.count, showMoreCount))) of \(SizeFormatter.shared.formatCount(totalMatches)) results (capped)")
                } else {
                    Text("\(SizeFormatter.shared.formatCount(totalMatches)) results")
                }
            } else {
                Text("Type to search")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if searchTimeMs > 0 {
                Text(String(format: "%.1f ms", searchTimeMs))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: - Keyboard Navigation

    private func moveResultSelection(by delta: Int, proxy: ScrollViewProxy) {
        let results = Array(appState.search.searchResults.prefix(showMoreCount))
        guard !results.isEmpty else { return }
        let currentIdx = results.firstIndex(where: { $0 == appState.selectedNodeIndex })
        let fromIdx = currentIdx ?? (delta > 0 ? -1 : results.count)
        let newIdx = max(0, min(results.count - 1, fromIdx + delta))
        let selected = results[newIdx]
        appState.selectedNodeIndex = selected
        proxy.scrollTo(selected)
    }

    private func toggleQuickLook() {
        guard let sel = appState.selectedNodeIndex,
              let tree = appState.fileTree else { return }
        let path = tree.path(at: sel)
        appState.quickLookCoordinator.toggleQuickLook(for: path)
    }

    // MARK: - Search Execution

    private func triggerSearch() {
        searchTask?.cancel()
        showMoreCount = pageSize
        searchGeneration &+= 1
        let thisGeneration = searchGeneration
        let thisScanToken = appState.scanToken

        // Allow empty query when an extension filter is active — show all files with that extension.
        guard (!appState.search.searchQuery.isEmpty || filters.extensionHash != nil),
              let tree = appState.fileTree else {
            appState.search.searchResults = []
            totalMatches = 0
            searchTimeMs = 0
            isCapped = false
            appState.search.isSearching = false
            previousQuery = ""
            previousMatchIndices = nil
            previousWasCapped = false
            return
        }

        appState.search.isSearching = true
        let currentQuery = appState.search.searchQuery
        let currentFilters = filters
        let currentSort = sortOrder
        let currentAscending = sortAscending
        let oldQuery = previousQuery
        let oldMatches = previousMatchIndices
        let wasCapped = previousWasCapped
        // Only use refinement if the previous query wasn't capped — otherwise
        // we'd miss valid matches that were beyond the 10K cap.
        let canRefine = !currentQuery.isEmpty && currentQuery.hasPrefix(oldQuery)
            && oldQuery.count > 0 && !wasCapped
        let prevMatches = canRefine ? oldMatches : nil

        searchTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }

            let nodes = tree.nodesSnapshot()
            let (searchPool, searchEntries) = tree.searchIndexSnapshot()

            guard !Task.isCancelled else { return }

            let searchResult = SearchEngine.search(
                query: currentQuery,
                nodes: nodes,
                searchPool: searchPool,
                searchEntries: searchEntries,
                filters: currentFilters,
                previousMatches: prevMatches
            )

            guard !Task.isCancelled else { return }

            let displayPool = tree.stringPoolSnapshot()
            var sortedIndices = searchResult.matchingIndices
            Self.sortIndices(&sortedIndices, nodes: nodes, pool: displayPool, by: currentSort, ascending: currentAscending)

            guard !Task.isCancelled else { return }

            let finalIndices = sortedIndices
            let resultWasCapped = searchResult.totalMatches > searchResult.matchingIndices.count
            await MainActor.run {
                // Discard if a newer search was triggered or a new scan started while we ran.
                guard thisGeneration == searchGeneration,
                      appState.scanToken == thisScanToken else { return }
                cachedNodes = nodes
                cachedPool = displayPool
                appState.search.searchResults = finalIndices
                totalMatches = searchResult.totalMatches
                searchTimeMs = searchResult.elapsedTime * 1000
                isCapped = resultWasCapped
                appState.search.isSearching = false
                previousQuery = currentQuery
                previousMatchIndices = searchResult.matchingIndices
                previousWasCapped = resultWasCapped
            }
        }
    }

    /// Re-sort existing results without re-searching.
    private func resortIndices() {
        searchTask?.cancel()
        searchGeneration &+= 1
        let thisGeneration = searchGeneration
        let indices = appState.search.searchResults
        let nodes = cachedNodes
        let pool = cachedPool
        let order = sortOrder
        let ascending = sortAscending

        appState.search.isSearching = true
        searchTask = Task.detached(priority: .userInitiated) {
            var sorted = indices
            Self.sortIndices(&sorted, nodes: nodes, pool: pool, by: order, ascending: ascending)
            guard !Task.isCancelled else { return }
            let result = sorted
            await MainActor.run {
                guard thisGeneration == searchGeneration else { return }
                appState.search.searchResults = result
                appState.search.isSearching = false
            }
        }
    }

    /// Sort indices using direct node field comparison — no String allocation for size/date.
    /// Name sort uses byte-level comparison on the string pool.
    private nonisolated static func sortIndices(
        _ indices: inout [UInt32],
        nodes: [FileNode],
        pool: Data,
        by order: SortOrder,
        ascending: Bool
    ) {
        switch order {
        case .size:
            if ascending {
                indices.sort { nodes[Int($0)].fileSize < nodes[Int($1)].fileSize }
            } else {
                indices.sort { nodes[Int($0)].fileSize > nodes[Int($1)].fileSize }
            }
        case .modified:
            if ascending {
                indices.sort { nodes[Int($0)].modifiedDate < nodes[Int($1)].modifiedDate }
            } else {
                indices.sort { nodes[Int($0)].modifiedDate > nodes[Int($1)].modifiedDate }
            }
        case .name:
            // Pre-extract names once, then sort with Finder-style natural ordering
            // (e.g., "file2" before "file10") via localizedStandardCompare.
            let names: [String] = indices.map { idx in
                let node = nodes[Int(idx)]
                let start = Int(node.nameOffset)
                let end = start + Int(node.nameLength)
                guard end <= pool.count else { return "" }
                return String(data: pool[start..<end], encoding: .utf8) ?? ""
            }
            var paired = Array(zip(indices, names))
            paired.sort { a, b in
                let cmp = a.1.localizedStandardCompare(b.1)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
            indices = paired.map { $0.0 }
        }
    }

    /// Extract name from string pool data — no lock needed.
    private nonisolated static func extractName(node: FileNode, pool: Data) -> String {
        let start = Int(node.nameOffset)
        let end = start + Int(node.nameLength)
        guard end <= pool.count else { return "" }
        return String(data: pool[start..<end], encoding: .utf8) ?? ""
    }

    private nonisolated static func fileIcon(for name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "doc" }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg": return "photo"
        case "mp4", "mov", "avi", "mkv", "wmv": return "film"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg": return "music.note"
        case "zip", "tar", "gz", "7z", "rar", "dmg": return "archivebox"
        case "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "java": return "chevron.left.forwardslash.chevron.right"
        case "app": return "app.gift"
        default: return "doc"
        }
    }

    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    static func formatDate(_ timestamp: UInt32) -> String {
        guard timestamp > 0 else { return "-" }
        return sharedDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}
