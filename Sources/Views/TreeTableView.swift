import SwiftUI

// MARK: - Tree Node Wrapper

/// Identifiable wrapper around a FileTree node index for use in the tree view.
/// Lazily provides children so only expanded nodes are resolved.
struct TreeNodeItem: Identifiable {
    let id: UInt32 // node index in the FileTree
    let tree: FileTree
    let depth: Int
    let reclaimScores: [UInt8]
    let sortKey: TreeSortKey
    let sortAscending: Bool

    init(
        id: UInt32,
        tree: FileTree,
        depth: Int,
        reclaimScores: [UInt8] = [],
        sortKey: TreeSortKey = .size,
        sortAscending: Bool = false
    ) {
        self.id = id
        self.tree = tree
        self.depth = depth
        self.reclaimScores = reclaimScores
        self.sortKey = sortKey
        self.sortAscending = sortAscending
    }

    var node: FileNode { tree.node(at: id) ?? FileNode() }
    var name: String { tree.name(at: id) }
    var isDirectory: Bool { node.isDirectory }

    /// Whether this directory has any children (cheap check — no sorting).
    var hasChildren: Bool {
        guard isDirectory else { return false }
        return !tree.children(of: id).isEmpty
    }

    /// Sorted children — only call when actually expanding.
    var children: [TreeNodeItem] {
        let childIndices = tree.children(of: id).map { UInt32($0) }
        let sorted = childIndices.sorted(by: compare)
        return sorted.map {
            TreeNodeItem(
                id: $0,
                tree: tree,
                depth: depth + 1,
                reclaimScores: reclaimScores,
                sortKey: sortKey,
                sortAscending: sortAscending
            )
        }
    }

    private func compare(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
        guard
            let lhsNode = tree.node(at: lhs),
            let rhsNode = tree.node(at: rhs)
        else { return lhs < rhs }

        let isLess: Bool
        switch sortKey {
        case .name:
            let lhsName = tree.name(at: lhs)
            let rhsName = tree.name(at: rhs)
            isLess = lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        case .percentage:
            isLess = lhsNode.fileSize < rhsNode.fileSize
        case .size:
            isLess = lhsNode.fileSize < rhsNode.fileSize
        case .allocated:
            isLess = lhsNode.allocatedSize < rhsNode.allocatedSize
        case .items:
            isLess = lhsNode.childCount < rhsNode.childCount
        case .modified:
            isLess = lhsNode.modifiedDate < rhsNode.modifiedDate
        case .reclaimScore:
            let lhsScore = reclaimScore(for: lhs, isDirectory: lhsNode.isDirectory)
            let rhsScore = reclaimScore(for: rhs, isDirectory: rhsNode.isDirectory)
            isLess = lhsScore < rhsScore
        }

        if sortAscending {
            if isLess { return true }
            if compareEqual(lhsNode: lhsNode, rhsNode: rhsNode, lhs: lhs, rhs: rhs) { return lhs < rhs }
            return false
        } else {
            if !isLess, !compareEqual(lhsNode: lhsNode, rhsNode: rhsNode, lhs: lhs, rhs: rhs) { return true }
            if compareEqual(lhsNode: lhsNode, rhsNode: rhsNode, lhs: lhs, rhs: rhs) { return lhs < rhs }
            return false
        }
    }

    private func compareEqual(lhsNode: FileNode, rhsNode: FileNode, lhs: UInt32, rhs: UInt32) -> Bool {
        switch sortKey {
        case .name:
            return tree.name(at: lhs).localizedCaseInsensitiveCompare(tree.name(at: rhs)) == .orderedSame
        case .percentage, .size:
            return lhsNode.fileSize == rhsNode.fileSize
        case .allocated:
            return lhsNode.allocatedSize == rhsNode.allocatedSize
        case .items:
            return lhsNode.childCount == rhsNode.childCount
        case .modified:
            return lhsNode.modifiedDate == rhsNode.modifiedDate
        case .reclaimScore:
            return reclaimScore(for: lhs, isDirectory: lhsNode.isDirectory) ==
                reclaimScore(for: rhs, isDirectory: rhsNode.isDirectory)
        }
    }

    private func reclaimScore(for index: UInt32, isDirectory: Bool) -> UInt8 {
        guard isDirectory else { return 0 }
        let idx = Int(index)
        guard idx < reclaimScores.count else { return 0 }
        return reclaimScores[idx]
    }
}

// MARK: - Sort Descriptor

/// Column sort keys for the tree table.
enum TreeSortKey: String {
    case name
    case percentage
    case size
    case allocated
    case items
    case modified
    case reclaimScore
}

// MARK: - TreeTableView

