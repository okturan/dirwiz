import Testing
@testable import DirWizCore
@testable import DirWizUI

/// Tests for AppState navigation state machine.
///
/// Tree structure used by all tests:
/// ```
/// root (0)
/// ├── dirA (1)
/// │   ├── subA1 (3)
/// │   └── subA2 (4)
/// └── dirB (2)
///     └── subB1 (5)
///         └── file.txt (6)
/// ```
@MainActor
@Suite
struct NavigationTests {

    /// Build an in-memory FileTree with the structure above.
    /// Returns (tree, appState) with appState.fileTree already set.
    private func makeFixture() -> (FileTree, AppState) {
        let tree = FileTree()

        // 0: root (directory, no parent)
        tree.addNode(FileNode(parentIndex: FileNode.invalid, flags: 1), name: "root")

        // 1: dirA (directory, parent=0)
        tree.addNode(FileNode(parentIndex: 0, flags: 1), name: "dirA")

        // 2: dirB (directory, parent=0)
        tree.addNode(FileNode(parentIndex: 0, flags: 1), name: "dirB")

        // Set root's children: [1, 2]
        tree.updateNode(at: 0) { node in
            node.firstChildIndex = 1
            node.childCount = 2
        }

        // 3: subA1 (directory, parent=1)
        tree.addNode(FileNode(parentIndex: 1, flags: 1), name: "subA1")

        // 4: subA2 (directory, parent=1)
        tree.addNode(FileNode(parentIndex: 1, flags: 1), name: "subA2")

        // Set dirA's children: [3, 4]
        tree.updateNode(at: 1) { node in
            node.firstChildIndex = 3
            node.childCount = 2
        }

        // 5: subB1 (directory, parent=2)
        tree.addNode(FileNode(parentIndex: 2, flags: 1), name: "subB1")

        // Set dirB's children: [5]
        tree.updateNode(at: 2) { node in
            node.firstChildIndex = 5
            node.childCount = 1
        }

        // 6: file.txt (file, parent=5)
        tree.addNode(FileNode(parentIndex: 5, fileSize: 1024, flags: 0), name: "file.txt")

        // Set subB1's children: [6]
        tree.updateNode(at: 5) { node in
            node.firstChildIndex = 6
            node.childCount = 1
        }

        let state = AppState()
        state.fileTree = tree
        return (tree, state)
    }

    // MARK: - Initial State

    @Test func initialState() {
        let state = AppState()
        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
        #expect(state.navigation.backStack.isEmpty)
        #expect(state.navigation.forwardStack.isEmpty)
        #expect(!state.navigation.canNavigateBack)
        #expect(!state.navigation.canNavigateForward)
        #expect(!state.navigation.canNavigateUp)
    }

    // MARK: - setTreemapRoot

    @Test func setTreemapRootToDirA() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(1)

