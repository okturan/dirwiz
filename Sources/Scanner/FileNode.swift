import Foundation
import Synchronization

private enum FileNodeFlags {
    static let isDirectory: UInt8 = 1
    static let isBundle: UInt8 = 2
}

/// Compact flat-array tree node for filesystem representation.
/// Uses index-based parent/child references to avoid ARC overhead on millions of nodes.
/// Keeps lightweight metadata needed by multiple analysis passes in a single cache-friendly struct.
public struct FileNode: Sendable {
    public var nameOffset: UInt32
    public var nameLength: UInt16
    public var parentIndex: UInt32
    public var firstChildIndex: UInt32
    public var childCount: UInt32
    public var fileSize: UInt64
    public var allocatedSize: UInt64
    public var inode: UInt64
    public var extensionHash: UInt32
    private var deviceID: UInt32
    public var flags: UInt8
    public var modifiedDate: UInt32

    public static let invalid: UInt32 = UInt32.max

    /// On-disk size for display and treemap layout: allocated blocks when reported by the
    /// filesystem (accurate for APFS compression, sparse files, etc.), falling back to the
    /// logical data length if allocatedSize is zero (e.g. a node that hasn't been flushed).
    /// Use this everywhere a size is shown to the user. Keep fileSize for duplicate detection
    /// and temporal diff, where logical content equality matters.
    public var displaySize: UInt64 {
        allocatedSize > 0 ? allocatedSize : fileSize
    }

    public var isDirectory: Bool {
        get { flags & FileNodeFlags.isDirectory != 0 }
        set {
            if newValue { flags |= FileNodeFlags.isDirectory } else { flags &= ~FileNodeFlags.isDirectory }
        }
    }

    // Bit 1: node is a bundle (.app, .framework, etc.) and treated as an opaque leaf.
    public var isBundle: Bool {
        get { flags & FileNodeFlags.isBundle != 0 }
        set {
            if newValue { flags |= FileNodeFlags.isBundle } else { flags &= ~FileNodeFlags.isBundle }
        }
    }

    public var device: Int32 {
        get { Int32(bitPattern: deviceID) }
        set { deviceID = UInt32(bitPattern: newValue) }
    }

