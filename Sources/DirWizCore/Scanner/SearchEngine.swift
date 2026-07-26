import Foundation
import Darwin
import os

private let log = Logger(subsystem: "com.dirwiz", category: "SearchEngine")

/// Filters for search results.
public struct SearchFilters: Sendable {
    public enum NodeType: Sendable { case all, filesOnly, directoriesOnly }
    public var nodeType: NodeType = .all
    public var minimumSize: UInt64 = 0
    /// Inclusive upper size bound. nil = unbounded.
    public var maximumSize: UInt64? = nil
    public var category: FileCategory? = nil
    /// Extension drill-down: exact extensionHash match. nil = no filter, 0 = no-extension files.
    ///
    /// Superseded by `extensionHashes` for multi-select, but kept because the Extensions-tab
    /// drill-down and its tests speak in terms of one extension. When the set is non-empty it
    /// wins; the two are never ANDed, which would make selecting two extensions match nothing.
    public var extensionHash: UInt32? = nil
    /// OR-combined extension multi-select. Empty = not filtering by extension.
    public var extensionHashes: Set<UInt32> = []

    /// Inclusive Unix-seconds bounds on `FileNode.modifiedDate`.
    ///
    /// `modifiedDate == 0` means the scanner never learned a date. Such nodes are excluded
    /// whenever a date bound is set: claiming an unknown date falls inside a "last 7 days"
    /// window would be inventing data.
    public var modifiedAfter: UInt32? = nil
    public var modifiedBefore: UInt32? = nil

    /// Restricts matches to a subtree. Built by `SearchEngine.scopeBitset`; nil = whole tree.
    ///
    /// A bitset rather than a per-node ancestor walk: the walk is O(depth) per node on a
    /// path that must stay instant, while the bitset is one ascending pass over the tree.
    public var scope: ScopeBitset? = nil

    public init() {}

    /// True when the filters can only be satisfied by nothing at all. Callers can skip the
    /// scan entirely, and it keeps an impossible band from looking like a slow search.
    public var isUnsatisfiable: Bool {
        if let maximumSize, maximumSize < minimumSize { return true }
        if let after = modifiedAfter, let before = modifiedBefore, after > before { return true }
        return false
    }
}

/// Subtree membership as a packed bitset, one bit per node index.
public struct ScopeBitset: Sendable {
    @usableFromInline var words: [UInt64]
    public let rootIndex: UInt32

    init(words: [UInt64], rootIndex: UInt32) {
        self.words = words
        self.rootIndex = rootIndex
    }

    @inlinable
    public func contains(_ index: Int) -> Bool {
        let word = index >> 6
        guard word >= 0, word < words.count else { return false }
        return words[word] & (1 << UInt64(index & 63)) != 0
    }
}

/// Result of a search operation.
public struct SearchResult: Sendable {
    public let matchingIndices: [UInt32]
    public let totalMatches: Int
    public let elapsedTime: TimeInterval
}

/// Instant search engine using pre-lowercased contiguous name buffer.
/// All hot-path array access uses UnsafeBufferPointer to eliminate
/// Swift's debug-mode bounds checks (~10x faster in debug builds).
public enum SearchEngine {

    public static let defaultResultCap = 10_000

    /// Builds subtree membership for `rootIndex` in ONE ascending pass.
    ///
    /// This relies on the tree's parent-index-< -child-index invariant: by the time node `i`
    /// is visited, its parent's membership is already final, so membership is just inherited.
    /// If that invariant ever breaks, this silently under-reports rather than crashing -
    /// hence the test that pins deep descendants.
    public static func scopeBitset(rootIndex: UInt32, nodes: [FileNode]) -> ScopeBitset? {
        let count = nodes.count
        guard Int(rootIndex) < count else { return nil }
        var words = [UInt64](repeating: 0, count: (count + 63) / 64)
        let root = Int(rootIndex)
        words[root >> 6] |= (1 << UInt64(root & 63))

        nodes.withUnsafeBufferPointer { buf in
            // Nothing before the root can be a descendant of it.
            for i in (root + 1)..<count {
                let parent = Int(buf[i].parentIndex)
                guard parent < i else { continue }   // defensive: never read a later node
                if words[parent >> 6] & (1 << UInt64(parent & 63)) != 0 {
                    words[i >> 6] |= (1 << UInt64(i & 63))
                }
            }
        }
        return ScopeBitset(words: words, rootIndex: rootIndex)
    }

