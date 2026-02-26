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
    case reclaimScore
}

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
        guard !node.isBundle else { return false }
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

    // MARK: - Sort Comparator

    private func compare(_ a: UInt32, _ b: UInt32) -> Bool {
        let nodeA = tree.node(at: a) ?? FileNode()
        let nodeB = tree.node(at: b) ?? FileNode()

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
        case .reclaimScore:
            let scoreA = Int(a) < reclaimScores.count ? reclaimScores[Int(a)] : 0
            let scoreB = Int(b) < reclaimScores.count ? reclaimScores[Int(b)] : 0
            cmp = scoreA > scoreB
        }
        return sortAscending ? !cmp : cmp
    }
}
