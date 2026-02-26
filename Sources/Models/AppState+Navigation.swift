import Foundation

extension AppState {

    // MARK: - Navigation

    /// Set the treemap root to a directory, rebuilding the canonical path from the parent chain.
    public func setTreemapRoot(_ nodeIndex: UInt32, recordHistory: Bool = true) {
        guard let tree = fileTree else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(nodeIndex)
        guard i < nodes.count, nodes[i].isDirectory else { return }

        if recordHistory {
            backStack.append(treemapRootIndex)
            forwardStack.removeAll()
        }

        treemapRootIndex = nodeIndex
        treemapPath = Self.buildPath(to: nodeIndex, nodes: nodes)
    }

    /// Navigate up one level in treemap.
    public func navigateUp() {
        guard treemapPath.count > 1 else { return }
        let parentIndex = treemapPath[treemapPath.count - 2]
        backStack.append(treemapRootIndex)
        forwardStack.removeAll()
        treemapRootIndex = parentIndex
        treemapPath.removeLast()
    }

    /// Navigate to a specific level in breadcrumb.
    public func navigateTo(pathIndex: Int) {
        guard pathIndex < treemapPath.count else { return }
        let target = treemapPath[pathIndex]
        backStack.append(treemapRootIndex)
        forwardStack.removeAll()
        treemapRootIndex = target
        treemapPath = Array(treemapPath.prefix(pathIndex + 1))
    }

    /// Go back to previously viewed directory.
    public func navigateBack() {
        guard let prev = backStack.popLast() else { return }
        guard let tree = fileTree else { return }
        forwardStack.append(treemapRootIndex)
        treemapRootIndex = prev
        treemapPath = Self.buildPath(to: prev, nodes: tree.nodesSnapshot())
    }

    /// Go forward after navigating back.
    public func navigateForward() {
        guard let next = forwardStack.popLast() else { return }
        guard let tree = fileTree else { return }
        backStack.append(treemapRootIndex)
        treemapRootIndex = next
        treemapPath = Self.buildPath(to: next, nodes: tree.nodesSnapshot())
    }

    /// Navigate to the volume root.
    public func navigateHome() {
        guard treemapRootIndex != 0 else { return }
        backStack.append(treemapRootIndex)
        forwardStack.removeAll()
        treemapRootIndex = 0
        treemapPath = [0]
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

    // MARK: - Rescan

    /// Rescan the selected volume from scratch (e.g., after trashing a file).
    public func rescanVolume() {
        guard let volumeURL = selectedVolume else { return }
        // Cancel any in-progress scan (user-initiated or previous rescan).
        activeScanner?.cancel()
        let scanner = FileScanner()
        activeScanner = scanner
        let newTree = FileTree()
        fileTree = newTree
        resetForNewScan()
        activeTab = .treeView
        Task {
            await scanner.scan(path: volumeURL.path, progress: scanProgress, tree: newTree)
            await MainActor.run { [weak self] in
                guard let self else { return }
                activeScanner = nil
                setTreemapRoot(0, recordHistory: false)
                computeExtensionStats()
            }
        }
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
