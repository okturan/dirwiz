import Foundation

/// Builds snapshots and computes temporal diffs between two scans.
///
/// All heavy work runs on `Task.detached` to keep the MainActor free.
public struct TemporalDiffService {

    // MARK: - Snapshot Building

    /// Build a snapshot from the current file tree (directories only).
    public static func buildSnapshot(tree: FileTree) async -> TemporalSnapshot {
        await Task.detached(priority: .utility) {
            buildSnapshotSync(tree: tree)
        }.value
    }

    private static func buildSnapshotSync(tree: FileTree) -> TemporalSnapshot {
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()
        let caseSensitive = tree.isCaseSensitive
        let resolvedRootPath = nodes.isEmpty ? "/" : rootPath
        let rootPrefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"

        var byPath: [String: UInt64] = [:]
        byPath.reserveCapacity(max(nodes.count / 8, 16))

        for i in 0..<nodes.count {
            let node = nodes[i]
            guard node.isDirectory else { continue }
            let relPath = relativePath(index: UInt32(i),
                                       isRoot: i == 0, rootPrefix: rootPrefix,
                                       nodes: nodes, stringPool: stringPool,
                                       rootPath: resolvedRootPath,
                                       caseSensitive: caseSensitive)
            byPath[relPath] = node.fileSize
        }

        let meta = TemporalSnapshotMeta(
            id: UUID(),
            createdAt: Date(),
            rootPath: resolvedRootPath,
            totalBytes: nodes.first?.fileSize ?? 0,
            dirCount: byPath.count,
            isCaseSensitive: caseSensitive
        )
        return TemporalSnapshot(meta: meta, byPath: byPath)
    }

    // MARK: - Diff Computation

    /// Compute a diff between a snapshot and the current tree.
    public static func computeDiff(
        currentTree: FileTree,
        snapshot: TemporalSnapshot
    ) async -> TemporalDiffResult {
        await Task.detached(priority: .utility) {
            computeDiffSync(currentTree: currentTree, snapshot: snapshot)
        }.value
    }