    public static func search(
        query: String,
        nodes: [FileNode],
        searchPool: Data,
        searchEntries: [(offset: UInt32, length: UInt16)],
        filters: SearchFilters = SearchFilters(),
        resultCap: Int = defaultResultCap,
        previousMatches: [UInt32]? = nil
    ) -> SearchResult {
        let start = CFAbsoluteTimeGetCurrent()

        // Mismatch is benign - the scan loop below uses min(nodeCount, entryCount),
        // so it never reads out of bounds. Log in debug to catch stale snapshots early.
        if searchEntries.count < nodes.count {
            #if DEBUG
            log.debug("searchEntries (\(searchEntries.count)) < nodes (\(nodes.count)); snapshot may be stale")
            #endif
        }

        // An empty query is meaningful for filters that are themselves an explicit
        // "show me this set" gesture: an extension pick, a folder scope, a date window.
        //
        // Category and size bounds are deliberately NOT in this list. They predate this
        // change with the documented behavior "an empty query returns nothing regardless of
        // filters" (pinned by SearchEngineTests), and a size filter in particular tends to
        // sit at a non-zero default - flipping it would make an empty search box suddenly
        // enumerate the volume. New filter kinds get the better semantics; existing ones
        // keep the contract they shipped with.
        let hasNarrowingFilter = filters.extensionHash != nil
            || !filters.extensionHashes.isEmpty
            || filters.scope != nil
            || filters.modifiedAfter != nil
            || filters.modifiedBefore != nil
        guard !filters.isUnsatisfiable else {
            return SearchResult(matchingIndices: [], totalMatches: 0,
                                elapsedTime: CFAbsoluteTimeGetCurrent() - start)
        }
        guard (!query.isEmpty || hasNarrowingFilter), !nodes.isEmpty, !searchEntries.isEmpty else {
            return SearchResult(matchingIndices: [], totalMatches: 0,
                                elapsedTime: CFAbsoluteTimeGetCurrent() - start)
        }

        let queryBytes: [UInt8]
        if query.isEmpty {
            queryBytes = []
        } else {
            queryBytes = Array(query.precomposedStringWithCanonicalMapping.lowercased().utf8)
        }
        let hasQuery = !queryBytes.isEmpty
        let colorMap = filters.category != nil ? ExtensionColorMap.shared : nil
        let filterCategory = filters.category
        let scanAll = previousMatches == nil
        let scanIndices = previousMatches ?? []

        var matches: [UInt32] = []
        var totalMatches = 0
        let expectedScanCount = scanAll ? min(nodes.count, searchEntries.count) : scanIndices.count
        matches.reserveCapacity(min(resultCap, expectedScanCount))

        // All array access via UnsafeBufferPointer - no bounds checks in debug mode.
        queryBytes.withUnsafeBufferPointer { needleBuf in
            nodes.withUnsafeBufferPointer { nodesBuf in
                searchEntries.withUnsafeBufferPointer { entriesBuf in
                    searchPool.withUnsafeBytes { poolPtr in
                        guard let poolBase = poolPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        let poolCount = poolPtr.count
                        let nodeCount = nodesBuf.count
                        let entryCount = entriesBuf.count
                        let needleLen = hasQuery ? needleBuf.count : 0
                        let needleBase: UnsafePointer<UInt8>
                        if hasQuery {
                            guard let base = needleBuf.baseAddress else { return }
                            needleBase = base
                        } else {
                            // Unused when hasQuery is false; any valid pointer is fine.
                            needleBase = poolBase
                        }

                        if scanAll {
                            let limit = min(nodeCount, entryCount)
                            for i in 0..<limit {
                                if matchNode(
                                    i: i, nodesBuf: nodesBuf, entriesBuf: entriesBuf,
                                    poolBase: poolBase, poolCount: poolCount,
                                    hasQuery: hasQuery, needleBase: needleBase, needleLen: needleLen,
                                    filters: filters, filterCategory: filterCategory, colorMap: colorMap
                                ) {
                                    totalMatches += 1
                                    if matches.count < resultCap {
                                        matches.append(UInt32(i))
                                    }
                                }
                            }
                        } else {
                            scanIndices.withUnsafeBufferPointer { indicesBuf in
                                for idx in 0..<indicesBuf.count {
                                    let i = Int(indicesBuf[idx])
                                    guard i < nodeCount, i < entryCount else { continue }
                                    if matchNode(
                                        i: i, nodesBuf: nodesBuf, entriesBuf: entriesBuf,
                                        poolBase: poolBase, poolCount: poolCount,
                                        hasQuery: hasQuery, needleBase: needleBase, needleLen: needleLen,
                                        filters: filters, filterCategory: filterCategory, colorMap: colorMap
                                    ) {
                                        totalMatches += 1
                                        if matches.count < resultCap {
                                            matches.append(UInt32(i))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return SearchResult(matchingIndices: matches, totalMatches: totalMatches,
                            elapsedTime: CFAbsoluteTimeGetCurrent() - start)
    }

    /// Check a single node against filters + byte search. All access via unsafe pointers.
    @inline(__always)
    private static func matchNode(
        i: Int,
        nodesBuf: UnsafeBufferPointer<FileNode>,
        entriesBuf: UnsafeBufferPointer<(offset: UInt32, length: UInt16)>,
        poolBase: UnsafePointer<UInt8>,
        poolCount: Int,
        hasQuery: Bool,
        needleBase: UnsafePointer<UInt8>,
        needleLen: Int,
        filters: SearchFilters,
        filterCategory: FileCategory?,
        colorMap: ExtensionColorMap?
    ) -> Bool {
        let node = nodesBuf[i]

        switch filters.nodeType {
        case .filesOnly where node.isDirectory: return false
        case .directoriesOnly where !node.isDirectory: return false
        default: break
        }
        if node.fileSize < filters.minimumSize { return false }
        if let maxSize = filters.maximumSize, node.fileSize > maxSize { return false }

        // Date bounds. modifiedDate == 0 means "unknown", which is never inside a window -
        // treating it as a match would invent a date the scanner never read.
        if filters.modifiedAfter != nil || filters.modifiedBefore != nil {
            let mod = node.modifiedDate
            if mod == 0 { return false }
            if let after = filters.modifiedAfter, mod < after { return false }
            if let before = filters.modifiedBefore, mod > before { return false }
        }

        if let scope = filters.scope, !scope.contains(i) { return false }

        // Extension: the multi-select set wins when present; ANDing it with the single-hash
        // drill-down would make any two-extension selection match nothing.
        if !filters.extensionHashes.isEmpty {
            if !filters.extensionHashes.contains(node.extensionHash) { return false }
        } else if let extHash = filters.extensionHash, node.extensionHash != extHash {
            return false
        }

        if let cat = filterCategory, let map = colorMap {
            if map.category(forHash: node.extensionHash) != cat { return false }
        }
        if !hasQuery { return true }

        let entry = entriesBuf[i]
        let nameStart = Int(entry.offset)
        let nameLen = Int(entry.length)
        guard nameStart + nameLen <= poolCount, nameLen >= needleLen else { return false }

        return byteContains(
            haystack: poolBase + nameStart,
            haystackLen: nameLen,
            needle: needleBase,
            needleLen: needleLen
        )
    }

    /// Fast byte-level substring search using libc's memmem (SIMD-optimized on Apple platforms).
    /// Both haystack and needle are pre-lowercased.
    @inline(__always)
    private static func byteContains(
        haystack: UnsafePointer<UInt8>,
        haystackLen: Int,
        needle: UnsafePointer<UInt8>,
        needleLen: Int
    ) -> Bool {
        guard needleLen > 0 else { return true }
        guard haystackLen >= needleLen else { return false }
        return memmem(haystack, haystackLen, needle, needleLen) != nil
    }
}