    public init(
        nameOffset: UInt32 = 0,
        nameLength: UInt16 = 0,
        parentIndex: UInt32 = FileNode.invalid,
        firstChildIndex: UInt32 = FileNode.invalid,
        childCount: UInt32 = 0,
        fileSize: UInt64 = 0,
        allocatedSize: UInt64 = 0,
        inode: UInt64 = 0,
        extensionHash: UInt32 = 0,
        device: Int32 = 0,
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
        self.inode = inode
        self.extensionHash = extensionHash
        self.deviceID = UInt32(bitPattern: device)
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

    /// Build an absolute path as a null-terminated C string from a pre-snapshotted tree.
    /// This avoids taking the tree lock in high-throughput callers that already have a snapshot.
    public static func withCPathFromSnapshot<R>(
        at index: UInt32,
        nodes: [FileNode],
        stringPool: Data,
        rootPath: String,
        _ body: (UnsafePointer<CChar>) -> R
    ) -> R {
        var segments: [(offset: Int, length: Int)] = []
        var totalSegmentBytes = 0
        var current = index
        while current != FileNode.invalid {
            let i = Int(current)
            guard i < nodes.count else { break }
            let node = nodes[i]
            if node.parentIndex == FileNode.invalid { break }
            let segment = (offset: Int(node.nameOffset), length: Int(node.nameLength))
            segments.append(segment)
            totalSegmentBytes += segment.length
            current = node.parentIndex
        }

        let slash = CChar(bitPattern: UInt8(ascii: "/"))
        var buf = ContiguousArray<CChar>()
        buf.reserveCapacity(rootPath.utf8.count + totalSegmentBytes + segments.count + 1)

        rootPath.withCString { cstr in
            var p = cstr
            while p.pointee != 0 {
                buf.append(p.pointee)
                p += 1
            }
        }

        stringPool.withUnsafeBytes { pool in
            let base = pool.baseAddress?.assumingMemoryBound(to: UInt8.self)
            for seg in segments.reversed() {
                if !buf.isEmpty, buf.last != slash {
                    buf.append(slash)
                }
                guard let base else { continue }
                for j in 0..<seg.length {
                    buf.append(CChar(bitPattern: base[seg.offset + j]))
                }
            }
        }

        buf.append(0)
        return buf.withUnsafeBufferPointer { ptr in
            body(ptr.baseAddress!)
        }
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
        let snapshot = lock.withLock { _ in (nodes, stringPool, rootPath) }
        return Self.withCPathFromSnapshot(
            at: index,
            nodes: snapshot.0,
            stringPool: snapshot.1,
            rootPath: snapshot.2,
            body
        )
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
            // Build the search-index entry: NFC-normalize then lowercase so that
            // composed "Café" and decomposed "Cafe\u{301}" both index identically,
            // and uppercase names are found by lowercase queries on any volume.
            let lcOffset = UInt32(lowercaseNamePool.count)
            let lcUTF8 = Array(name.precomposedStringWithCanonicalMapping.lowercased().utf8)
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
                let lcUTF8 = Array(childName.precomposedStringWithCanonicalMapping.lowercased().utf8)
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

    /// Zero a node's sizes and subtract the freed amount from all ancestors.
    /// Used after trashing a file to keep the tree consistent without a full re-scan.
    public func zeroNodeSize(at index: UInt32) {
        lock.withLock { _ in
            let i = Int(index)
            guard i < nodes.count else { return }
            let oldSize = nodes[i].displaySize
            nodes[i].fileSize = 0
            nodes[i].allocatedSize = 0
            var current = nodes[i].parentIndex
            while current != FileNode.invalid {
                let ci = Int(current)
                guard ci < nodes.count else { break }
                if nodes[ci].fileSize >= oldSize {
                    nodes[ci].fileSize -= oldSize
                } else {
                    nodes[ci].fileSize = 0
                }
                if nodes[ci].allocatedSize >= oldSize {
                    nodes[ci].allocatedSize -= oldSize
                } else {
                    nodes[ci].allocatedSize = 0
                }
                current = nodes[ci].parentIndex
            }
        }
    }

    /// Remove a node and all descendants, then rebuild parent/child links and aggregate sizes.
    /// Keeps the root node in place if asked to remove index 0 so the tree remains usable.
    public func removeSubtree(at index: UInt32) {
        lock.withLock { _ in
            let removeIndex = Int(index)
            guard removeIndex >= 0, removeIndex < nodes.count else { return }

            if removeIndex == 0 {
                guard !nodes.isEmpty else { return }
                var root = nodes[0]
                root.firstChildIndex = FileNode.invalid
                root.childCount = 0
                root.fileSize = 0
                root.allocatedSize = 0
                nodes = [root]
                return
            }

            var removed = Set<UInt32>()
            var stack: [UInt32] = [index]
            while let current = stack.popLast() {
                guard removed.insert(current).inserted else { continue }
                let i = Int(current)
                guard i < nodes.count else { continue }
                let node = nodes[i]
                guard node.firstChildIndex != FileNode.invalid else { continue }
                let start = Int(node.firstChildIndex)
                let end = min(start + Int(node.childCount), nodes.count)
                for child in start..<end {
                    stack.append(UInt32(child))
                }
            }

            guard !removed.isEmpty else { return }

            let oldNodes = nodes
            let oldStringPool = stringPool
            let oldSearchPool = lowercaseNamePool
            let oldSearchEntries = lowercaseNameEntries

            var oldToNew = Array(repeating: FileNode.invalid, count: oldNodes.count)
            var newNodes: [FileNode] = []
            var newStringPool = Data()
            var newSearchPool = Data()
            var newSearchEntries: [(offset: UInt32, length: UInt16)] = []

            newNodes.reserveCapacity(oldNodes.count - removed.count)
            newStringPool.reserveCapacity(oldStringPool.count)
            newSearchPool.reserveCapacity(oldSearchPool.count)
            newSearchEntries.reserveCapacity(oldSearchEntries.count - removed.count)

            for oldIndex in oldNodes.indices {
                let oldUInt = UInt32(oldIndex)
                guard !removed.contains(oldUInt) else { continue }

                var node = oldNodes[oldIndex]

                let nameStart = Int(node.nameOffset)
                let nameEnd = nameStart + Int(node.nameLength)
                guard nameEnd <= oldStringPool.count else { continue }
                let nameBytes = oldStringPool[nameStart..<nameEnd]
                node.nameOffset = UInt32(newStringPool.count)
                node.nameLength = UInt16(nameBytes.count)
                newStringPool.append(contentsOf: nameBytes)

                let searchEntry = oldSearchEntries[oldIndex]
                let searchStart = Int(searchEntry.offset)
                let searchEnd = searchStart + Int(searchEntry.length)
                guard searchEnd <= oldSearchPool.count else { continue }
                let searchBytes = oldSearchPool[searchStart..<searchEnd]
                let newSearchOffset = UInt32(newSearchPool.count)
                newSearchPool.append(contentsOf: searchBytes)
                newSearchEntries.append((offset: newSearchOffset, length: searchEntry.length))

                node.parentIndex = FileNode.invalid
                node.firstChildIndex = FileNode.invalid
                node.childCount = 0
                if node.isDirectory && !node.isBundle {
                    node.fileSize = 0
                    node.allocatedSize = 0
                }

                oldToNew[oldIndex] = UInt32(newNodes.count)
                newNodes.append(node)
            }

            for oldIndex in oldNodes.indices {
                let newIndex = oldToNew[oldIndex]
                guard newIndex != FileNode.invalid else { continue }
                let oldParent = oldNodes[oldIndex].parentIndex
                guard oldParent != FileNode.invalid else { continue }
                let newParent = oldToNew[Int(oldParent)]
                guard newParent != FileNode.invalid else { continue }

                let parentIndex = Int(newParent)
                let childIndex = Int(newIndex)
                newNodes[childIndex].parentIndex = newParent
                if newNodes[parentIndex].firstChildIndex == FileNode.invalid {
                    newNodes[parentIndex].firstChildIndex = newIndex
                }
                newNodes[parentIndex].childCount &+= 1
            }

            for i in stride(from: newNodes.count - 1, through: 0, by: -1) {
                let parent = newNodes[i].parentIndex
                guard parent != FileNode.invalid else { continue }
                let parentIndex = Int(parent)
                newNodes[parentIndex].fileSize += newNodes[i].fileSize
                newNodes[parentIndex].allocatedSize += newNodes[i].allocatedSize
            }

            nodes = newNodes
            stringPool = newStringPool
            lowercaseNamePool = newSearchPool
            lowercaseNameEntries = newSearchEntries
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
                // using cycle-following on the src→dst mapping.
                //
                // perm[i] = absolute index of the element that belongs at position (start+i).
                // This is a dst→src map; we invert it to src→dst so we can follow cycles
                // by always swapping element i with its final destination.
                let perm = (start..<end).sorted { nodes[$0].fileSize > nodes[$1].fileSize }
                var dest = [Int](repeating: 0, count: perm.count)
                for i in 0..<perm.count {
                    dest[perm[i] - start] = i   // element at relative pos j goes to pos i
                }
                var i = 0
                while i < dest.count {
                    let target = dest[i]
                    if target != i {
                        nodes.swapAt(start + i, start + target)
                        lowercaseNameEntries.swapAt(start + i, start + target)
                        dest.swapAt(i, target)  // element at i is now at target; update
                    } else {
                        i += 1
                    }
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
