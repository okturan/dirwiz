import Foundation

/// Result of a trash operation.
public struct TrashResult: Sendable {
    public let originalPath: String
    public let trashedURL: URL?
    public let nodeIndex: UInt32
    public let freedSize: UInt64
    public let success: Bool
    public let error: String?

    public init(
        originalPath: String,
        trashedURL: URL?,
        nodeIndex: UInt32,
        freedSize: UInt64,
        success: Bool,
        error: String?
    ) {
        self.originalPath = originalPath
        self.trashedURL = trashedURL
        self.nodeIndex = nodeIndex
        self.freedSize = freedSize
        self.success = success
        self.error = error
    }
}

/// Batch trash result.
public struct BatchTrashResult: Sendable {
    public let results: [TrashResult]
    public var totalFreed: UInt64 { results.filter(\.success).reduce(0) { $0 + $1.freedSize } }
    public var successCount: Int { results.filter(\.success).count }
    public var failureCount: Int { results.filter { !$0.success }.count }

    public init(results: [TrashResult]) {
        self.results = results
    }
}

/// Cleanup presets for duplicate groups.
public enum CleanupPreset: String, Sendable, CaseIterable {
    case keepNewest = "Keep Newest"
    case keepOldest = "Keep Oldest"
    case keepLargest = "Keep Largest"
    case keepInDirectory = "Keep in Directory"
}

public struct TreeActions: Sendable {
    public init() {}

    /// Trash a single file/directory and update tree sizes.
    public func trash(nodeIndex: UInt32, tree: FileTree) async -> TrashResult {
        guard let node = tree.node(at: nodeIndex) else {
            return TrashResult(
                originalPath: "", trashedURL: nil, nodeIndex: nodeIndex,
                freedSize: 0, success: false, error: "Invalid node index"
            )
        }

        let path = tree.path(at: nodeIndex)
        let size = node.displaySize

        let trashedURL: URL?
        do {
            trashedURL = try performTrash(path: path)
        } catch {
            return TrashResult(
                originalPath: path, trashedURL: nil, nodeIndex: nodeIndex,
                freedSize: 0, success: false, error: error.localizedDescription
            )
        }

        tree.removeSubtree(at: nodeIndex)

        return TrashResult(
            originalPath: path, trashedURL: trashedURL,
            nodeIndex: nodeIndex, freedSize: size, success: true, error: nil
        )
    }

