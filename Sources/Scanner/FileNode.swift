import Foundation

/// Compact flat-array tree node for filesystem representation.
/// Uses index-based parent/child references to avoid ARC overhead on millions of nodes.
/// ~48 bytes per node. 1M files ≈ 48 MB.
public struct FileNode: Sendable {
    public var nameOffset: UInt32
    public var nameLength: UInt16
    public var parentIndex: UInt32
    public var firstChildIndex: UInt32
    public var childCount: UInt32
    public var fileSize: UInt64
    public var allocatedSize: UInt64
    public var extensionHash: UInt32
    public var flags: UInt8
    public var modifiedDate: UInt32

    public static let invalid: UInt32 = UInt32.max

    public var isDirectory: Bool {
        get { flags & 1 != 0 }
        set {
            if newValue { flags |= 1 } else { flags &= ~1 }
        }
    }

    // Bit 1: node is a bundle (.app, .framework, etc.) and treated as an opaque leaf.
    public var isBundle: Bool {
        get { flags & 2 != 0 }
        set {
            if newValue { flags |= 2 } else { flags &= ~2 }
        }
    }

    public init(
        nameOffset: UInt32 = 0,
        nameLength: UInt16 = 0,
        parentIndex: UInt32 = FileNode.invalid,
        firstChildIndex: UInt32 = FileNode.invalid,
        childCount: UInt32 = 0,
        fileSize: UInt64 = 0,
        allocatedSize: UInt64 = 0,
        extensionHash: UInt32 = 0,
        flags: UInt8 = 0,
        modifiedDate: UInt32 = 0
    ) {
        self.nameOffset = nameOffset
        self.nameLength = nameLength
        self.parentIndex = parentIndex
        self.firstChildIndex = firstChildIndex
        self.childCount = childCount
        self.fileSize = fileSize
        self.allocatedSize = allocatedSize
        self.extensionHash = extensionHash
        self.flags = flags
        self.modifiedDate = modifiedDate
    }
}

/// Container for the flat-array tree + string pool.
/// Holds all filesystem scan results in a compact, cache-friendly format.
public final class FileTree: @unchecked Sendable {
    public private(set) var nodes: [FileNode] = []
    public private(set) var stringPool: Data = Data()
    // Pre-lowercased contiguous name buffer for cache-friendly scanning
    /// Full filesystem path of the scan root (set before scanning begins).
    /// Used by path(at:) to reconstruct correct absolute paths.
    public var rootPath: String = "/"
    private var lowercaseNamePool: Data = Data()
    private var lowercaseNameEntries: [(offset: UInt32, length: UInt16)] = []

