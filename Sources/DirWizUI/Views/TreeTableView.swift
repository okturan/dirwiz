import SwiftUI
import DirWizCore

/// Hierarchical file/folder table with sortable columns.
/// Uses a flattened visible-items array with manual expand/collapse
/// for full control over indentation and disclosure arrows.
public struct TreeTableView: View {
    @Bindable var appState: AppState
    @State private var sortKey: TreeSortKey = .size
    @State private var sortAscending: Bool = false
    @State private var expandedFolders: Set<UInt32> = []
    @State private var scrollGeneration: UInt64 = 0
    @State private var minSizeFilter: UInt64 = 0
    @FocusState private var isFocused: Bool
    /// Cached visible items for keyboard navigation — avoids O(n) recompute on every keypress.
    @State private var cachedItems: [TreeNodeItem] = []

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        if let tree = appState.fileTree, !tree.isEmpty {
            treeContent(tree: tree)
        } else {
            ContentUnavailableView(
                "No Scan Results",
                systemImage: "internaldrive",
                description: Text("Select a volume and scan to see the file tree.")
            )
        }
    }

    // MARK: - Tree Content

    @ViewBuilder
    private func treeContent(tree: FileTree) -> some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ScrollViewReader { proxy in
                treeNavigationBar(tree: tree, proxy: proxy)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(cachedItems) { item in
                            treeRowContainer(item, tree: tree)
                                .id(item.id)
                            Divider()
                        }
                    }
                }
                .focusable()
                .focused($isFocused)
                .onChange(of: appState.selectedNodeIndex) { _, newValue in
                    revealAndScroll(to: newValue, nodes: tree.nodesSnapshot(), proxy: proxy)
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1, tree: tree, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1, tree: tree, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    collapseOrGoParent(tree: tree, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    expandOrGoFirstChild(tree: tree, proxy: proxy)
                    return .handled
                }
                .onAppear { cachedItems = flattenedVisibleItems(tree: tree) }
                .onChange(of: sortKey) { _, _ in cachedItems = flattenedVisibleItems(tree: tree) }
                .onChange(of: sortAscending) { _, _ in cachedItems = flattenedVisibleItems(tree: tree) }
                .onChange(of: minSizeFilter) { _, _ in cachedItems = flattenedVisibleItems(tree: tree) }
                .onChange(of: appState.scanProgress.treeLayoutRevision) { _, _ in cachedItems = flattenedVisibleItems(tree: tree) }
                .onChange(of: expandedFolders) { _, _ in cachedItems = flattenedVisibleItems(tree: tree) }
                .onKeyPress(.space) {
                    guard let sel = appState.selectedNodeIndex,
                          let tree = appState.fileTree else { return .ignored }
                    let path = tree.path(at: sel)
                    appState.quickLookCoordinator.toggleQuickLook(for: path)
                    return .handled
                }
            }
        }
    }

    /// Flatten the tree into a list of visible items based on which folders are expanded.
    private func flattenedVisibleItems(tree: FileTree) -> [TreeNodeItem] {
        let nodes = tree.nodesSnapshot()
        var result: [TreeNodeItem] = []
        result.reserveCapacity(256)
        let roots = rootChildren(tree: tree, nodes: nodes)
        for item in roots {
            collectVisible(item, into: &result)
        }
        return result
    }

    private func collectVisible(_ item: TreeNodeItem, into result: inout [TreeNodeItem]) {
        // Size threshold filter: use displaySize to match the row's on-disk size column.
        // Directory displaySize is aggregated from descendants, so if a directory is below
        // the threshold none of its children can exceed it either.
        if minSizeFilter > 0, item.node.displaySize < minSizeFilter {
            return
        }

        result.append(item)
        guard item.isDirectory, expandedFolders.contains(item.id) else { return }
        for child in item.children {
            collectVisible(child, into: &result)
        }
    }

    // MARK: - Row Container

    private func treeRowContainer(_ item: TreeNodeItem, tree: FileTree) -> some View {
        TreeRow(
            item: item,
            parentSize: parentSize(for: item),
            extensionPalette: appState.extensionPalette,
            depth: item.depth,
            isExpanded: expandedFolders.contains(item.id),
            onToggleExpand: {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if expandedFolders.contains(item.id) {
                        expandedFolders.remove(item.id)
                    } else {
                        expandedFolders.insert(item.id)
                    }
                }
            }
        )
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
            appState.selectedNodeIndex = item.id
            ensureVisibleInTreemap(item.id, nodes: item.nodes)
        }
        .contextMenu {
            if let tree = appState.fileTree {
                let path = tree.path(at: item.id)

                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }

                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }

                Button("Move to Trash") {
                    let size = tree.node(at: item.id)?.displaySize ?? 0
                    confirmTrash(name: item.name, size: size) {
                        Task {
                            let result = await appState.trashNode(at: item.id)
                            if result.success {
                                // Node indices are rebuilt after subtree removal, so reset the
                                // local expansion cache before rebuilding visible items.
                                expandedFolders.removeAll()
                                cachedItems = flattenedVisibleItems(tree: tree)
                            }
                        }
                    }
                }

                Divider()

                Button("Show in Treemap") {
                    appState.showNodeInTreemap(item.id)
                }

                if item.isDirectory {
                    Button("Zoom Into \"\(item.name)\"") {
                        appState.setTreemapRoot(item.id)
                    }
                }
            }
        }
        .background(
            appState.selectedNodeIndex == item.id
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            headerButton("Name", key: .name, width: nil, alignment: .leading)
                .frame(minWidth: TreeTableColumns.nameMinWidth, maxWidth: .infinity, alignment: .leading)
            headerButton("% of Parent", key: .percentage, width: TreeTableColumns.percentage, alignment: .leading)
            headerButton("On Disk", key: .size, width: TreeTableColumns.size, alignment: .trailing)
            headerButton("Logical", key: .allocated, width: TreeTableColumns.logical, alignment: .trailing)
            headerButton("Items", key: .items, width: TreeTableColumns.items, alignment: .trailing)
            headerButton("Modified", key: .modified, width: TreeTableColumns.modified, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .padding(.trailing, TreeTableColumns.rowTrailingPadding)
        .background(.bar)
    }

    /// - Parameter width: Fixed column width, or `nil` for the flexible name column
    ///   (the caller applies `maxWidth: .infinity` in that case).
    private func headerButton(_ title: String, key: TreeSortKey, width: CGFloat?, alignment: Alignment) -> some View {
        Button(action: {
            if sortKey == key {
                sortAscending.toggle()
            } else {
                sortKey = key
                sortAscending = false
            }
        }) {
            HStack(spacing: 3) {
                Text(title)
                if sortKey == key {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width)
    }

    // MARK: - Navigation Bar

    private func treeNavigationBar(tree: FileTree, proxy: ScrollViewProxy) -> some View {
        let canGoUp = canGoUpInTree(nodes: tree.nodesSnapshot())

        return HStack(spacing: 6) {
            Button {
                goUpInTree(nodes: tree.nodesSnapshot(), proxy: proxy)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .medium))
                    Text("Up")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoUp)
            .foregroundStyle(canGoUp ? .secondary : .quaternary)

            Divider()
                .frame(height: 14)

            Text(selectedNodeName(tree: tree))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            minSizeFilterMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar)
    }

    private var minSizeFilterMenu: some View {
        Menu {
            minSizeFilterMenuButton("All", value: 0)
            minSizeFilterMenuButton("> 1 MB", value: 1_000_000)
            minSizeFilterMenuButton("> 10 MB", value: 10_000_000)
            minSizeFilterMenuButton("> 100 MB", value: 100_000_000)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                Text(minSizeFilterTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(minWidth: 54, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 20)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .help("Minimum item size")
    }

    private func minSizeFilterMenuButton(_ title: String, value: UInt64) -> some View {
        Button {
            minSizeFilter = value
        } label: {
            if minSizeFilter == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var minSizeFilterTitle: String {
        switch minSizeFilter {
        case 0:
            return "All"
        case 1_000_000:
            return "> 1 MB"
        case 10_000_000:
            return "> 10 MB"
        case 100_000_000:
            return "> 100 MB"
        default:
            return SizeFormatter.shared.format(minSizeFilter)
        }
    }

    private func canGoUpInTree(nodes: [FileNode]) -> Bool {
        guard let selected = appState.selectedNodeIndex else { return false }
        let i = Int(selected)
        guard i < nodes.count else { return false }
        return nodes[i].parentIndex != FileNode.invalid
    }

    private func selectedNodeName(tree: FileTree) -> String {
        guard let selected = appState.selectedNodeIndex,
              Int(selected) < tree.count else {
            return "No Selection"
        }
        let name = tree.name(at: selected)
        return name.isEmpty ? "/" : name
    }

    private func goUpInTree(nodes: [FileNode], proxy: ScrollViewProxy) {
        guard let selected = appState.selectedNodeIndex else { return }
        let i = Int(selected)
        guard i < nodes.count else { return }

        let parentIndex = nodes[i].parentIndex
        guard parentIndex != FileNode.invalid else { return }

        appState.selectedNodeIndex = parentIndex
        revealAndScroll(to: parentIndex, nodes: nodes, proxy: proxy)
    }

    // MARK: - Selection Sync

    /// Expand all ancestors of the selected node and scroll it into view.
    private func revealAndScroll(to nodeIndex: UInt32?, nodes: [FileNode], proxy: ScrollViewProxy) {
        guard let nodeIndex else { return }
        let i = Int(nodeIndex)
        guard i < nodes.count else { return }

        // Walk parent chain, expand each ancestor (with depth guard).
        var didExpand = false
        var current = nodes[i].parentIndex
        var hops = 0
        while current != FileNode.invalid && Int(current) < nodes.count && hops < 512 {
            if expandedFolders.insert(current).inserted {
                didExpand = true
            }
            current = nodes[Int(current)].parentIndex
            hops += 1
        }

        if didExpand {
            // Ancestors were expanded — wait for SwiftUI to lay out new rows, then scroll.
            scrollGeneration &+= 1
            let gen = scrollGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard gen == scrollGeneration else { return }
                proxy.scrollTo(nodeIndex)
            }
        } else {
            // Node already visible in the list — minimal scroll, no delay.
            proxy.scrollTo(nodeIndex)
        }
    }

    /// If the node is not under the current treemap root, navigate treemap to show it.
    private func ensureVisibleInTreemap(_ nodeIndex: UInt32, nodes: [FileNode]) {
        let root = appState.navigation.treemapRootIndex

        // Walk parent chain — if we hit the current root, node is already visible
        var current = nodeIndex
        var hops = 0
        while current != FileNode.invalid && Int(current) < nodes.count && hops < 512 {
            if current == root { return }
            current = nodes[Int(current)].parentIndex
            hops += 1
        }

        // Not under current root — navigate treemap to parent dir.
        // showNodeInTreemap also sets selectedNodeIndex, but we already set it
        // in onTapGesture — the duplicate write is harmless (same value).
        appState.showNodeInTreemap(nodeIndex)
    }

    // MARK: - Keyboard Navigation

    private func moveSelection(by delta: Int, tree: FileTree, proxy: ScrollViewProxy) {
        let items = cachedItems.isEmpty ? flattenedVisibleItems(tree: tree) : cachedItems
        guard !items.isEmpty else { return }
        let currentIdx = items.firstIndex { $0.id == appState.selectedNodeIndex }
        let fromIdx = currentIdx ?? (delta > 0 ? -1 : items.count)
        let newIdx = max(0, min(items.count - 1, fromIdx + delta))
        let newItem = items[newIdx]
        appState.selectedNodeIndex = newItem.id
        // Reuse the item's own carried snapshot instead of asking the tree for a fresh one.
        ensureVisibleInTreemap(newItem.id, nodes: newItem.nodes)
        proxy.scrollTo(newItem.id)
    }

    /// Left arrow: collapse expanded directory, or jump to parent.
    private func collapseOrGoParent(tree: FileTree, proxy: ScrollViewProxy) {
        guard let selected = appState.selectedNodeIndex else { return }
        if expandedFolders.contains(selected) {
            withAnimation(.easeInOut(duration: 0.12)) {
                _ = expandedFolders.remove(selected)
            }
            return
        }
        let nodes = tree.nodesSnapshot()
        let i = Int(selected)
        guard i < nodes.count else { return }
        let parentIdx = nodes[i].parentIndex
        guard parentIdx != FileNode.invalid else { return }
        appState.selectedNodeIndex = parentIdx
        proxy.scrollTo(parentIdx)
    }

    /// Right arrow: expand collapsed directory, or move to its first child.
    private func expandOrGoFirstChild(tree: FileTree, proxy: ScrollViewProxy) {
        guard let selected = appState.selectedNodeIndex else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(selected)
        guard i < nodes.count, nodes[i].isDirectory else { return }
        guard !nodes[i].isBundle else { return }
        if !expandedFolders.contains(selected) {
            withAnimation(.easeInOut(duration: 0.12)) {
                _ = expandedFolders.insert(selected)
            }
        } else {
            let items = cachedItems.isEmpty ? flattenedVisibleItems(tree: tree) : cachedItems
            if let idx = items.firstIndex(where: { $0.id == selected }), idx + 1 < items.count {
                let child = items[idx + 1]
                appState.selectedNodeIndex = child.id
                proxy.scrollTo(child.id)
            }
        }
    }

    // MARK: - Helpers

    private func rootChildren(tree: FileTree, nodes: [FileNode]) -> [TreeNodeItem] {
        // depth: -1 so children are created at depth 0.
        let children = TreeNodeItem(
            id: 0, tree: tree, nodes: nodes, depth: -1,
            sortKey: sortKey, sortAscending: sortAscending
        ).children
        if children.isEmpty {
            return [TreeNodeItem(id: 0, tree: tree, nodes: nodes, depth: 0,
                                 sortKey: sortKey, sortAscending: sortAscending)]
        }
        return children
    }

    /// Reads the parent's size from the item's own carried snapshot (`item.nodes`) rather
    /// than `tree.node(at:)`, so rendering a row never takes the tree lock.
    private func parentSize(for item: TreeNodeItem) -> UInt64 {
        let parentIdx = item.node.parentIndex
        if parentIdx == FileNode.invalid { return item.node.displaySize }
        let i = Int(parentIdx)
        guard i < item.nodes.count else { return item.node.displaySize }
        return item.nodes[i].displaySize
    }

}
