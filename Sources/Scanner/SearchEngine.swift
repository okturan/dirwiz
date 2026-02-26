import Foundation

/// Filters for search results.
public struct SearchFilters: Sendable {
    public enum NodeType: Sendable { case all, filesOnly, directoriesOnly }
    public var nodeType: NodeType = .all
    public var minimumSize: UInt64 = 0
    public var category: FileCategory? = nil

    public init() {}
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

        assert(searchEntries.count >= nodes.count,
               "searchEntries (\(searchEntries.count)) must be >= nodes (\(nodes.count)); snapshot may be stale")

        guard !query.isEmpty, !nodes.isEmpty, !searchEntries.isEmpty else {
            return SearchResult(matchingIndices: [], totalMatches: 0,
                                elapsedTime: CFAbsoluteTimeGetCurrent() - start)
        }

        let queryBytes = Array(query.lowercased().utf8)
        let colorMap = filters.category != nil ? ExtensionColorMap.shared : nil
        let filterCategory = filters.category
        let scanAll = previousMatches == nil
        let scanIndices = previousMatches ?? []

        var matches: [UInt32] = []
        var totalMatches = 0

        // All array access via UnsafeBufferPointer — no bounds checks in debug mode.
        queryBytes.withUnsafeBufferPointer { needleBuf in
            nodes.withUnsafeBufferPointer { nodesBuf in
                searchEntries.withUnsafeBufferPointer { entriesBuf in
                    searchPool.withUnsafeBytes { poolPtr in
                        guard let poolBase = poolPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let needleBase = needleBuf.baseAddress else { return }
                        let poolCount = poolPtr.count
                        let nodeCount = nodesBuf.count
                        let entryCount = entriesBuf.count
                        let needleLen = needleBuf.count

                        if scanAll {
                            let limit = min(nodeCount, entryCount)
                            for i in 0..<limit {
                                if matchNode(
                                    i: i, nodesBuf: nodesBuf, entriesBuf: entriesBuf,
                                    poolBase: poolBase, poolCount: poolCount,
                                    needleBase: needleBase, needleLen: needleLen,
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
                                        needleBase: needleBase, needleLen: needleLen,
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
        if let cat = filterCategory, let map = colorMap {
            if map.category(forHash: node.extensionHash) != cat { return false }
        }

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

    /// Fast byte-level substring search. Both haystack and needle are pre-lowercased.
    @inline(__always)
    private static func byteContains(
        haystack: UnsafePointer<UInt8>,
        haystackLen: Int,
        needle: UnsafePointer<UInt8>,
        needleLen: Int
    ) -> Bool {
        guard needleLen > 0 else { return true }
        let limit = haystackLen - needleLen
        guard limit >= 0 else { return false }
        let firstByte = needle[0]
        for i in 0...limit {
            if haystack[i] == firstByte {
                var found = true
                for j in 1..<needleLen {
                    if haystack[i + j] != needle[j] {
                        found = false
                        break
                    }
                }
                if found { return true }
            }
        }
        return false
    }
}