    private static func computeDiffSync(
        currentTree: FileTree,
        snapshot: TemporalSnapshot
    ) -> TemporalDiffResult {
        let (nodes, stringPool, rootPath) = currentTree.pathBuildingSnapshot()
        guard !nodes.isEmpty else {
            return TemporalDiffResult(kinds: [], strengths: [], deletedByNode: [:])
        }

        // Use snapshot's case-sensitivity flag so that path keys match what was stored.
        let caseSensitive = snapshot.meta.isCaseSensitive
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let totalBytes = Double(max(nodes.first?.fileSize ?? 0, 1))

        var kinds     = Array(repeating: UInt8(TemporalDiffKind.none.rawValue), count: nodes.count)
        var strengths = Array(repeating: Float(0), count: nodes.count)

        // Build a relPath → nodeIndex map for the ancestor-aggregation pass.
        var relPathToIndex: [String: UInt32] = [:]
        relPathToIndex.reserveCapacity(nodes.count / 8)

        // --- First pass: classify each current directory ---
        for i in 0..<nodes.count {
            let node = nodes[i]
            guard node.isDirectory else { continue }

            let relPath = relativePath(index: UInt32(i),
                                       isRoot: i == 0, rootPrefix: rootPrefix,
                                       nodes: nodes, stringPool: stringPool,
                                       rootPath: rootPath,
                                       caseSensitive: caseSensitive)
            relPathToIndex[relPath] = UInt32(i)

            if let oldSize = snapshot.byPath[relPath] {
                let currentSize = node.fileSize
                // Threshold: max(4 MB, 5 % of old size) — ignore noise
                let threshold = max(UInt64(4 * 1024 * 1024), oldSize / 20)
                // Compare UInt64 values directly to avoid Int64 overflow on files > 8 EB.
                if currentSize >= oldSize {
                    let delta = currentSize - oldSize
                    if delta >= threshold {
                        kinds[i] = TemporalDiffKind.grown.rawValue
                        strengths[i] = logStrength(abs: delta, base: oldSize)
                    }
                } else {
                    let delta = oldSize - currentSize
                    if delta >= threshold {
                        kinds[i] = TemporalDiffKind.shrunk.rawValue
                        strengths[i] = logStrength(abs: delta, base: oldSize)
                    }
                }
            } else {
                // Not in snapshot → new directory
                kinds[i] = TemporalDiffKind.new.rawValue
                // Strength proportional to fraction of total disk, log-scaled
                let frac = Double(node.fileSize) / totalBytes
                strengths[i] = Float(min(log1p(frac * 10.0) / log1p(10.0), 1.0))
            }
        }

        // --- Second pass: aggregate deleted snapshot entries to nearest ancestor ---
        // A snapshot path is "deleted" if it doesn't appear in relPathToIndex (no
        // separate matchedPaths set needed — saves a Set<String> allocation).
        var deletedByNode: [UInt32: DeletedSummary] = [:]
        for (deletedPath, deletedBytes) in snapshot.byPath where relPathToIndex[deletedPath] == nil {
            guard let ancestorIdx = nearestAncestor(
                of: deletedPath, in: relPathToIndex
            ) else { continue }

            let existing = deletedByNode[ancestorIdx]
            deletedByNode[ancestorIdx] = DeletedSummary(
                bytes: (existing?.bytes ?? 0) + deletedBytes,
                count: (existing?.count ?? 0) + 1
            )
        }

        // Mark surviving ancestors that hold deleted descendants.
        for (nodeIdx, _) in deletedByNode {
            let i = Int(nodeIdx)
            guard i < kinds.count else { continue }
            // Only mark if the node has no stronger classification.
            if kinds[i] == TemporalDiffKind.none.rawValue {
                kinds[i] = TemporalDiffKind.deletedDescendants.rawValue
                strengths[i] = 0.55
            }
        }

        return TemporalDiffResult(kinds: kinds, strengths: strengths, deletedByNode: deletedByNode)
    }

    // MARK: - Helpers

    /// Relative path from scan root for a directory node.
    /// Root itself returns "".
    ///
    /// On case-insensitive volumes (default macOS), paths are lowercased so that
    /// snapshot keys match regardless of case. On case-sensitive volumes, original
    /// case is preserved to avoid merging directories like "Build" and "build".
    private static func relativePath(
        index: UInt32, isRoot: Bool, rootPrefix: String,
        nodes: [FileNode], stringPool: Data, rootPath: String,
        caseSensitive: Bool
    ) -> String {
        if isRoot { return "" }
        let full = FileTree.pathFromSnapshot(at: index, nodes: nodes,
                                            stringPool: stringPool, rootPath: rootPath)
        let rel: String
        if full.hasPrefix(rootPrefix) {
            rel = String(full.dropFirst(rootPrefix.count))
        } else {
            rel = full
        }
        return caseSensitive ? rel : rel.lowercased()
    }

    /// Log-scaled strength in [0, 1] for a size delta relative to a base.
    private static func logStrength(abs delta: UInt64, base: UInt64) -> Float {
        let ratio = Double(delta) / Double(max(base, 1))
        return Float(min(log1p(ratio) / log1p(10.0), 1.0))
    }

    /// Find the nearest surviving ancestor of a deleted relative path.
    /// Returns nil only if no ancestor exists (shouldn't happen since root "" is always present).
    private static func nearestAncestor(
        of path: String, in index: [String: UInt32]
    ) -> UInt32? {
        var current = (path as NSString).deletingLastPathComponent
        // Normalise: "." means we've reached the root level
        while !current.isEmpty && current != "." {
            if let idx = index[current] { return idx }
            current = (current as NSString).deletingLastPathComponent
        }
        return index[""]  // root fallback
    }
}
