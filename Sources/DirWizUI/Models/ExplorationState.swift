import DirWizCore

/// Path-keyed snapshot of "where the user is", captured before a tree mutation that
/// renumbers indices (e.g. `FileTree.removeSubtree`), re-resolved after. Paths survive
/// renumbering; indices don't.
struct ExplorationCapture {
    let selectedPath: String?
    let treemapRootPath: String?

    static func capture(tree: FileTree, selectedIndex: UInt32?, treemapRootIndex: UInt32) -> ExplorationCapture {
        ExplorationCapture(
            selectedPath: selectedIndex.map { tree.path(at: $0) },
            treemapRootPath: tree.path(at: treemapRootIndex)
        )
    }

    /// Resolve a captured absolute path to the index of itself, or of the nearest
    /// surviving ancestor, in the CURRENT `tree`. Strips trailing path components one at
    /// a time and retries `FileTree.descendPath` until one resolves. Returns nil only
    /// when `path` was never under this tree's root at all — once a path is confirmed to
    /// be under the root, root itself (index 0) is always a valid last-resort resolution,
    /// since `descendPath` with zero components always returns 0.
    static func resolveOrAncestor(_ path: String, tree: FileTree) -> UInt32? {
        let snapshot = tree.pathBuildingSnapshot()
        guard var components = PathResolution.relativeComponents(of: path, rootPath: snapshot.rootPath) else {
            return nil
        }
        while true {
            if let index = FileTree.descendPath(components, nodes: snapshot.nodes, stringPool: snapshot.stringPool) {
                return index
            }
            guard !components.isEmpty else { return nil }
            components.removeLast()
        }
    }
}

/// Shared path-splitting helper for resolving absolute paths against a `FileTree`
/// snapshot. Used by `ExplorationCapture` (selection/treemap-root restore after a trash)
/// and `TreeTableView` (expansion-set remap) — both need to turn a captured absolute path
/// back into tree-relative components before calling `FileTree.descendPath`.
enum PathResolution {
    /// Split `path` into components relative to `rootPath`, or nil if `path` is neither
    /// `rootPath` itself nor a boundary-respecting descendant of it (e.g. rejects
    /// "/root-2" against root "/root"). Reimplements the pattern used by
    /// `FileScanner.relativeComponents`/`iCloudAnalyzer.relativeComponents` — those are
    /// `internal` to DirWizCore and not visible from this module.
    static func relativeComponents(of path: String, rootPath: String) -> [String]? {
        if path == rootPath { return [] }
        let boundaryPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(boundaryPrefix) else { return nil }
        let relative = String(path.dropFirst(boundaryPrefix.count))
        guard !relative.isEmpty else { return [] }
        return relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
