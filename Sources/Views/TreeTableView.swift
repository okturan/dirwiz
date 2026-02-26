import SwiftUI

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
                        let items = flattenedVisibleItems(tree: tree)
                        ForEach(items) { item in
                            treeRowContainer(item, tree: tree)
                                .id(item.id)
                            Divider().padding(.leading, CGFloat(item.depth) * 18 + 12)
                        }
                    }
                }
                .focusable()
                .focused($isFocused)
                .onChange(of: appState.selectedNodeIndex) { _, newValue in
                    revealAndScroll(to: newValue, tree: tree, proxy: proxy)
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
        // Size threshold filter: skip this node and its entire subtree if it falls below the
        // minimum. Because directory fileSize equals the sum of all descendants, if a directory
        // is below the threshold none of its children can exceed it either — so skipping the
        // subtree is both correct and efficient.
        if minSizeFilter > 0, item.node.fileSize < minSizeFilter {
            return
        }

        result.append(item)
        guard item.isDirectory, expandedFolders.contains(item.id) else { return }
        for child in item.children {
            collectVisible(child, into: &result)
        }
    }

    // MARK: - Row Container (indentation + arrow + content)

    private func treeRowContainer(_ item: TreeNodeItem, tree: FileTree) -> some View {
        HStack(spacing: 0) {
            // Depth-based indentation: 12pt base + 18pt per level.
            Color.clear
                .frame(width: CGFloat(item.depth) * 18 + 12, height: 1)

            // Disclosure arrow
            if item.hasChildren {
                let isExpanded = expandedFolders.contains(item.id)
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if isExpanded {
                            expandedFolders.remove(item.id)
                        } else {
                            expandedFolders.insert(item.id)
                        }
                    }
                } label: {
                    Image(systemName: expandedFolders.contains(item.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
            } else {
                // Leaf node — spacer to align with siblings.
                Color.clear.frame(width: 16, height: 1)
            }

            // Row content
            TreeRow(
                item: item,
                parentSize: parentSize(for: item, tree: tree),
                isSelected: appState.selectedNodeIndex == item.id,
                extensionPalette: appState.extensionPalette
            )
        }
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
            appState.selectedNodeIndex = item.id
            ensureVisibleInTreemap(item.id, tree: tree)
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
                    let url = URL(fileURLWithPath: path)
                    let size = tree.node(at: item.id)?.fileSize ?? 0
                    confirmTrash(name: item.name, size: size) {
                        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                            appState.rescanVolume()
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
            headerButton("Name", key: .name, minWidth: 200, alignment: .leading)
            headerButton("% of Parent", key: .percentage, minWidth: 100, alignment: .leading)
            headerButton("Size", key: .size, minWidth: 80, alignment: .trailing)
            headerButton("Allocated", key: .allocated, minWidth: 80, alignment: .trailing)
            headerButton("Items", key: .items, minWidth: 60, alignment: .trailing)
            headerButton("Modified", key: .modified, minWidth: 100, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func headerButton(_ title: String, key: TreeSortKey, minWidth: CGFloat, alignment: Alignment) -> some View {
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
        }
        .buttonStyle(.plain)
        .frame(minWidth: minWidth)
    }

    // MARK: - Navigation Bar

    private func treeNavigationBar(tree: FileTree, proxy: ScrollViewProxy) -> some View {
        let canGoUp = canGoUpInTree(tree: tree)

        return HStack(spacing: 6) {
            Button {
                goUpInTree(tree: tree, proxy: proxy)
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

            Picker("Min Size", selection: $minSizeFilter) {
                Text("All").tag(UInt64(0))
                Text("> 1 MB").tag(UInt64(1_000_000))
                Text("> 10 MB").tag(UInt64(10_000_000))
                Text("> 100 MB").tag(UInt64(100_000_000))
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar)
    }

    private func canGoUpInTree(tree: FileTree) -> Bool {
        guard let selected = appState.selectedNodeIndex else { return false }
        let nodes = tree.nodesSnapshot()
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

    private func goUpInTree(tree: FileTree, proxy: ScrollViewProxy) {
        guard let selected = appState.selectedNodeIndex else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(selected)
        guard i < nodes.count else { return }

        let parentIndex = nodes[i].parentIndex
        guard parentIndex != FileNode.invalid else { return }

        appState.selectedNodeIndex = parentIndex
        revealAndScroll(to: parentIndex, tree: tree, proxy: proxy)
    }

    // MARK: - Selection Sync

    /// Expand all ancestors of the selected node and scroll it into view.
    private func revealAndScroll(to nodeIndex: UInt32?, tree: FileTree, proxy: ScrollViewProxy) {
        guard let nodeIndex else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(nodeIndex)
        guard i < nodes.count else { return }

        // Walk parent chain, expand each ancestor (with max-hop guard)
        var current = nodes[i].parentIndex
        var hops = 0
        while current != FileNode.invalid && Int(current) < nodes.count && hops < nodes.count {
            expandedFolders.insert(current)
            current = nodes[Int(current)].parentIndex
            hops += 1
        }

        // Scroll after SwiftUI processes the expansion.
        // Generation token prevents stale closures from scrolling to outdated selections.
        scrollGeneration &+= 1
        let gen = scrollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard gen == scrollGeneration else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(nodeIndex, anchor: .center)
            }
        }
    }

    /// If the node is not under the current treemap root, navigate treemap to show it.
    private func ensureVisibleInTreemap(_ nodeIndex: UInt32, tree: FileTree) {
        let nodes = tree.nodesSnapshot()
        let root = appState.treemapRootIndex

        // Walk parent chain — if we hit the current root, node is already visible
        var current = nodeIndex
        var hops = 0
        while current != FileNode.invalid && Int(current) < nodes.count && hops < nodes.count {
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
        let items = flattenedVisibleItems(tree: tree)
        guard !items.isEmpty else { return }
        let currentIdx = items.firstIndex { $0.id == appState.selectedNodeIndex }
        let fromIdx = currentIdx ?? (delta > 0 ? -1 : items.count)
        let newIdx = max(0, min(items.count - 1, fromIdx + delta))
        let newItem = items[newIdx]
        appState.selectedNodeIndex = newItem.id
        ensureVisibleInTreemap(newItem.id, tree: tree)
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
            let items = flattenedVisibleItems(tree: tree)
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

    private func parentSize(for item: TreeNodeItem, tree: FileTree) -> UInt64 {
        let parentIdx = item.node.parentIndex
        if parentIdx == FileNode.invalid { return item.node.fileSize }
        return tree.node(at: parentIdx)?.fileSize ?? item.node.fileSize
    }

}
