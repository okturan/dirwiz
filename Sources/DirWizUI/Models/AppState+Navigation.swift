import Foundation
import DirWizCore

extension AppState {

    // MARK: - Navigation

    /// Set the treemap root to a directory, rebuilding the canonical path from the parent chain.
    public func setTreemapRoot(_ nodeIndex: UInt32, recordHistory: Bool = true) {
        guard let tree = fileTree else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(nodeIndex)
        guard i < nodes.count, nodes[i].isDirectory else { return }

        if recordHistory {
            navigation.backStack.append(navigation.treemapRootIndex)
            navigation.forwardStack.removeAll()
        }

        navigation.treemapRootIndex = nodeIndex
        navigation.treemapPath = Self.buildPath(to: nodeIndex, nodes: nodes)
        saveSelectionAndRootSession()
    }

    /// Navigate up one level in treemap.
    public func navigateUp() {
        guard navigation.treemapPath.count > 1 else { return }
        let parentIndex = navigation.treemapPath[navigation.treemapPath.count - 2]
        navigation.backStack.append(navigation.treemapRootIndex)
        navigation.forwardStack.removeAll()
        navigation.treemapRootIndex = parentIndex
        navigation.treemapPath.removeLast()
    }

    /// Navigate to a specific level in breadcrumb.
    public func navigateTo(pathIndex: Int) {
        guard pathIndex < navigation.treemapPath.count else { return }
        let target = navigation.treemapPath[pathIndex]
        navigation.backStack.append(navigation.treemapRootIndex)
        navigation.forwardStack.removeAll()
        navigation.treemapRootIndex = target
        navigation.treemapPath = Array(navigation.treemapPath.prefix(pathIndex + 1))
    }

    /// Go back to previously viewed directory.
    public func navigateBack() {
        guard let prev = navigation.backStack.popLast() else { return }
        guard let tree = fileTree else { return }
        navigation.forwardStack.append(navigation.treemapRootIndex)
        navigation.treemapRootIndex = prev
        navigation.treemapPath = Self.buildPath(to: prev, nodes: tree.nodesSnapshot())
    }

    /// Go forward after navigating back.
    public func navigateForward() {
        guard let next = navigation.forwardStack.popLast() else { return }
        guard let tree = fileTree else { return }
        navigation.backStack.append(navigation.treemapRootIndex)
        navigation.treemapRootIndex = next
        navigation.treemapPath = Self.buildPath(to: next, nodes: tree.nodesSnapshot())
    }

    /// Navigate to the volume root.
    public func navigateHome() {
        guard navigation.treemapRootIndex != 0 else { return }
        navigation.backStack.append(navigation.treemapRootIndex)
        navigation.forwardStack.removeAll()
        navigation.treemapRootIndex = 0
        navigation.treemapPath = [0]
    }

    /// Navigate treemap to show a specific node (from search or tree view).
    /// For files, navigates to the parent directory. For directories, navigates to it.
    public func showNodeInTreemap(_ nodeIndex: UInt32) {
        guard let tree = fileTree else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(nodeIndex)
        guard i < nodes.count else { return }

        let node = nodes[i]
        let targetDir: UInt32
        if node.isDirectory {
            targetDir = nodeIndex
        } else if node.parentIndex != FileNode.invalid {
            targetDir = node.parentIndex
        } else {
            return
        }

        setTreemapRoot(targetDir)
        selectedNodeIndex = nodeIndex
    }

    // MARK: - Path Building

    /// Build canonical path from root (0) to the given node index by walking parent chain.
    static func buildPath(to index: UInt32, nodes: [FileNode]) -> [UInt32] {
        var path: [UInt32] = []
        var current = index
        while current != FileNode.invalid {
            let i = Int(current)
            guard i < nodes.count else { break }
            path.append(current)
            current = nodes[i].parentIndex
        }
        path.reverse()
        return path.isEmpty ? [0] : path
    }
}
