import Foundation
import Synchronization

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
///
/// `@unchecked Sendable` safety: all mutable state is behind a `Mutex`.
/// `rootPath` is set once before any concurrent access (in `FileScanner.scan()`
/// before `enqueueDirectory`) and never mutated again — reads via `path(at:)`
/// and `withCPath` occur under the lock where rootPath is captured.
/// Snapshot methods (`nodesSnapshot()`, `stringPoolSnapshot()`) return CoW copies
/// that are safe to use without the lock.
public final class FileTree: @unchecked Sendable {
    public private(set) var nodes: [FileNode] = []
    public private(set) var stringPool: Data = Data()
    /// Full filesystem path of the scan root.
    /// **Thread safety contract**: set once via `setRootPath(_:)` before any concurrent
    /// access begins (in `FileScanner.scan()`) and never mutated after. All reads occur
    /// under the lock where the value is captured, so no data race is possible.
    public private(set) var rootPath: String = "/"
    /// Whether the scanned volume is case-sensitive (e.g., case-sensitive APFS).
    /// When true, the search index stores original-case names instead of lowercased.
    public private(set) var isCaseSensitive: Bool = false
    private var lowercaseNamePool: Data = Data()
    private var lowercaseNameEntries: [(offset: UInt32, length: UInt16)] = []

    private let lock = Mutex(())

    public var count: Int {
        lock.withLock { _ in nodes.count }
    }

    public var isEmpty: Bool {
        lock.withLock { _ in nodes.isEmpty }
    }

    public init() {
        nodes.reserveCapacity(500_000)
        stringPool.reserveCapacity(500_000 * 32)
        lowercaseNamePool.reserveCapacity(500_000 * 32)
        lowercaseNameEntries.reserveCapacity(500_000)
    }

    /// Set the root path. Must be called exactly once, before concurrent access begins.
    public func setRootPath(_ path: String) {
        precondition(nodes.isEmpty, "setRootPath must be called before any nodes are added")
        rootPath = path
    }

    /// Set whether the volume is case-sensitive. Must be called before concurrent access begins.
    public func setCaseSensitivity(_ caseSensitive: Bool) {
        precondition(nodes.isEmpty, "setCaseSensitivity must be called before any nodes are added")
        isCaseSensitive = caseSensitive
    }

    // MARK: - Thread-safe Reads

    /// Safely read a node by index. Returns nil if out of bounds.
    public func node(at index: UInt32) -> FileNode? {
        lock.withLock { _ in
            let i = Int(index)
            guard i < nodes.count else { return nil }
            return nodes[i]
        }
    }

    /// Snapshot the nodes array for lock-free layout computation.
    /// One lock acquisition instead of thousands during treemap layout.
    public func nodesSnapshot() -> [FileNode] {
        lock.withLock { _ in nodes }
    }

    /// Snapshot the string pool for lock-free search.
    /// Data is CoW — O(1) unless mutated later.
    public func stringPoolSnapshot() -> Data {
        lock.withLock { _ in stringPool }
    }

    /// Snapshot all data needed for lock-free path building in a single lock acquisition.
    /// Used by RecencyQueryService and other batch operations to avoid per-call locking.
    public func pathBuildingSnapshot() -> (nodes: [FileNode], stringPool: Data, rootPath: String) {
        lock.withLock { _ in (nodes, stringPool, rootPath) }
    }