/// Hierarchical file/folder table with sortable columns.
/// Uses a flattened visible-items array with manual expand/collapse
/// for full control over indentation and disclosure arrows.
public struct TreeTableView: View {
    @Bindable var appState: AppState
    @State private var sortKey: TreeSortKey = .size
    @State private var sortAscending: Bool = false
    @State private var expandedFolders: Set<UInt32> = []
    @State private var scrollGeneration: UInt64 = 0

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let items = flattenedVisibleItems(tree: tree)
                        ForEach(items) { item in
                            treeRowContainer(item, tree: tree)
                            Divider().padding(.leading, CGFloat(item.depth) * 18 + 12)
                        }
                    }
                }
                .onChange(of: appState.selectedNodeIndex) { _, newValue in
                    revealAndScroll(to: newValue, tree: tree, proxy: proxy)
                }
            }
        }
    }

    /// Flatten the tree into a list of visible items based on which folders are expanded.
    private func flattenedVisibleItems(tree: FileTree) -> [TreeNodeItem] {
        var result: [TreeNodeItem] = []
        result.reserveCapacity(256)
        let roots = rootChildren(tree: tree)
        for item in roots {
            collectVisible(item, into: &result)
        }
        return result
    }

    private func collectVisible(_ item: TreeNodeItem, into result: inout [TreeNodeItem]) {
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
                        .frame(width: 16, height: 16)
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
                extensionPalette: appState.extensionPalette,
                reclaimScore: item.isDirectory && Int(item.id) < appState.reclaimScores.count
                    ? appState.reclaimScores[Int(item.id)]
                    : nil
            )
        }
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedNodeIndex = item.id
            ensureVisibleInTreemap(item.id, tree: tree)
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
            headerButton("Score", key: .reclaimScore, minWidth: 65, alignment: .trailing)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
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

    // MARK: - Helpers

    private func rootChildren(tree: FileTree) -> [TreeNodeItem] {
        let sorted = TreeNodeItem(
            id: 0,
            tree: tree,
            depth: -1,
            reclaimScores: appState.reclaimScores,
            sortKey: sortKey,
            sortAscending: sortAscending
        ).children.map(\.id)
        if sorted.isEmpty {
            return [TreeNodeItem(
                id: 0,
                tree: tree,
                depth: 0,
                reclaimScores: appState.reclaimScores,
                sortKey: sortKey,
                sortAscending: sortAscending
            )]
        }
        return sorted.map {
            TreeNodeItem(
                id: $0,
                tree: tree,
                depth: 0,
                reclaimScores: appState.reclaimScores,
                sortKey: sortKey,
                sortAscending: sortAscending
            )
        }
    }

    private func parentSize(for item: TreeNodeItem, tree: FileTree) -> UInt64 {
        let parentIdx = item.node.parentIndex
        if parentIdx == FileNode.invalid { return item.node.fileSize }
        return tree.node(at: parentIdx)?.fileSize ?? item.node.fileSize
    }
}

// MARK: - TreeRow

/// A single row in the tree table showing file/folder details.
private struct TreeRow: View {
    let item: TreeNodeItem
    let parentSize: UInt64
    let isSelected: Bool
    let extensionPalette: ExtensionPalette
    let reclaimScore: UInt8?

    var body: some View {
        HStack(spacing: 0) {
            // Name column
            nameColumn
                .frame(minWidth: 200, alignment: .leading)

            // Percentage bar column
            percentageColumn
                .frame(minWidth: 100, alignment: .leading)

            // Size column
            Text(SizeFormatter.shared.format(item.node.fileSize))
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 80, alignment: .trailing)

            // Allocated column
            Text(SizeFormatter.shared.format(item.node.allocatedSize))
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 80, alignment: .trailing)

            // Items count column
            itemsColumn
                .frame(minWidth: 60, alignment: .trailing)

            // Modified date column
            Text(formattedDate)
                .font(.system(size: 11))
                .frame(minWidth: 100, alignment: .trailing)

            // Reclaim score column
            reclaimScoreColumn
                .frame(minWidth: 65, alignment: .trailing)
        }
    }

    // MARK: - Column Views

    private var nameColumn: some View {
        HStack(spacing: 5) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(item.isDirectory ? .blue : .secondary)

            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var percentageColumn: some View {
        let pct = parentSize > 0 ? Double(item.node.fileSize) / Double(parentSize) : 0

        return HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(categoryColor)
                        .frame(width: max(0, geo.size.width * pct))
                }
            }
            .frame(width: 60, height: 10)

            Text(String(format: "%.1f%%", pct * 100))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var itemsColumn: some View {
        Group {
            if item.isDirectory {
                Text(SizeFormatter.shared.formatCount(Int(item.node.childCount)))
                    .font(.system(size: 11, design: .monospaced))
            } else {
                Text("-")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var reclaimScoreColumn: some View {
        Group {
            if item.isDirectory, let score = reclaimScore {
                HStack(spacing: 5) {
                    Circle()
                        .fill(scoreColor(score))
                        .frame(width: 8, height: 8)
                    Text("\(score)")
                        .font(.system(size: 11, design: .monospaced))
                }
            } else {
                Text("-")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private var categoryColor: Color {
        if item.isDirectory {
            return .blue.opacity(0.6)
        }
        return extensionPalette.swiftUIColor(forHash: item.node.extensionHash)
    }

    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private var formattedDate: String {
        guard item.node.modifiedDate > 0 else { return "-" }
        let date = Date(timeIntervalSince1970: TimeInterval(item.node.modifiedDate))
        return Self.sharedDateFormatter.string(from: date)
    }

    private func scoreColor(_ score: UInt8) -> Color {
        switch score {
        case 70...100:
            return .red
        case 40...69:
            return .orange
        case 15...39:
            return .yellow
        default:
            return .green
        }
    }
}