    /// Move a single filesystem item to Trash. Uses compiler-managed writeback
    /// for the `resultingItemURL` out-param rather than a hand-built
    /// AutoreleasingUnsafeMutablePointer — the manual pointer construction
    /// over-released at autorelease-pool pop when called from an async context.
    private func performTrash(path: String) throws -> URL? {
        var trashedURL: NSURL?
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: path),
            resultingItemURL: &trashedURL
        )
        return trashedURL as URL?
    }

    /// Batch trash multiple nodes.
    ///
    /// Only safe for a single index: `removeSubtree` renumbers indices, so multiple
    /// pre-resolved indices are invalid after the first removal. Prefer
    /// `batchTrash(paths:tree:)`.
    public func batchTrash(nodeIndices: [UInt32], tree: FileTree) async -> BatchTrashResult {
        var results: [TrashResult] = []
        results.reserveCapacity(nodeIndices.count)
        for idx in nodeIndices {
            let result = await trash(nodeIndex: idx, tree: tree)
            results.append(result)
        }
        return BatchTrashResult(results: results)
    }

    /// Trash files by absolute path, resolving each path against the tree's
    /// CURRENT state immediately before trashing it (removeSubtree renumbers
    /// indices, so pre-resolved indices are invalid after the first removal).
    /// Paths that no longer resolve are reported as failures, not trashed blindly.
    public func batchTrash(paths: [String], tree: FileTree) async -> BatchTrashResult {
        var results: [TrashResult] = []
        results.reserveCapacity(paths.count)
        for path in paths {
            let snapshot = tree.pathBuildingSnapshot()
            guard let idx = Self.findNodeIndex(for: path, nodes: snapshot.nodes,
                                               stringPool: snapshot.stringPool,
                                               rootPath: snapshot.rootPath) else {
                results.append(TrashResult(originalPath: path, trashedURL: nil, nodeIndex: 0,
                                           freedSize: 0, success: false, error: "Path not found in tree"))
                continue
            }
            results.append(await trash(nodeIndex: idx, tree: tree))
        }
        return BatchTrashResult(results: results)
    }

    /// Apply cleanup preset to a duplicate group.
    ///
    /// Returns paths to trash (all except the one to keep). Returns an empty array
    /// when no unambiguous keep-file can be determined; callers must treat `[]` as
    /// "do nothing". This function fails closed: it never guesses a keep-file to
    /// nominate the rest for deletion. Fail-closed cases are (1) any group member
    /// that no longer resolves to a node in the current tree — stale paths mean the
    /// scan no longer reflects reality — (2) `.keepOldest` when no member has a known
    /// (non-zero) modified date, and (3) `.keepInDirectory` when `preferredDirectory`
    /// is nil or no member's path has that prefix.
    public func applyPreset(
        _ preset: CleanupPreset,
        to group: DuplicateGroup,
        preferredDirectory: String?,
        tree: FileTree
    ) -> [String] {
        let paths = group.paths
        guard paths.count >= 2 else { return [] }

        let snapshot = tree.pathBuildingSnapshot()
        let nodes = snapshot.nodes

        // Build (path, nodeIndex) pairs by searching tree for matching paths.
        struct PathInfo {
            let path: String
            let nodeIndex: UInt32?
            let modifiedDate: UInt32
            let allocatedSize: UInt64
        }

        let infos: [PathInfo] = paths.map { path in
            let idx = Self.findNodeIndex(for: path, nodes: nodes, stringPool: snapshot.stringPool, rootPath: snapshot.rootPath)
            let date: UInt32
            let size: UInt64
            if let idx, Int(idx) < nodes.count {
                date = nodes[Int(idx)].modifiedDate
                size = nodes[Int(idx)].allocatedSize
            } else {
                date = 0
                size = 0
            }
            return PathInfo(path: path, nodeIndex: idx, modifiedDate: date, allocatedSize: size)
        }

        // A path that no longer resolves means the scan is stale — fail closed rather
        // than nominate anything for deletion from an out-of-date view of the tree.
        guard infos.allSatisfy({ $0.nodeIndex != nil }) else { return [] }

        let keepIndex: Int?
        switch preset {
        case .keepNewest:
            keepIndex = infos.indices.max(by: { infos[$0].modifiedDate < infos[$1].modifiedDate })
        case .keepOldest:
            if let minDate = infos.filter({ $0.modifiedDate > 0 }).min(by: { $0.modifiedDate < $1.modifiedDate })?.modifiedDate {
                keepIndex = infos.firstIndex(where: { $0.modifiedDate == minDate })
            } else {
                keepIndex = nil
            }
        case .keepLargest:
            keepIndex = infos.indices.max(by: { infos[$0].allocatedSize < infos[$1].allocatedSize })
        case .keepInDirectory:
            if let dir = preferredDirectory {
                keepIndex = infos.firstIndex(where: { $0.path.hasPrefix(dir) })
            } else {
                keepIndex = nil
            }
        }

        guard let keepIndex else { return [] }

        return infos.enumerated().compactMap { i, info in
            i == keepIndex ? nil : info.path
        }
    }

    /// Find a node index by full path, walking the tree from root.
    private static func findNodeIndex(
        for targetPath: String,
        nodes: [FileNode],
        stringPool: Data,
        rootPath: String
    ) -> UInt32? {
        guard nodes.count > 0 else { return nil }

        // Strip rootPath prefix to get relative components.
        var relative = targetPath
        if relative.hasPrefix(rootPath) {
            relative = String(relative.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        }
        if relative.isEmpty { return 0 }

        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var currentIndex: UInt32 = 0  // root

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
}
