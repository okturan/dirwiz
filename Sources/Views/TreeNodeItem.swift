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
struct TreeNodeItem: Identifiable, Equatable {
    static func == (lhs: TreeNodeItem, rhs: TreeNodeItem) -> Bool {
        lhs.id == rhs.id && lhs.depth == rhs.depth
    }

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

    /// Whether this directory has any children.
    /// Uses pre-snapshotted node fields to avoid a lock acquisition per row.
    var hasChildren: Bool {
        let n = node
        guard n.isDirectory, !n.isBundle else { return false }
        return n.childCount > 0 && n.firstChildIndex != FileNode.invalid
    }

    /// Sorted children — only call when actually expanding.
    var children: [TreeNodeItem] {
        let range = tree.children(of: id)
        let sorted: [UInt32]
        switch sortKey {
        case .size, .percentage:
            // FileTree.sortAllChildren() pre-sorted children by size descending — reuse it.
            let forward = range.map { UInt32($0) }
            sorted = sortAscending ? Array(forward.reversed()) : forward
        default:
            sorted = range.map { UInt32($0) }.sorted(by: compare)
        }
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

        switch sortKey {
        case .name:
            let order = tree.name(at: a).localizedCaseInsensitiveCompare(tree.name(at: b))
            if order != .orderedSame {
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
        case .percentage, .size:
            if nodeA.fileSize != nodeB.fileSize {
                return sortAscending ? nodeA.fileSize < nodeB.fileSize : nodeA.fileSize > nodeB.fileSize
            }
        case .allocated:
            if nodeA.allocatedSize != nodeB.allocatedSize {
                return sortAscending
                    ? nodeA.allocatedSize < nodeB.allocatedSize
                    : nodeA.allocatedSize > nodeB.allocatedSize
            }
        case .items:
            if nodeA.childCount != nodeB.childCount {
                return sortAscending ? nodeA.childCount < nodeB.childCount : nodeA.childCount > nodeB.childCount
            }
        case .modified:
            if nodeA.modifiedDate != nodeB.modifiedDate {
                return sortAscending ? nodeA.modifiedDate < nodeB.modifiedDate : nodeA.modifiedDate > nodeB.modifiedDate
            }
        }
        // Deterministic tie-breaker to satisfy strict weak ordering.
        return a < b
    }
}