    private let lock = NSLock()

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return nodes.count
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodes.isEmpty
    }

    public init() {
        nodes.reserveCapacity(500_000)
        stringPool.reserveCapacity(500_000 * 32)
        lowercaseNamePool.reserveCapacity(500_000 * 32)
        lowercaseNameEntries.reserveCapacity(500_000)
    }

    // MARK: - Thread-safe Reads

    /// Safely read a node by index. Returns nil if out of bounds.
    public func node(at index: UInt32) -> FileNode? {
        lock.lock()
        defer { lock.unlock() }
        let i = Int(index)
        guard i < nodes.count else { return nil }
        return nodes[i]
    }

    /// Snapshot the nodes array for lock-free layout computation.
    /// One lock acquisition instead of thousands during treemap layout.
    public func nodesSnapshot() -> [FileNode] {
        lock.lock()
        defer { lock.unlock() }
        return nodes
    }

    /// Snapshot the string pool for lock-free search.
    /// Data is CoW — O(1) unless mutated later.
    public func stringPoolSnapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stringPool
    }

    /// Snapshot the lowercase name pool + entries for lock-free search.
    public func searchIndexSnapshot() -> (pool: Data, entries: [(offset: UInt32, length: UInt16)]) {
        lock.lock()
        defer { lock.unlock() }
        return (lowercaseNamePool, lowercaseNameEntries)
    }

    // MARK: - String Pool

    public func name(at index: UInt32) -> String {
        lock.lock()
        defer { lock.unlock() }
        let i = Int(index)
        guard i < nodes.count else { return "" }
        let node = nodes[i]
        let start = Int(node.nameOffset)
        let end = start + Int(node.nameLength)
        guard end <= stringPool.count else { return "" }
        return String(data: stringPool[start..<end], encoding: .utf8) ?? ""
    }

    /// Build full path for a node by walking up the parent chain.
    /// Uses the stored `rootPath` to produce correct absolute paths
    /// regardless of whether the scan root is a volume root.
    public func path(at index: UInt32) -> String {
        lock.lock()
        defer { lock.unlock() }
        var components: [String] = []
        var current = index
        while current != FileNode.invalid {
            let i = Int(current)
            guard i < nodes.count else { break }
            let node = nodes[i]
            // Root node: use stored rootPath as prefix instead of node name.
            if node.parentIndex == FileNode.invalid { break }
            let start = Int(node.nameOffset)
            let end = start + Int(node.nameLength)
            if end <= stringPool.count {
                components.append(String(data: stringPool[start..<end], encoding: .utf8) ?? "")
            }
            current = node.parentIndex
        }
        let suffix = components.reversed().joined(separator: "/")
        if suffix.isEmpty { return rootPath }
        if rootPath.hasSuffix("/") { return rootPath + suffix }
        return rootPath + "/" + suffix
    }

    // MARK: - Children

    public func children(of index: UInt32) -> Range<Int> {
        lock.lock()
        defer { lock.unlock() }
        let i = Int(index)
        guard i < nodes.count else { return 0..<0 }
        let node = nodes[i]
        guard node.firstChildIndex != FileNode.invalid else { return 0..<0 }
        let start = Int(node.firstChildIndex)
        let end = min(start + Int(node.childCount), nodes.count)
        return start..<end
    }


    // MARK: - Thread-safe Mutation (used during scanning)

    @discardableResult
    public func addNode(_ node: FileNode, name: String) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let index = UInt32(nodes.count)
        var n = node
        let utf8 = Array(name.utf8)
        n.nameOffset = UInt32(stringPool.count)
        n.nameLength = UInt16(min(utf8.count, Int(UInt16.max)))
        stringPool.append(contentsOf: utf8)
        let lcOffset = UInt32(lowercaseNamePool.count)
        for byte in utf8 {
            lowercaseNamePool.append((byte >= 0x41 && byte <= 0x5A) ? (byte | 0x20) : byte)
        }
        lowercaseNameEntries.append((offset: lcOffset, length: UInt16(min(utf8.count, Int(UInt16.max)))))
        nodes.append(n)
        return index
    }

    /// Update a node at the given index (thread-safe).
    public func updateNode(at index: UInt32, _ mutate: (inout FileNode) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let i = Int(index)
        guard i < nodes.count else { return }
        mutate(&nodes[i])
    }

    /// Batch-add children for a parent. Returns the index of the first child.
    @discardableResult
    public func addChildren(_ children: [(node: FileNode, name: String)], parentIndex: UInt32) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let firstIndex = UInt32(nodes.count)
        for case (var node, let childName) in children {
            node.parentIndex = parentIndex
            let utf8 = Array(childName.utf8)
            node.nameOffset = UInt32(stringPool.count)
            node.nameLength = UInt16(min(utf8.count, Int(UInt16.max)))
            stringPool.append(contentsOf: utf8)
            let lcOffset = UInt32(lowercaseNamePool.count)
            for byte in utf8 {
                lowercaseNamePool.append((byte >= 0x41 && byte <= 0x5A) ? (byte | 0x20) : byte)
            }
            lowercaseNameEntries.append((offset: lcOffset, length: UInt16(min(utf8.count, Int(UInt16.max)))))
            nodes.append(node)
        }
        nodes[Int(parentIndex)].firstChildIndex = firstIndex
        nodes[Int(parentIndex)].childCount = UInt32(children.count)
        return firstIndex
    }

    /// Accumulate size up the parent chain (thread-safe with atomics approach via lock).
    public func accumulateSize(from index: UInt32, fileSize: UInt64, allocatedSize: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard Int(index) < nodes.count else { return }
        var current = nodes[Int(index)].parentIndex
        while current != FileNode.invalid {
            let ci = Int(current)
            guard ci < nodes.count else { break }
            nodes[ci].fileSize += fileSize
            nodes[ci].allocatedSize += allocatedSize
            current = nodes[ci].parentIndex
        }
    }

    /// Sort children of all directories by size descending, compacting the array.
    /// Also reorders lowercaseNameEntries to stay in sync with nodes,
    /// and fixes parentIndex pointers that become stale after reordering.
    public func sortAllChildren() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<nodes.count {
            guard nodes[i].isDirectory, nodes[i].childCount > 1 else { continue }
            let start = Int(nodes[i].firstChildIndex)
            let end = start + Int(nodes[i].childCount)
            guard end <= nodes.count, end <= lowercaseNameEntries.count else { continue }

            // Sort by size descending via index permutation.
            let perm = (start..<end).sorted { nodes[$0].fileSize > nodes[$1].fileSize }
            let sortedNodes = perm.map { nodes[$0] }
            let sortedEntries = perm.map { lowercaseNameEntries[$0] }
            for j in 0..<sortedNodes.count {
                nodes[start + j] = sortedNodes[j]
                lowercaseNameEntries[start + j] = sortedEntries[j]
            }
        }
        // Fix parentIndex on all children. After reordering, a child's parentIndex
        // may point to the wrong slot because its parent sibling was shuffled.
        // Each directory's firstChildIndex/childCount were carried with the node
        // so they're still correct — just walk all dirs and stamp children.
        for i in 0..<nodes.count {
            guard nodes[i].isDirectory, nodes[i].firstChildIndex != FileNode.invalid else { continue }
            let start = Int(nodes[i].firstChildIndex)
            let end = min(start + Int(nodes[i].childCount), nodes.count)
            for j in start..<end {
                nodes[j].parentIndex = UInt32(i)
            }
        }
    }
}

// MARK: - Extension Hash

public func extensionHash(_ name: String) -> UInt32 {
    guard let dotIndex = name.lastIndex(of: ".") else { return 0 }
    let ext = name[name.index(after: dotIndex)...].lowercased()
    guard !ext.isEmpty else { return 0 }
    var hash: UInt32 = 5381
    for byte in ext.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt32(byte)
    }
    return hash
}
