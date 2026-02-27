import Foundation
import CoreServices

/// Spotlight-based recency query service.
///
/// Queries `kMDItemLastUsedDate` for all indexed files under the scan root and
/// maps each result to a [0, 1] recency factor:
///   - 1.0  = accessed within the last 30 days
///   - 0.0  = not accessed in 2+ years, or not Spotlight-indexed
///   - linear interpolation between 30 days and 2 years
///
/// Directories receive the max recency of any descendant.
/// All heavy work (nodesSnapshot, path building, MDQuery) runs on a background thread.
public struct RecencyQueryService {
    public init() {}

    /// Query Spotlight for recency factors. Returns a `[Float]` parallel array
    /// (same length as `tree.nodesSnapshot()`). Safe to call from any async context.
    /// Checks `Task.isCancelled` at key points to bail early on superseded scans.
    public func queryRecency(tree: FileTree) async -> [Float] {
        let inner = Task.detached(priority: .utility) {
            Self.runFullQuery(tree: tree)
        }
        return await withTaskCancellationHandler {
            await inner.value
        } onCancel: {
            inner.cancel()
        }
    }

    // MARK: - Private

    private static func runFullQuery(tree: FileTree) -> [Float] {
        // Single lock acquisition for all data needed to build paths.
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()
        guard !nodes.isEmpty else { return [] }
        guard !rootPath.isEmpty else { return Array(repeating: 1, count: nodes.count) }

        // Build file-path → node-index map (files only) using snapshot data.
        // One lock acquisition above instead of millions of per-file tree.path() calls.
        // Normalize to NFC (precomposed) to match Spotlight's kMDItemPath normalization.
        var pathToIndex: [String: Int] = [:]
        pathToIndex.reserveCapacity(nodes.count)
        for i in 0..<nodes.count where !nodes[i].isDirectory {
            let p = FileTree.pathFromSnapshot(at: UInt32(i), nodes: nodes, stringPool: stringPool, rootPath: rootPath)
            pathToIndex[p.precomposedStringWithCanonicalMapping] = i
        }

        // Bail early if the scan was superseded while we built the path map.
        guard !Task.isCancelled else { return Array(repeating: Float(1), count: nodes.count) }

        let nowSeconds = Date().timeIntervalSince1970
        let recentCutoff = nowSeconds - 30.0 * 86_400    // 30 days
        let staleCutoff  = nowSeconds - 730.0 * 86_400   // 2 years

        return runQuery(
            rootPath: rootPath,
            nodeCount: nodes.count,
            pathToIndex: pathToIndex,
            nodes: nodes,
            recentCutoff: recentCutoff,
            staleCutoff: staleCutoff
        )
    }

    private static func runQuery(
        rootPath: String,
        nodeCount: Int,
        pathToIndex: [String: Int],
        nodes: [FileNode],
        recentCutoff: Double,
        staleCutoff: Double
    ) -> [Float] {
        // All entries start at 0.0 (stale/unknown). Spotlight results overwrite file values;
        // the bottom-up max pass then propagates the highest child recency up to each directory.
        // Directories with no Spotlight-indexed descendants remain at 0.0 (stale) rather than
        // staying at 1.0 regardless of their contents — the previous 1.0 default made every
        // directory appear "fully recent" even when all descendants were stale.
        var factors = Array(repeating: Float(0), count: nodeCount)

        let queryString = "kMDItemLastUsedDate >= $time.epoch(0)" as CFString
        let valueAttrs = [kMDItemPath, kMDItemLastUsedDate] as CFArray

        guard let query = MDQueryCreate(kCFAllocatorDefault, queryString, valueAttrs, nil) else {
            // On failure, return 1.0 everywhere — don't show false stale.
            return Array(repeating: Float(1), count: nodeCount)
        }

        // Scope to the scanned volume/directory only.
        let scope = [rootPath as CFString] as CFArray
        MDQuerySetSearchScope(query, scope, 0)

        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return Array(repeating: Float(1), count: nodeCount)
        }

        let resultCount = MDQueryGetResultCount(query)
        for idx in 0..<resultCount {
            guard let rawPath = MDQueryGetAttributeValueOfResultAtIndex(query, kMDItemPath, idx) else { continue }
            let path = (Unmanaged<CFString>.fromOpaque(rawPath).takeUnretainedValue() as String)
                .precomposedStringWithCanonicalMapping
            guard let nodeIdx = pathToIndex[path] else { continue }

            guard let rawDate = MDQueryGetAttributeValueOfResultAtIndex(query, kMDItemLastUsedDate, idx) else { continue }
            let date = Unmanaged<CFDate>.fromOpaque(rawDate).takeUnretainedValue() as Date

            let lastUsed = date.timeIntervalSince1970
            let factor: Float
            if lastUsed >= recentCutoff {
                factor = 1.0
            } else if lastUsed <= staleCutoff {
                factor = 0.0
            } else {
                let range = recentCutoff - staleCutoff
                factor = Float((lastUsed - staleCutoff) / range)
            }
            factors[nodeIdx] = factor
        }

        // Bottom-up pass: each directory gets the max recency of its descendants.
        for i in stride(from: nodeCount - 1, through: 0, by: -1) {
            let parentIndex = nodes[i].parentIndex
            if parentIndex == FileNode.invalid { continue }
            let parentInt = Int(parentIndex)
            guard parentInt < factors.count else { continue }
            if factors[i] > factors[parentInt] {
                factors[parentInt] = factors[i]
            }
        }

        return factors
    }
}