    /// Build a path lock-free from pre-snapshotted data.
    /// Avoids per-call lock acquisition when building many paths (e.g., RecencyQueryService).
    public static func pathFromSnapshot(
        at index: UInt32,
        nodes: [FileNode],
        stringPool: Data,
        rootPath: String
    ) -> String {
        var components: [String] = []
        var current = index
        while current != FileNode.invalid {
            let i = Int(current)
            guard i < nodes.count else { break }
            let node = nodes[i]
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

    /// Snapshot the lowercase name pool + entries for lock-free search.
    public func searchIndexSnapshot() -> (pool: Data, entries: [(offset: UInt32, length: UInt16)]) {
        lock.withLock { _ in (lowercaseNamePool, lowercaseNameEntries) }
    }

    // MARK: - String Pool

    public func name(at index: UInt32) -> String {
        lock.withLock { _ in
            let i = Int(index)
            guard i < nodes.count else { return "" }
            let node = nodes[i]
            let start = Int(node.nameOffset)
            let end = start + Int(node.nameLength)
            guard end <= stringPool.count else { return "" }
            return String(data: stringPool[start..<end], encoding: .utf8) ?? ""
        }
    }

    /// Build full path for a node by walking up the parent chain.
    /// Uses the stored `rootPath` to produce correct absolute paths
    /// regardless of whether the scan root is a volume root.
    public func path(at index: UInt32) -> String {
        lock.withLock { _ in
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
    }

    /// Build an absolute path as a null-terminated C string directly from the byte pool,
    /// avoiding intermediate Swift String allocations. Useful for high-throughput I/O
    /// (e.g., duplicate file hashing) where thousands of paths are opened in sequence.
    /// The closure receives a pointer valid only for its duration.
    public func withCPath<R>(at index: UInt32, _ body: (UnsafePointer<CChar>) -> R) -> R {
        // Build path bytes under the lock, then call body outside the lock
        // so that file I/O doesn't block tree access.
        let buf: ContiguousArray<CChar> = lock.withLock { _ in
            var segments: [(offset: Int, length: Int)] = []
            var current = index
            while current != FileNode.invalid {
                let i = Int(current)
                guard i < nodes.count else { break }
                let node = nodes[i]
                if node.parentIndex == FileNode.invalid { break }
                segments.append((Int(node.nameOffset), Int(node.nameLength)))
                current = node.parentIndex
            }

            // Use withCString on rootPath to safely convert to C bytes,
            // avoiding manual UTF-8 iteration on potentially non-ASCII paths.
            var buf = ContiguousArray<CChar>()
            buf.reserveCapacity(256)
            rootPath.withCString { cstr in
                var p = cstr
                while p.pointee != 0 {
                    buf.append(p.pointee)
                    p += 1
                }
            }
            for seg in segments.reversed() {
                if !buf.isEmpty, buf.last != CChar(bitPattern: UInt8(ascii: "/")) {
                    buf.append(CChar(bitPattern: UInt8(ascii: "/")))
                }
                let start = seg.offset
                let end = start + seg.length
                if end <= stringPool.count {
                    stringPool.withUnsafeBytes { pool in
                        let src = pool.baseAddress!.advanced(by: start)
                        for j in 0..<seg.length {
                            buf.append(CChar(bitPattern: src.load(fromByteOffset: j, as: UInt8.self)))
                        }
                    }
                }
            }
            buf.append(0) // null terminator
            return buf
        }
        return buf.withUnsafeBufferPointer { ptr in
            body(ptr.baseAddress!)
        }
    }

    // MARK: - Children

    public func children(of index: UInt32) -> Range<Int> {
        lock.withLock { _ in
            let i = Int(index)
            guard i < nodes.count else { return 0..<0 }
            let node = nodes[i]
            guard node.firstChildIndex != FileNode.invalid else { return 0..<0 }
            let start = Int(node.firstChildIndex)
            let end = min(start + Int(node.childCount), nodes.count)
            return start..<end
        }
    }


    // MARK: - Thread-safe Mutation (used during scanning)

    @discardableResult
    public func addNode(_ node: FileNode, name: String) -> UInt32 {
        lock.withLock { _ in
            let index = UInt32(nodes.count)
            var n = node
            let utf8 = Array(name.utf8)
            n.nameOffset = UInt32(stringPool.count)
            n.nameLength = UInt16(min(utf8.count, Int(UInt16.max)))
            stringPool.append(contentsOf: utf8)
            // Build the search-index entry. On case-insensitive volumes, use Unicode-aware
            // lowercasing so that Ü→ü, É→é, etc. are searchable. On case-sensitive volumes,
            // store the original name to avoid merging directories that differ only in case.
            let lcOffset = UInt32(lowercaseNamePool.count)
            let lcUTF8 = isCaseSensitive ? utf8 : Array(name.lowercased().utf8)
            lowercaseNamePool.append(contentsOf: lcUTF8)
            lowercaseNameEntries.append((offset: lcOffset, length: UInt16(min(lcUTF8.count, Int(UInt16.max)))))
            nodes.append(n)
            return index
        }
    }

    /// Update a node at the given index (thread-safe).
    public func updateNode(at index: UInt32, _ mutate: (inout FileNode) -> Void) {
        lock.withLock { _ in
            let i = Int(index)
            guard i < nodes.count else { return }
            mutate(&nodes[i])
        }
    }

    /// Batch-add children for a parent. Returns the index of the first child.
    @discardableResult
    public func addChildren(_ children: [(node: FileNode, name: String)], parentIndex: UInt32) -> UInt32 {
        lock.withLock { _ in
            let p = Int(parentIndex)
            guard p >= 0, p < nodes.count else { return UInt32(nodes.count) }
            let firstIndex = UInt32(nodes.count)
            for case (var node, let childName) in children {
                node.parentIndex = parentIndex
                let utf8 = Array(childName.utf8)
                node.nameOffset = UInt32(stringPool.count)
                node.nameLength = UInt16(min(utf8.count, Int(UInt16.max)))
                stringPool.append(contentsOf: utf8)
                let lcOffset = UInt32(lowercaseNamePool.count)
                let lcUTF8 = isCaseSensitive ? utf8 : Array(childName.lowercased().utf8)
                lowercaseNamePool.append(contentsOf: lcUTF8)
                lowercaseNameEntries.append((offset: lcOffset, length: UInt16(min(lcUTF8.count, Int(UInt16.max)))))
                nodes.append(node)
            }
            nodes[p].firstChildIndex = firstIndex
            nodes[p].childCount = UInt32(children.count)
            return firstIndex
        }
    }

    /// Accumulate size up the parent chain (thread-safe with atomics approach via lock).
    /// Note: For bulk scanning, prefer propagateSizes() after all nodes are added — it's O(n)
    /// with a single pass and avoids lock contention from 32 concurrent threads.
    public func accumulateSize(from index: UInt32, fileSize: UInt64, allocatedSize: UInt64) {
        lock.withLock { _ in
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
    }

    /// Single-pass bottom-up size propagation. Call after all nodes are added (post-scan).
    /// Each node's fileSize starts as its own direct size. This walk adds each node's size
    /// to its parent, naturally bubbling totals up to the root in O(n) time.
    /// Replaces thousands of per-directory accumulateSize() calls that each walk the full
    /// parent chain under lock contention.
    public func propagateSizes() {
        lock.withLock { _ in
            for i in stride(from: nodes.count - 1, through: 0, by: -1) {
                let parentIdx = Int(nodes[i].parentIndex)
                guard nodes[i].parentIndex != FileNode.invalid, parentIdx < nodes.count else { continue }
                nodes[parentIdx].fileSize += nodes[i].fileSize
                nodes[parentIdx].allocatedSize += nodes[i].allocatedSize
            }
        }
    }

    /// Sort children of all directories by size descending, compacting the array.
    /// Also reorders lowercaseNameEntries to stay in sync with nodes,
    /// and fixes parentIndex pointers that become stale after reordering.
    ///
    /// **Correctness invariant**: each directory's child slice `[firstChildIndex..<firstChildIndex+childCount]`
    /// is contiguous and non-overlapping with every other directory's slice (guaranteed by `addChildren`
    /// which appends children in a single batch). Sorting within a slice only permutes elements within
    /// that slice — no other directory's indices are affected. `firstChildIndex` and `childCount` travel
    /// with the node during permutation, so they remain valid. The second pass stamps all children's
    /// `parentIndex` to fix the only field that becomes stale (a child's parent may have moved within
    /// *its* parent's slice).
    public func sortAllChildren() {
        lock.withLock { _ in
            for i in 0..<nodes.count {
                guard nodes[i].isDirectory, nodes[i].childCount > 1 else { continue }
                let start = Int(nodes[i].firstChildIndex)
                let end = start + Int(nodes[i].childCount)
                guard end <= nodes.count, end <= lowercaseNameEntries.count else { continue }

                // Sort by size descending via index permutation, then apply in-place
                // using cycle sort to avoid allocating temporary copies of nodes/entries.
                let perm = (start..<end).sorted { nodes[$0].fileSize > nodes[$1].fileSize }
                var localPerm = perm.map { $0 - start }
                for k in 0..<localPerm.count {
                    var j = localPerm[k]
                    if j == k { continue } // already in place
                    while j != k {
                        nodes.swapAt(start + k, start + j)
                        lowercaseNameEntries.swapAt(start + k, start + j)
                        let next = localPerm[j]
                        localPerm[j] = j // mark as done
                        j = next
                    }
                    localPerm[k] = k
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
