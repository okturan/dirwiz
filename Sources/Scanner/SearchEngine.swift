import Foundation
import Darwin

/// Filters for search results.
public struct SearchFilters: Sendable {
    public enum NodeType: Sendable { case all, filesOnly, directoriesOnly }
    public var nodeType: NodeType = .all
    public var minimumSize: UInt64 = 0
    public var category: FileCategory? = nil
    /// Extension drill-down: exact extensionHash match. nil = no filter, 0 = no-extension files.
    public var extensionHash: UInt32? = nil

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

        // Mismatch is benign — the scan loop below uses min(nodeCount, entryCount),
        // so it never reads out of bounds. Log in debug to catch stale snapshots early.
        if searchEntries.count < nodes.count {
            #if DEBUG
            print("SearchEngine: searchEntries (\(searchEntries.count)) < nodes (\(nodes.count)); snapshot may be stale")
            #endif
        }

        // Allow empty query when an extension filter is active (show all files with that extension).
        let hasExtFilter = filters.extensionHash != nil
        guard (!query.isEmpty || hasExtFilter), !nodes.isEmpty, !searchEntries.isEmpty else {
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

        // All array access via UnsafeBufferPointer — no bounds checks in debug mode.
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
        if let cat = filterCategory, let map = colorMap {
            if map.category(forHash: node.extensionHash) != cat { return false }
        }
        if let extHash = filters.extensionHash, node.extensionHash != extHash { return false }
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
