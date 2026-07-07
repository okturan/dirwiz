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

struct EncodedFileNode: Sendable {
    var node: FileNode
    var nameOffset: Int
    var nameLength: Int
}

struct IndexedEncodedFileNode: Sendable {
    var index: UInt32
    var node: FileNode
    var nameOffset: Int
    var nameLength: Int
}

struct FileTreeArena: Sendable {
    var nodes: [IndexedEncodedFileNode]
    var namePool: Data
}

struct BundleSizeCandidate: Sendable {
    let index: UInt32
    let path: String
    let device: Int32
    let inode: UInt64
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
    private var isSearchIndexBuilt = false

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

    /// The root node's on-disk size, read under the lock. Use this instead of a raw
    /// `nodes.first?.displaySize` — the root can be mutated concurrently by deferred
    /// bundle sizing or trash operations.
    public var rootDisplaySize: UInt64 {
        lock.withLock { _ in nodes.first?.displaySize ?? 0 }
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

    /// Iterate non-directory nodes of a snapshot with a uniform cancellation cadence.
    /// Returns false if cancelled (caller should treat this as "produced nothing usable").
    /// This is the single blessed walk for post-scan analyzers (file age, size distribution,
    /// etc.) — new analyzers that need to visit every file should use this instead of a
    /// fresh hand-rolled loop.
    public static func forEachFileInSnapshot(
        _ nodes: [FileNode],
        cancelEvery: Int = 0x10000,
        _ body: (Int, FileNode) -> Void
    ) -> Bool {
        let cadence = max(cancelEvery, 1)
        for i in 0..<nodes.count {
            if i % cadence == 0, Task.isCancelled { return false }
            let node = nodes[i]
            if node.isDirectory { continue }
            body(i, node)
        }
        return true
    }

    /// Locate a node by descending named path components from the root of a snapshot,
    /// matching one component per tree level against child names (no path strings built).
    /// Returns nil as soon as a component has no matching child. An empty `components`
    /// array returns the root (index 0).
    ///
    /// Adapted from the technique in `TreeActions.findNodeIndex`, decoupled from stripping
    /// an absolute path's `rootPath` prefix — callers that start from an absolute path derive
    /// the relative components themselves.
    public static func descendPath(
        _ components: [String],
        nodes: [FileNode],
        stringPool: Data
    ) -> UInt32? {
        guard !nodes.isEmpty else { return nil }
        var currentIndex: UInt32 = 0

        for component in components {
            let node = nodes[Int(currentIndex)]
            guard node.firstChildIndex != FileNode.invalid else { return nil }
            let childStart = Int(node.firstChildIndex)
            let childEnd = min(childStart + Int(node.childCount), nodes.count)
            var found = false
            for ci in childStart..<childEnd {
                let child = nodes[ci]
                let start = Int(child.nameOffset)
                let end = start + Int(child.nameLength)
                guard end <= stringPool.count else { continue }
                let name = String(data: stringPool[start..<end], encoding: .utf8) ?? ""
                if name == component {
                    currentIndex = UInt32(ci)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }
        return currentIndex
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
        let poolCount = stringPool.count
        var current = index
        while current != FileNode.invalid {
            let i = Int(current)
            guard i < nodes.count else { break }
            let node = nodes[i]
            if node.parentIndex == FileNode.invalid { break }
            let offset = Int(node.nameOffset)
            let length = Int(node.nameLength)
            let end = offset + length
            if offset <= poolCount, end <= poolCount {
                let segment = (offset: offset, length: length)
                segments.append(segment)
                totalSegmentBytes += segment.length
            }
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
            guard let baseAddress = ptr.baseAddress else {
                var terminator = CChar(0)
                return withUnsafePointer(to: &terminator) { zeroPointer in
                    body(zeroPointer)
                }
            }
            return body(baseAddress)
        }
    }

    /// Snapshot the lowercase name pool + entries for lock-free search.
    public func searchIndexSnapshot() -> (pool: Data, entries: [(offset: UInt32, length: UInt16)]) {
        lock.withLock { _ in
            rebuildSearchIndexIfNeeded()
            return (lowercaseNamePool, lowercaseNameEntries)
        }
    }

    private func rebuildSearchIndexIfNeeded() {
        guard !isSearchIndexBuilt else { return }

        lowercaseNamePool.removeAll(keepingCapacity: true)
        lowercaseNameEntries.removeAll(keepingCapacity: true)
        lowercaseNamePool.reserveCapacity(stringPool.count)
        lowercaseNameEntries.reserveCapacity(nodes.count)

        stringPool.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                for _ in nodes {
                    lowercaseNameEntries.append((offset: UInt32(lowercaseNamePool.count), length: 0))
                }
                return
            }

            let poolCount = rawBuffer.count
            for node in nodes {
                let nameOffset = Int(node.nameOffset)
                let nameLength = Int(node.nameLength)
                let nameEnd = nameOffset + nameLength
                let searchOffset = UInt32(lowercaseNamePool.count)
                guard nameOffset >= 0, nameEnd <= poolCount else {
                    lowercaseNameEntries.append((offset: searchOffset, length: 0))
                    continue
                }

                var isASCII = true
                for i in 0..<nameLength {
                    if base[nameOffset + i] >= 0x80 {
                        isASCII = false
                        break
                    }
                }

                if isASCII {
                    for i in 0..<nameLength {
                        let byte = base[nameOffset + i]
                        if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") {
                            lowercaseNamePool.append(byte + 32)
                        } else {
                            lowercaseNamePool.append(byte)
                        }
                    }
                } else {
                    let nameBytes = UnsafeBufferPointer(start: base + nameOffset, count: nameLength)
                    let name = String(decoding: nameBytes, as: UTF8.self)
                    let searchName = name.precomposedStringWithCanonicalMapping.lowercased()
                    lowercaseNamePool.append(contentsOf: searchName.utf8)
                }

                let searchLength = min(lowercaseNamePool.count - Int(searchOffset), Int(UInt16.max))
                lowercaseNameEntries.append((offset: searchOffset, length: UInt16(searchLength)))
            }
        }

        isSearchIndexBuilt = true
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

    /// Return only the bundle leaves that need deferred size resolution.
    ///
    /// This intentionally does not expose or retain a whole-tree snapshot. Holding a
    /// CoW snapshot while later mutating bundle sizes can force a full nodes-array copy
    /// on large scans.
    func bundleSizeCandidates() -> [BundleSizeCandidate] {
        lock.withLock { _ in
            var candidates: [BundleSizeCandidate] = []
            candidates.reserveCapacity(min(nodes.count / 64, 4096))

            for i in nodes.indices {
                let node = nodes[i]
                guard node.isBundle else { continue }
                let index = UInt32(i)
                candidates.append(BundleSizeCandidate(
                    index: index,
                    path: Self.pathFromSnapshot(
                        at: index,
                        nodes: nodes,
                        stringPool: stringPool,
                        rootPath: rootPath
                    ),
                    device: node.device,
                    inode: node.inode
                ))
            }

            return candidates
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

    private func appendName(for name: String, to node: inout FileNode) {
        node.nameOffset = UInt32(stringPool.count)
        let nameLength = min(name.utf8.count, Int(UInt16.max))
        node.nameLength = UInt16(nameLength)
        stringPool.append(contentsOf: name.utf8)
        isSearchIndexBuilt = false
    }

    @discardableResult
    public func addNode(_ node: FileNode, name: String) -> UInt32 {
        lock.withLock { _ in
            let index = UInt32(nodes.count)
            var n = node
            appendName(for: name, to: &n)
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

    /// Set a leaf node's direct size and apply the size delta to all ancestors.
    ///
    /// Deferred bundle sizing uses this after the initial scan has already propagated
    /// sizes. Bundle nodes are opaque leaves, so changing the node and bubbling the
    /// exact delta preserves aggregate directory totals without rebuilding the tree.
    @discardableResult
    public func setNodeSizeAndPropagate(
        at index: UInt32,
        fileSize: UInt64,
        allocatedSize: UInt64,
        expectedDevice: Int32? = nil,
        expectedInode: UInt64? = nil
    ) -> Bool {
        lock.withLock { _ in
            let i = Int(index)
            guard i < nodes.count else { return false }
            if let expectedDevice, nodes[i].device != expectedDevice {
                return false
            }
            if let expectedInode, nodes[i].inode != expectedInode {
                return false
            }

            let oldFileSize = nodes[i].fileSize
            let oldAllocatedSize = nodes[i].allocatedSize
            nodes[i].fileSize = fileSize
            nodes[i].allocatedSize = allocatedSize

            func applyDelta(_ value: inout UInt64, from oldValue: UInt64, to newValue: UInt64) {
                if newValue >= oldValue {
                    let delta = newValue - oldValue
                    let result = value.addingReportingOverflow(delta)
                    value = result.overflow ? UInt64.max : result.partialValue
                } else {
                    let delta = oldValue - newValue
                    value = value >= delta ? value - delta : 0
                }
            }

            var current = nodes[i].parentIndex
            while current != FileNode.invalid {
                let ci = Int(current)
                guard ci < nodes.count else { break }
                applyDelta(&nodes[ci].fileSize, from: oldFileSize, to: fileSize)
                applyDelta(&nodes[ci].allocatedSize, from: oldAllocatedSize, to: allocatedSize)
                current = nodes[ci].parentIndex
            }
            return true
        }
    }

    /// Replace the whole tree from deferred scanner arenas.
    ///
    /// Production scans can assign stable global node indices while walking the filesystem,
    /// store nodes in worker-local arenas, then materialize the flat tree once. This preserves
    /// the same final representation as `addChildren` while avoiding a global tree lock on
    /// every scanned directory.
    func replaceContents(
        rootNode: FileNode,
        rootName: String,
        childRanges: [UInt32: (first: UInt32, count: UInt32)],
        arenas: [FileTreeArena],
        totalNodeCount: Int
    ) {
        lock.withLock { _ in
            let nodeCount = max(1, totalNodeCount)
            var rebuiltNodes = Array(repeating: FileNode(), count: nodeCount)
            var rebuiltStringPool = Data()
            let estimatedNameBytes = arenas.reduce(rootName.utf8.count) { partial, arena in
                partial + arena.namePool.count
            }
            rebuiltStringPool.reserveCapacity(estimatedNameBytes)

            func appendNameBytes(_ bytes: UnsafeBufferPointer<UInt8>, to node: inout FileNode) {
                node.nameOffset = UInt32(clamping: rebuiltStringPool.count)
                let length = min(bytes.count, Int(UInt16.max))
                node.nameLength = UInt16(length)
                if let base = bytes.baseAddress, length > 0 {
                    rebuiltStringPool.append(contentsOf: UnsafeBufferPointer(start: base, count: length))
                }
            }

            var root = rootNode
            root.parentIndex = FileNode.invalid
            root.firstChildIndex = FileNode.invalid
            root.childCount = 0
            root.nameOffset = UInt32(clamping: rebuiltStringPool.count)
            let rootNameBytes = Array(rootName.utf8.prefix(Int(UInt16.max)))
            root.nameLength = UInt16(rootNameBytes.count)
            if !rootNameBytes.isEmpty {
                rebuiltStringPool.append(contentsOf: rootNameBytes)
            }
            rebuiltNodes[0] = root

            for arena in arenas {
                arena.namePool.withUnsafeBytes { rawPool in
                    let pool = rawPool.bindMemory(to: UInt8.self)
                    for encoded in arena.nodes {
                        let nodeIndex = Int(encoded.index)
                        guard nodeIndex > 0, nodeIndex < rebuiltNodes.count else { continue }

                        var node = encoded.node
                        node.firstChildIndex = FileNode.invalid
                        node.childCount = 0

                        let offset = encoded.nameOffset
                        let available = offset >= 0 && offset < pool.count
                            ? min(encoded.nameLength, pool.count - offset)
                            : 0
                        if let base = pool.baseAddress, available > 0 {
                            appendNameBytes(
                                UnsafeBufferPointer(start: base.advanced(by: offset), count: available),
                                to: &node
                            )
                        } else {
                            node.nameOffset = UInt32(clamping: rebuiltStringPool.count)
                            node.nameLength = 0
                        }

                        rebuiltNodes[nodeIndex] = node
                    }
                }
            }

            for (parent, range) in childRanges {
                let parentIndex = Int(parent)
                guard parentIndex >= 0, parentIndex < rebuiltNodes.count else { continue }
                rebuiltNodes[parentIndex].firstChildIndex = range.first
                rebuiltNodes[parentIndex].childCount = range.count
            }

            nodes = rebuiltNodes
            stringPool = rebuiltStringPool
            lowercaseNamePool.removeAll(keepingCapacity: true)
            lowercaseNameEntries.removeAll(keepingCapacity: true)
            isSearchIndexBuilt = false
        }
    }

    /// Batch-add children for a parent. Returns the index of the first child.
    @discardableResult
    public func addChildren(_ children: [(node: FileNode, name: String)], parentIndex: UInt32) -> UInt32 {
        lock.withLock { _ in
            let p = Int(parentIndex)
            guard p >= 0, p < nodes.count else { return UInt32(nodes.count) }
            let firstIndex = UInt32(nodes.count)
            nodes.reserveCapacity(nodes.count + children.count)
            for case (var node, let childName) in children {
                node.parentIndex = parentIndex
                appendName(for: childName, to: &node)
                nodes.append(node)
            }
            nodes[p].firstChildIndex = firstIndex
            nodes[p].childCount = UInt32(children.count)
            return firstIndex
        }
    }

    /// Batch-add children whose names are already encoded in a local UTF-8 byte pool.
    /// Used by the production scanner to avoid creating one Swift String per filesystem entry.
    @discardableResult
    func addChildren(
        encoded children: [EncodedFileNode],
        namePool: Data,
        parentIndex: UInt32
    ) -> UInt32 {
        lock.withLock { _ in
            let p = Int(parentIndex)
            guard p >= 0, p < nodes.count else { return UInt32(nodes.count) }
            let firstIndex = UInt32(nodes.count)
            nodes.reserveCapacity(nodes.count + children.count)
            isSearchIndexBuilt = false

            namePool.withUnsafeBytes { rawPool in
                let pool = rawPool.bindMemory(to: UInt8.self)
                for child in children {
                    var node = child.node
                    node.parentIndex = parentIndex
                    node.nameOffset = UInt32(stringPool.count)

                    let offset = child.nameOffset
                    let available = offset >= 0 && offset < pool.count
                        ? min(child.nameLength, pool.count - offset)
                        : 0
                    let length = min(available, Int(UInt16.max))
                    node.nameLength = UInt16(length)

                    if let base = pool.baseAddress, offset >= 0, offset + length <= pool.count {
                        let bytes = UnsafeBufferPointer(start: base.advanced(by: offset), count: length)
                        stringPool.append(contentsOf: bytes)
                    }

                    nodes.append(node)
                }
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
    /// Subtracts `fileSize` and `allocatedSize` independently (matching
    /// `setNodeSizeAndPropagate`) since the two can diverge under APFS compression,
    /// sparse files, or block rounding — subtracting one value from both would corrupt
    /// whichever aggregate doesn't match.
    public func zeroNodeSize(at index: UInt32) {
        lock.withLock { _ in
            let i = Int(index)
            guard i < nodes.count else { return }
            let oldFileSize = nodes[i].fileSize
            let oldAllocatedSize = nodes[i].allocatedSize
            nodes[i].fileSize = 0
            nodes[i].allocatedSize = 0
            var current = nodes[i].parentIndex
            while current != FileNode.invalid {
                let ci = Int(current)
                guard ci < nodes.count else { break }
                if nodes[ci].fileSize >= oldFileSize {
                    nodes[ci].fileSize -= oldFileSize
                } else {
                    nodes[ci].fileSize = 0
                }
                if nodes[ci].allocatedSize >= oldAllocatedSize {
                    nodes[ci].allocatedSize -= oldAllocatedSize
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
                lowercaseNamePool.removeAll(keepingCapacity: true)
                lowercaseNameEntries.removeAll(keepingCapacity: true)
                isSearchIndexBuilt = false
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
            var oldToNew = Array(repeating: FileNode.invalid, count: oldNodes.count)
            var newNodes: [FileNode] = []
            var newStringPool = Data()

            newNodes.reserveCapacity(oldNodes.count - removed.count)
            newStringPool.reserveCapacity(oldStringPool.count)

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
            lowercaseNamePool.removeAll(keepingCapacity: true)
            lowercaseNameEntries.removeAll(keepingCapacity: true)
            isSearchIndexBuilt = false
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
    /// Invalidates the lazy search index and fixes parentIndex pointers that become stale
    /// after reordering.
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
                guard end <= nodes.count else { continue }

                // Common-case fast path: skip permutation work for slices that are
                // already strictly descending by size.
                var isStrictlyDescending = true
                var previousSize = nodes[start].fileSize
                for j in (start + 1)..<end {
                    let currentSize = nodes[j].fileSize
                    if previousSize <= currentSize {
                        isStrictlyDescending = false
                        break
                    }
                    previousSize = currentSize
                }
                if isStrictlyDescending {
                    continue
                }

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
                        dest.swapAt(i, target)  // element at i is now at target; update
                    } else {
                        i += 1
                    }
                }
            }
            isSearchIndexBuilt = false
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
    var fastResult: UInt32?
    let usedFastPath = name.utf8.withContiguousStorageIfAvailable { bytes in
        guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot + 1 < bytes.count else {
            fastResult = 0
            return
        }

        // Fast path: common ASCII extensions hash directly from UTF-8 bytes, avoiding
        // substring/lowercased allocations in scan hot paths.
        var hash: UInt32 = 5381
        var i = dot + 1
        while i < bytes.count {
            let byte = bytes[i]
            if byte & 0x80 != 0 {
                // Preserve exact Unicode lowercasing semantics for non-ASCII extensions.
                fastResult = nil
                return
            }
            let lowered = (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ? (byte &+ 32) : byte
            hash = ((hash &<< 5) &+ hash) &+ UInt32(lowered)
            i += 1
        }
        fastResult = hash
    } != nil

    if usedFastPath, let result = fastResult {
        return result
    }
    return extensionHashUnicodeFallback(name)
}

public func extensionHash(_ nameBytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
    guard let dot = nameBytes.lastIndex(of: UInt8(ascii: ".")), dot + 1 < nameBytes.count else {
        return 0
    }

    var hash: UInt32 = 5381
    var i = dot + 1
    while i < nameBytes.count {
        let byte = nameBytes[i]
        if byte & 0x80 != 0 {
            return extensionHashUnicodeFallback(String(decoding: nameBytes, as: UTF8.self))
        }
        let lowered = (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ? (byte &+ 32) : byte
        hash = ((hash &<< 5) &+ hash) &+ UInt32(lowered)
        i += 1
    }
    return hash
}

@inline(__always)
private func extensionHashUnicodeFallback(_ name: String) -> UInt32 {
    guard let dotIndex = name.lastIndex(of: ".") else { return 0 }
    let ext = name[name.index(after: dotIndex)...].lowercased()
    guard !ext.isEmpty else { return 0 }
    var hash: UInt32 = 5381
    for byte in ext.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt32(byte)
    }
    return hash
}
