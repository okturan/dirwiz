import Foundation

// MARK: - Sort Descriptor

/// Column sort keys for the tree table.
enum TreeSortKey: String {
    case name
    case percentage
    case size
    case allocated
    case items
    case modified
}

// MARK: - Tree Node Wrapper

/// Identifiable wrapper around a FileTree node index for use in the tree view.
/// Lazily provides children so only expanded nodes are resolved.
struct TreeNodeItem: Identifiable {
    let id: UInt32 // node index in the FileTree
    let tree: FileTree
    let nodes: [FileNode]
    let depth: Int
    let sortKey: TreeSortKey
    let sortAscending: Bool

    init(
        id: UInt32,
        tree: FileTree,
        nodes: [FileNode],
        depth: Int,
        sortKey: TreeSortKey = .size,
        sortAscending: Bool = false
    ) {
        self.id = id
        self.tree = tree
        self.nodes = nodes
        self.depth = depth
        self.sortKey = sortKey
        self.sortAscending = sortAscending
    }

    var node: FileNode {
        let i = Int(id)
        guard i < nodes.count else { return FileNode() }
        return nodes[i]
    }
    var name: String { tree.name(at: id) }
    var isDirectory: Bool { node.isDirectory }

    /// Whether this directory has any children (cheap check — no sorting).
    var hasChildren: Bool {
        guard isDirectory else { return false }
        guard !node.isBundle else { return false }
        return !tree.children(of: id).isEmpty
    }

    /// Sorted children — only call when actually expanding.
    var children: [TreeNodeItem] {
        let childIndices = tree.children(of: id).map { UInt32($0) }
        let sorted = childIndices.sorted(by: compare)
        return sorted.map {
            TreeNodeItem(id: $0, tree: tree, nodes: nodes, depth: depth + 1,
                         sortKey: sortKey, sortAscending: sortAscending)
        }
    }

    // MARK: - Sort Comparator

    private func compare(_ a: UInt32, _ b: UInt32) -> Bool {
        let ia = Int(a)
        let ib = Int(b)
        let nodeA = ia < nodes.count ? nodes[ia] : FileNode()
        let nodeB = ib < nodes.count ? nodes[ib] : FileNode()

        let cmp: Bool
        switch sortKey {
        case .name:
            cmp = tree.name(at: a).localizedCaseInsensitiveCompare(tree.name(at: b)) == .orderedAscending
        case .percentage, .size:
            cmp = nodeA.fileSize > nodeB.fileSize
        case .allocated:
            cmp = nodeA.allocatedSize > nodeB.allocatedSize
        case .items:
            cmp = nodeA.childCount > nodeB.childCount
        case .modified:
            cmp = nodeA.modifiedDate > nodeB.modifiedDate
        }
        return sortAscending ? !cmp : cmp
    }
}