        #expect(state.navigation.treemapRootIndex == 1)
        #expect(state.navigation.treemapPath == [0, 1])
        #expect(state.navigation.backStack == [0])
        #expect(state.navigation.forwardStack.isEmpty)
        #expect(state.navigation.canNavigateBack)
        #expect(state.navigation.canNavigateUp)
    }

    @Test func setTreemapRootIgnoresFiles() {
        let (_, state) = makeFixture()

        // node 6 is a file, should be ignored
        state.setTreemapRoot(6)

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
        #expect(state.navigation.backStack.isEmpty)
    }

    @Test func setTreemapRootIgnoresOutOfBounds() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(999)

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
    }

    @Test func setTreemapRootDeepNavigation() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(5) // subB1

        #expect(state.navigation.treemapRootIndex == 5)
        #expect(state.navigation.treemapPath == [0, 2, 5])
        #expect(state.navigation.backStack == [0])
    }

    // MARK: - navigateBack

    @Test func navigateBack() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(1) // go to dirA
        state.navigateBack()

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
        #expect(state.navigation.backStack.isEmpty)
        #expect(state.navigation.forwardStack == [1])
        #expect(state.navigation.canNavigateForward)
        #expect(!state.navigation.canNavigateBack)
    }

    @Test func navigateBackWhenEmpty() {
        let (_, state) = makeFixture()

        state.navigateBack() // should do nothing

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.forwardStack.isEmpty)
    }

    // MARK: - navigateForward

    @Test func navigateForward() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(1) // dirA
        state.navigateBack()    // back to root
        state.navigateForward() // forward to dirA

        #expect(state.navigation.treemapRootIndex == 1)
        #expect(state.navigation.treemapPath == [0, 1])
        #expect(state.navigation.backStack == [0])
        #expect(state.navigation.forwardStack.isEmpty)
        #expect(state.navigation.canNavigateBack)
        #expect(!state.navigation.canNavigateForward)
    }

    @Test func navigateForwardWhenEmpty() {
        let (_, state) = makeFixture()

        state.navigateForward() // should do nothing

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.backStack.isEmpty)
    }

    // MARK: - navigateUp

    @Test func navigateUp() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(3) // subA1 (path: [0, 1, 3])
        state.navigateUp()      // should go to dirA

        #expect(state.navigation.treemapRootIndex == 1)
        #expect(state.navigation.treemapPath == [0, 1])
        // backStack: [0] from setTreemapRoot, then [0, 3] from navigateUp
        #expect(state.navigation.backStack == [0, 3])
        #expect(state.navigation.forwardStack.isEmpty)
    }

    @Test func navigateUpAtRoot() {
        let (_, state) = makeFixture()

        state.navigateUp() // at root, should do nothing

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
        #expect(state.navigation.backStack.isEmpty)
        #expect(!state.navigation.canNavigateUp)
    }

    // MARK: - navigateHome

    @Test func navigateHome() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(3) // subA1
        state.navigateHome()

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
        // backStack: [0] from setTreemapRoot(3), then [3] from navigateHome
        #expect(state.navigation.backStack == [0, 3])
        #expect(state.navigation.forwardStack.isEmpty)
    }

    @Test func navigateHomeAtRoot() {
        let (_, state) = makeFixture()

        state.navigateHome() // already at root, should do nothing

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
        #expect(state.navigation.backStack.isEmpty)
    }

    // MARK: - Forward stack cleared on new navigation

    @Test func newNavigationClearsForwardStack() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(1) // dirA, backStack=[0]
        state.navigateBack()    // root, forwardStack=[1]
        #expect(state.navigation.canNavigateForward)

        state.setTreemapRoot(2) // dirB — should clear forwardStack

        #expect(state.navigation.forwardStack.isEmpty)
        #expect(!state.navigation.canNavigateForward)
        #expect(state.navigation.treemapRootIndex == 2)
    }

    // MARK: - navigateTo (breadcrumb)

    @Test func navigateToBreadcrumb() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(3) // subA1, path=[0,1,3]

        // Navigate to root via breadcrumb (pathIndex 0)
        state.navigateTo(pathIndex: 0)

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
        // backStack: [0] from setTreemapRoot, then [3] from navigateTo
        #expect(state.navigation.backStack == [0, 3])
    }

    @Test func navigateToMiddleBreadcrumb() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(3) // subA1, path=[0,1,3]

        // Navigate to dirA via breadcrumb (pathIndex 1)
        state.navigateTo(pathIndex: 1)

        #expect(state.navigation.treemapRootIndex == 1)
        #expect(state.navigation.treemapPath == [0, 1])
    }

    @Test func navigateToOutOfBounds() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(1) // dirA, path=[0,1]

        // pathIndex 5 is out of bounds, should do nothing
        state.navigateTo(pathIndex: 5)

        #expect(state.navigation.treemapRootIndex == 1)
        #expect(state.navigation.treemapPath == [0, 1])
    }

    // MARK: - showNodeInTreemap

    @Test func showNodeInTreemapFile() {
        let (_, state) = makeFixture()

        // node 6 is file.txt, parent is subB1 (5)
        state.showNodeInTreemap(6)

        #expect(state.navigation.treemapRootIndex == 5)
        #expect(state.navigation.treemapPath == [0, 2, 5])
        #expect(state.selectedNodeIndex == 6)
    }

    @Test func showNodeInTreemapDirectory() {
        let (_, state) = makeFixture()

        // node 3 is subA1 (directory)
        state.showNodeInTreemap(3)

        #expect(state.navigation.treemapRootIndex == 3)
        #expect(state.navigation.treemapPath == [0, 1, 3])
        #expect(state.selectedNodeIndex == 3)
    }

    @Test func showNodeInTreemapOutOfBounds() {
        let (_, state) = makeFixture()

        state.showNodeInTreemap(999)

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.selectedNodeIndex == nil)
    }

    // MARK: - buildPath

    @Test func buildPathToRoot() {
        let (tree, _) = makeFixture()
        let nodes = tree.nodesSnapshot()

        let path = AppState.buildPath(to: 0, nodes: nodes)

        #expect(path == [0])
    }

    @Test func buildPathToDirectChild() {
        let (tree, _) = makeFixture()
        let nodes = tree.nodesSnapshot()

        let path = AppState.buildPath(to: 1, nodes: nodes)

        #expect(path == [0, 1])
    }

    @Test func buildPathDeep() {
        let (tree, _) = makeFixture()
        let nodes = tree.nodesSnapshot()

        // file.txt (6) → subB1 (5) → dirB (2) → root (0)
        let path = AppState.buildPath(to: 6, nodes: nodes)

        #expect(path == [0, 2, 5, 6])
    }

    @Test func buildPathSubA1() {
        let (tree, _) = makeFixture()
        let nodes = tree.nodesSnapshot()

        let path = AppState.buildPath(to: 3, nodes: nodes)

        #expect(path == [0, 1, 3])
    }

    // MARK: - Complex navigation sequences

    @Test func backForwardBackSequence() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(1)  // dirA
        state.setTreemapRoot(3)  // subA1, backStack=[0,1]
        state.navigateBack()     // back to dirA, forwardStack=[3]
        state.navigateBack()     // back to root, forwardStack=[3,1]

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.backStack.isEmpty)
        #expect(state.navigation.forwardStack == [3, 1])

        state.navigateForward()  // forward to dirA

        #expect(state.navigation.treemapRootIndex == 1)
        #expect(state.navigation.backStack == [0])
        #expect(state.navigation.forwardStack == [3])
    }

    @Test func navigateUpClearsForwardStack() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(3)  // subA1, path=[0,1,3]
        state.navigateBack()     // root, forwardStack=[3]

        state.setTreemapRoot(3)  // subA1 again, forwardStack cleared
        state.navigateUp()       // up to dirA, forwardStack cleared

        #expect(state.navigation.treemapRootIndex == 1)
        #expect(state.navigation.forwardStack.isEmpty)
    }

    @Test func resetForNewScan() {
        let (_, state) = makeFixture()

        state.setTreemapRoot(3)
        state.navigateBack()
        // Now we have non-empty stacks
        #expect(!state.navigation.backStack.isEmpty || !state.navigation.forwardStack.isEmpty)

        state.resetForNewScan()

        #expect(state.navigation.treemapRootIndex == 0)
        #expect(state.navigation.treemapPath == [0])
        #expect(state.navigation.backStack.isEmpty)
        #expect(state.navigation.forwardStack.isEmpty)
        #expect(state.selectedNodeIndex == nil)
    }
}
