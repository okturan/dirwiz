import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

// MARK: - Hand-built tree fixtures
//
// These analyzers only care about FileNode metadata (isDirectory, displaySize,
// modifiedDate) and tree shape, not real filesystem state. Hand-building trees gives
// exact control over sizes/dates without depending on APFS block-rounding or real
// mtimes, and lets us construct trees no real scan could ever produce (see the
// index-inversion test below).

private indirect enum Fixture {
    case file(name: String, size: UInt64, modifiedDate: UInt32)
    case dir(name: String, children: [Fixture])
}

private func file(_ name: String, size: UInt64, modifiedDate: UInt32 = 0) -> Fixture {
    .file(name: name, size: size, modifiedDate: modifiedDate)
}

private func dir(_ name: String, _ children: [Fixture]) -> Fixture {
    .dir(name: name, children: children)
}

/// Build a chain of single-child directories from a "/"-separated path, e.g.
/// `nestedDir("Library/Caches", [file("a", size: 1)])` produces `Library/Caches/a`.
private func nestedDir(_ path: String, _ children: [Fixture]) -> Fixture {
    let components = path.split(separator: "/").map(String.init)
    precondition(!components.isEmpty)
    var node = Fixture.dir(name: components[components.count - 1], children: children)
    for name in components.dropLast().reversed() {
        node = .dir(name: name, children: [node])
    }
    return node
}

@discardableResult
private func materialize(_ children: [Fixture], into tree: FileTree, parentIndex: UInt32) -> [UInt32] {
    guard !children.isEmpty else { return [] }
    let pairs: [(node: FileNode, name: String)] = children.map { child in
        switch child {
        case .file(let name, let size, let modifiedDate):
            return (node: FileNode(fileSize: size, allocatedSize: size, modifiedDate: modifiedDate), name: name)
        case .dir(let name, _):
            var node = FileNode()
            node.isDirectory = true
            return (node: node, name: name)
        }
    }
    let firstIndex = tree.addChildren(pairs, parentIndex: parentIndex)
    var indices: [UInt32] = []
    for (offset, child) in children.enumerated() {
        let index = firstIndex + UInt32(offset)
        indices.append(index)
        if case .dir(_, let grandchildren) = child, !grandchildren.isEmpty {
            materialize(grandchildren, into: tree, parentIndex: index)
        }
    }
    return indices
}

/// Build a hand-crafted tree rooted at `rootPath`. Sizes propagate bottom-up via
/// `propagateSizes()` exactly as a real scan would, so directory aggregates behave
/// normally even though nothing touches a real filesystem.
private func makeTree(rootPath: String, _ children: [Fixture]) -> FileTree {
    let tree = FileTree()
    tree.setRootPath(rootPath)
    var root = FileNode()
    root.isDirectory = true
    tree.addNode(root, name: "")
    materialize(children, into: tree, parentIndex: 0)
    tree.propagateSizes()
    return tree
}

@Suite("Analyzer Walk And Consolidation Tests")
struct AnalyzerWalkTests {

    // MARK: - forEachFileInSnapshot

    @Test("forEachFileInSnapshot visits every file exactly once, in index order, and skips directories")
    func forEachFileVisitsEveryFileOnce() throws {
        let tree = makeTree(rootPath: "/fake-root", [
            file("a.bin", size: 10),
            dir("sub", [
                file("b.bin", size: 20),
                dir("deep", [file("c.bin", size: 30)]),
            ]),
            dir("emptyDir", []),
        ])
        let nodes = tree.nodesSnapshot()

        var visitedIndices: [Int] = []
        var totalSize: UInt64 = 0
        var sawDirectory = false
        let completed = FileTree.forEachFileInSnapshot(nodes) { i, node in
            visitedIndices.append(i)
            totalSize += node.displaySize
            if node.isDirectory { sawDirectory = true }
        }

        #expect(completed)
        #expect(!sawDirectory)
        #expect(visitedIndices.count == 3, "Should visit exactly the 3 files, never directories")
        #expect(Set(visitedIndices).count == 3, "No index should be visited twice")
        #expect(visitedIndices == visitedIndices.sorted(), "Should visit in ascending index order")
        #expect(totalSize == 60)
    }

    @Test("forEachFileInSnapshot stops and returns false when the task is already cancelled")
    func forEachFileStopsWhenCancelled() async throws {
        let tree = makeTree(rootPath: "/fake-root", [file("a.bin", size: 10)])
        let nodes = tree.nodesSnapshot()

        let task = Task {
            // Cancel the currently-running task synchronously, before any work happens —
            // deterministic, unlike racing a concurrent cancel() against a tight sync loop.
            withUnsafeCurrentTask { $0?.cancel() }
            var bodyRan = false
            let completed = FileTree.forEachFileInSnapshot(nodes) { _, _ in bodyRan = true }
            return (completed, bodyRan)
        }
        let (completed, bodyRan) = await task.value
        #expect(!completed)
        #expect(!bodyRan)
    }

    // MARK: - descendPath

    @Test("descendPath finds nested nodes by name and returns nil past a missing component")
    func descendPathFindsNestedNodes() throws {
        let tree = makeTree(rootPath: "/fake-root", [
            dir("Library", [
                dir("Caches", [file("a.txt", size: 10)]),
            ]),
        ])
        let (nodes, stringPool, _) = tree.pathBuildingSnapshot()

        let cachesIndex = FileTree.descendPath(["Library", "Caches"], nodes: nodes, stringPool: stringPool)
        #expect(cachesIndex != nil)
        if let cachesIndex {
            #expect(tree.path(at: cachesIndex) == "/fake-root/Library/Caches")
        }

        #expect(FileTree.descendPath([], nodes: nodes, stringPool: stringPool) == 0, "Empty components resolve to root")
        #expect(FileTree.descendPath(["Library", "Missing"], nodes: nodes, stringPool: stringPool) == nil)
        #expect(FileTree.descendPath(["Nope"], nodes: nodes, stringPool: stringPool) == nil)
    }

    // MARK: - FileAgeAnalyzer characterization (pins pre-refactor behavior)

    @Test("FileAgeAnalyzer buckets by age and tracks oldest/newest known dates")
    func fileAgeCharacterization() async throws {
        let now = UInt32(Date().timeIntervalSince1970)
        let day: UInt32 = 86_400
        let tree = makeTree(rootPath: "/fake-root", [
            file("recent.bin", size: 1_000, modifiedDate: now - 5 * day),
            dir("sub", [
                file("mid.bin", size: 2_000, modifiedDate: now - 45 * day),
                dir("deep", [
                    file("old.bin", size: 3_000, modifiedDate: now - 200 * day),
                    file("ancient.bin", size: 4_000, modifiedDate: now - 500 * day),
                ]),
            ]),
            file("veryOld.bin", size: 5_000, modifiedDate: now - 1_000 * day),
            file("unknown.bin", size: 6_000, modifiedDate: 0),
        ])

        let result = await FileAgeAnalyzer().analyze(tree: tree)

        #expect(result.totalFiles == 6)
        #expect(result.totalSize == 21_000)
        #expect(result.buckets.count == 6)

        let byId = Dictionary(uniqueKeysWithValues: result.buckets.map { ($0.id, $0) })
        #expect(byId["recent_30d"]?.fileCount == 1)
        #expect(byId["recent_30d"]?.totalSize == 1_000)
        #expect(byId["30_90d"]?.fileCount == 1)
        #expect(byId["30_90d"]?.totalSize == 2_000)
        #expect(byId["90d_1y"]?.fileCount == 1)
        #expect(byId["90d_1y"]?.totalSize == 3_000)
        #expect(byId["1_2y"]?.fileCount == 1)
        #expect(byId["1_2y"]?.totalSize == 4_000)
        #expect(byId["2y_plus"]?.fileCount == 1)
        #expect(byId["2y_plus"]?.totalSize == 5_000)
        #expect(byId["unknown"]?.fileCount == 1)
        #expect(byId["unknown"]?.totalSize == 6_000)

        if let pct = byId["recent_30d"]?.percentage {
            #expect(abs(pct - (1_000.0 / 21_000.0 * 100.0)) < 0.0001)
        } else {
            Issue.record("Missing recent_30d bucket")
        }

        #expect(result.newestFileDate == Date(timeIntervalSince1970: TimeInterval(now - 5 * day)))
        #expect(result.oldestFileDate == Date(timeIntervalSince1970: TimeInterval(now - 1_000 * day)))
    }

    @Test("FileAgeAnalyzer returns an empty result when the task is already cancelled")
    func fileAgeReturnsEmptyWhenCancelled() async throws {
        let tree = makeTree(rootPath: "/fake-root", [file("a.bin", size: 100)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FileAgeAnalyzer().analyze(tree: tree)
        }
        let result = await task.value
        #expect(result.buckets.isEmpty)
        #expect(result.totalFiles == 0)
        #expect(result.totalSize == 0)
        #expect(result.oldestFileDate == nil)
        #expect(result.newestFileDate == nil)
    }

    // MARK: - SizeDistributionAnalyzer characterization (pins pre-refactor behavior)

    @Test("SizeDistributionAnalyzer buckets, sorts, and computes percentiles")
    func sizeDistributionCharacterization() async throws {
        // One file per bucket boundary, chosen so buckets, totals, and the ceiling-rank
        // percentile formula (see SizeDistribution.swift's `percentile`) are hand-verifiable.
        let sizes: [UInt64] = [0, 500, 5_000, 50_000, 500_000, 5_000_000, 50_000_000, 500_000_000, 5_000_000_000]
        let tree = makeTree(
            rootPath: "/fake-root",
            sizes.enumerated().map { i, size in file("f\(i).bin", size: size) }
        )

        let result = await SizeDistributionAnalyzer().analyze(tree: tree)

        #expect(result.totalFiles == 9)
        #expect(result.totalSize == 5_555_555_500)
        #expect(result.meanSize == 617_283_944)
        #expect(result.medianSize == 500_000)
        #expect(result.percentiles.p50 == 500_000)
        #expect(result.percentiles.p90 == 5_000_000_000)
        #expect(result.percentiles.p95 == 5_000_000_000)
        #expect(result.percentiles.p99 == 5_000_000_000)

        let byId = Dictionary(uniqueKeysWithValues: result.buckets.map { ($0.id, $0) })
        for id in ["0b", "1b_1kb", "1_10kb", "10_100kb", "100kb_1mb", "1_10mb", "10_100mb", "100mb_1gb", "1gb_plus"] {
            #expect(byId[id]?.fileCount == 1, "Bucket \(id) should have exactly one file")
        }
    }

    @Test("SizeDistributionAnalyzer returns an empty result when the task is already cancelled")
    func sizeDistributionReturnsEmptyWhenCancelled() async throws {
        let tree = makeTree(rootPath: "/fake-root", [file("a.bin", size: 100)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SizeDistributionAnalyzer().analyze(tree: tree)
        }
        let result = await task.value
        #expect(result.buckets.isEmpty)
        #expect(result.totalFiles == 0)
        #expect(result.totalSize == 0)
    }

    // MARK: - iCloudAnalyzer characterization (pins pre-refactor behavior)

    @Test("iCloudAnalyzer returns an empty result for a tree with no iCloud container paths")
    func iCloudOutsidePrefixCharacterization() async throws {
        let tree = makeTree(rootPath: "/Users/tester/Projects", [
            file("main.swift", size: 100),
            dir("Sub", [file("helper.swift", size: 200)]),
        ])
        let result = await iCloudAnalyzer().analyze(tree: tree)
        #expect(result.groups.isEmpty)
        #expect(result.totalLocalSize == 0)
        #expect(result.evictableSize == 0)
        #expect(result.cloudOnlySize == 0)
    }

    // MARK: - iCloudAnalyzer container derivation (post-refactor: Step 3)

    @Test("iCloudAnalyzer.relativeComponents handles root at /, exact-match ancestor, root-inside-container, and non-boundary false positives")
    func iCloudRelativeComponentsHandlesRootVariants() throws {
        // Root "/" — every absolute path is "inside" it; components are the full path split.
        #expect(
            iCloudAnalyzer.relativeComponents(of: "/Users/alice/Library/Mobile Documents/", from: "/")
                == ["Users", "alice", "Library", "Mobile Documents"]
        )

        // ancestor == child exactly.
        #expect(iCloudAnalyzer.relativeComponents(of: "/Users/alice", from: "/Users/alice") == [])

        // Root strictly inside a container.
        #expect(
            iCloudAnalyzer.relativeComponents(
                of: "/Users/alice/Library/Mobile Documents/com~apple~CloudDocs",
                from: "/Users/alice/Library/Mobile Documents/"
            ) == ["com~apple~CloudDocs"]
        )

        // Root unrelated to any container.
        #expect(
            iCloudAnalyzer.relativeComponents(of: "/Applications", from: "/Users/alice/Library/Mobile Documents/")
                == nil
        )

        // Textual-but-not-path-boundary prefix must not match (e.g. "al" vs "alice").
        #expect(iCloudAnalyzer.relativeComponents(of: "/Users/alicexyz", from: "/Users/alice") == nil)
    }

    @Test("iCloudAnalyzer.containerSubtreeRoots resolves root-is-ancestor, root-inside-container, and unrelated-root cases")
    func iCloudContainerSubtreeRootsResolvesAllCases() throws {
        // iCloudPrefixes is derived from the real current-user home directory, so these
        // fixtures must be rooted there too.
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Root is an ancestor of a container that exists in the tree: locate its node.
        let treeA = makeTree(rootPath: home, [
            dir("Library", [
                dir("Mobile Documents", [file("doc.txt", size: 10)]),
            ]),
        ])
        let snapshotA = treeA.pathBuildingSnapshot()
        let rootsA = iCloudAnalyzer.containerSubtreeRoots(
            nodes: snapshotA.nodes, stringPool: snapshotA.stringPool, rootPath: snapshotA.rootPath
        )
        #expect(rootsA.count == 1)
        if let onlyRoot = rootsA.first {
            #expect(treeA.path(at: onlyRoot) == home + "/Library/Mobile Documents")
        }

        // Root is itself inside a container: whole tree (root index 0) is in scope.
        let treeB = makeTree(rootPath: home + "/Library/Mobile Documents/com~apple~CloudDocs", [
            file("doc.txt", size: 10),
        ])
        let snapshotB = treeB.pathBuildingSnapshot()
        let rootsB = iCloudAnalyzer.containerSubtreeRoots(
            nodes: snapshotB.nodes, stringPool: snapshotB.stringPool, rootPath: snapshotB.rootPath
        )
        #expect(rootsB == [0])

        // Root unrelated to any container: nothing to scope to.
        let treeC = makeTree(rootPath: "/Applications", [file("placeholder", size: 10)])
        let snapshotC = treeC.pathBuildingSnapshot()
        let rootsC = iCloudAnalyzer.containerSubtreeRoots(
            nodes: snapshotC.nodes, stringPool: snapshotC.stringPool, rootPath: snapshotC.rootPath
        )
        #expect(rootsC.isEmpty)

        // Neither container exists on disk under this root: derivation finds the ancestor
        // relationship but descendPath comes up empty, so no subtree roots either.
        let treeD = makeTree(rootPath: home, [dir("Documents", [file("note.txt", size: 5)])])
        let snapshotD = treeD.pathBuildingSnapshot()
        let rootsD = iCloudAnalyzer.containerSubtreeRoots(
            nodes: snapshotD.nodes, stringPool: snapshotD.stringPool, rootPath: snapshotD.rootPath
        )
        #expect(rootsD.isEmpty)
    }

    @Test("iCloudAnalyzer walks only the container subtree when the scan root is broader")
    func iCloudAnalyzeScopesToContainerSubtree() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tree = makeTree(rootPath: home, [
            dir("Documents", [file("plain.txt", size: 999)]),
            dir("Library", [
                dir("Mobile Documents", [
                    nestedDir("com~apple~CloudDocs", [file("synced.pages", size: 4_096)]),
                ]),
            ]),
        ])

        let result = await iCloudAnalyzer().analyze(tree: tree)

        // The synthetic path doesn't exist on disk, so queryStatus can't classify it as
        // downloaded/cloud-only/downloading — but it must still be found and counted, which
        // is what this test is actually checking (the walk reaches the right subtree and
        // nowhere else). Plain Documents content must never be considered.
        let totalCount = result.groups.reduce(0) { $0 + $1.fileCount }
        let totalSize = result.groups.reduce(0) { $0 + $1.totalSize }
        #expect(totalCount == 1)
        #expect(totalSize == 4_096)
        #expect(result.groups.allSatisfy { !$0.paths.contains { $0.contains("plain.txt") } })
    }

    @Test("iCloudAnalyzer returns an empty result when the task is already cancelled")
    func iCloudReturnsEmptyWhenCancelled() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tree = makeTree(rootPath: home, [
            nestedDir("Library/Mobile Documents/com~apple~CloudDocs", [file("synced.pages", size: 4_096)]),
        ])

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await iCloudAnalyzer().analyze(tree: tree)
        }
        let result = await task.value
        #expect(result.groups.isEmpty)
        #expect(result.totalLocalSize == 0)
        #expect(result.evictableSize == 0)
        #expect(result.cloudOnlySize == 0)
    }

    // MARK: - SpaceAnalyzer characterization (pins pre-refactor behavior)
    //
    // SpaceAnalyzer's outer walk visits nodes in array-index order, which — for any tree a
    // real scan produces — is always ancestor-before-descendant (a child's index is always
    // greater than its parent's; propagateSizes(), sortAllChildren(), etc. all depend on this
    // same invariant elsewhere in the codebase). Combined with "claim a matched directory's
    // full displaySize, then skip all its descendants", this means: whichever category's
    // prefix is the *shallowest* structural ancestor claims the entire subtree, even when a
    // more specific category is defined earlier in `categoryDefinitions`. The tests below pin
    // this exactly as it stands today.

    @Test("SpaceAnalyzer claims a matched directory's full aggregate size exactly once")
    func spaceAnalyzerExactMatchNoDoubleCount() async throws {
        let tree = makeTree(rootPath: "/Users/tester", [
            nestedDir("Library/Developer/Xcode/DerivedData", [
                dir("ProjA-abc123", [file("a.o", size: 5_000)]),
                dir("ProjB-def456", [file("b.o", size: 3_000)]),
            ]),
            dir("Documents", [file("notes.txt", size: 777)]),
        ])

        let result = await SpaceAnalyzer().analyze(tree: tree)

        #expect(result.categories.count == 1, "Only DerivedData should be categorized")
        let derivedData = result.categories.first { $0.id == "xcode_derived_data" }
        #expect(derivedData?.totalSize == 8_000, "Aggregate of both sub-projects, counted once")
        #expect(derivedData?.fileCount == 1, "One claimed directory node, not one per file")
        #expect(derivedData?.matchedPaths == ["/Users/tester/Library/Developer/Xcode/DerivedData"])
        #expect(result.totalAnalyzed == 8_777, "Root aggregate: DerivedData (8000) + Documents (777)")
    }

    @Test("SpaceAnalyzer: a general ancestor category claims the whole subtree before a more specific nested category is ever reached")
    func spaceAnalyzerAncestorClaimsBeforeNestedCategory() async throws {
        let tree = makeTree(rootPath: "/Users/tester", [
            dir("Library", [
                dir("Caches", [
                    nestedDir("Google/Chrome", [file("cache_data.bin", size: 4_000)]),
                    dir("SomeOtherApp", [file("data.db", size: 2_000)]),
                ]),
            ]),
        ])

        let result = await SpaceAnalyzer().analyze(tree: tree)

        let appCaches = result.categories.first { $0.id == "application_caches" }
        #expect(appCaches?.totalSize == 6_000)
        #expect(appCaches?.fileCount == 1)
        #expect(appCaches?.matchedPaths == ["/Users/tester/Library/Caches"])
        #expect(!result.categories.contains { $0.id == "browser_caches" },
                "browser_caches is defined earlier than application_caches but never gets a turn because Library/Caches (its structural ancestor) is visited first and claims the whole subtree")
    }

    @Test("SpaceAnalyzer: application_containers eats docker_data and mail_downloads the same way")
    func spaceAnalyzerContainersClaimsBeforeDockerAndMail() async throws {
        let tree = makeTree(rootPath: "/Users/tester", [
            dir("Library", [
                dir("Containers", [
                    dir("com.docker.docker", [file("vm.img", size: 9_000)]),
                    nestedDir("com.apple.mail/Data/Library/Mail Downloads", [file("attachment.pdf", size: 1_500)]),
                ]),
            ]),
        ])

        let result = await SpaceAnalyzer().analyze(tree: tree)

        let containers = result.categories.first { $0.id == "application_containers" }
        #expect(containers?.totalSize == 10_500)
        #expect(containers?.fileCount == 1)
        #expect(!result.categories.contains { $0.id == "docker_data" })
        #expect(!result.categories.contains { $0.id == "mail_downloads" })
    }

    @Test("SpaceAnalyzer sorts independent categories by size descending")
    func spaceAnalyzerOrdersCategoriesBySizeDescending() async throws {
        // Both subtrees share the "Library/Developer" prefix, so they're nested under one
        // shared ancestor here — two independent nestedDir() calls with a shared prefix would
        // each build their own "Library" wrapper, producing two sibling nodes with the same
        // name under root, a shape no real filesystem (or scan) can ever produce.
        let tree = makeTree(rootPath: "/Users/tester", [
            dir("Library", [
                dir("Developer", [
                    nestedDir("Xcode/DerivedData", [file("build.o", size: 1_000)]),
                    dir("CoreSimulator", [file("runtime.dat", size: 9_000)]),
                ]),
            ]),
            dir(".Trash", [file("deleted.bin", size: 500)]),
        ])

        let result = await SpaceAnalyzer().analyze(tree: tree)

        #expect(result.categories.map(\.id) == ["xcode_simulators", "xcode_derived_data", "trash"])
    }

    /// This test deliberately builds a tree no real scan can produce: a child node whose
    /// array index is *lower* than its own parent's. `FileTree.propagateSizes()`,
    /// `sortAllChildren()`, and the removeSubtree rebuild all depend on parent-index <
    /// child-index holding for every node — the real scanner guarantees it structurally
    /// (a directory can't get a node until it's discovered, and children are only
    /// discovered after their parent). `replaceContents` is the one construction path that
    /// doesn't enforce it, which is exactly what's needed to exercise SpaceAnalyzer's
    /// "direct child of a not-yet-claimed prefix" branch: with normal ordering, "Library/Caches"
    /// (a real, always-materialized directory) is visited before any of its children and
    /// immediately claims itself exactly, so the branch is unreachable. Nodes: 0=root,
    /// 1=Library, 2=ChildA (parent=3, but index < 3), 3=Caches (parent=1).
    @Test("SpaceAnalyzer's direct-child-of-prefix branch requires index-inverted ordering no real scan produces")
    func spaceAnalyzerDirectChildBranchRequiresIndexInversion() async throws {
        let tree = FileTree()
        tree.setRootPath("/Users/tester")

        var rootNode = FileNode()
        rootNode.isDirectory = true

        var libraryNode = FileNode()
        libraryNode.isDirectory = true
        libraryNode.parentIndex = 0

        var childNode = FileNode()
        childNode.isDirectory = true
        childNode.allocatedSize = 12_345
        childNode.fileSize = 12_345
        childNode.parentIndex = 3

        var cachesNode = FileNode()
        cachesNode.isDirectory = true
        cachesNode.allocatedSize = 999
        cachesNode.fileSize = 999
        cachesNode.parentIndex = 1

        let namePool = Data("LibraryChildACaches".utf8)
        // "Library" [0..<7), "ChildA" [7..<13), "Caches" [13..<19)
        let arena = FileTreeArena(nodes: [
            IndexedEncodedFileNode(index: 1, node: libraryNode, nameOffset: 0, nameLength: 7),
            IndexedEncodedFileNode(index: 2, node: childNode, nameOffset: 7, nameLength: 6),
            IndexedEncodedFileNode(index: 3, node: cachesNode, nameOffset: 13, nameLength: 6),
        ], namePool: namePool)

        tree.replaceContents(
            rootNode: rootNode,
            rootName: "",
            childRanges: [
                0: (first: 1, count: 1),
                1: (first: 3, count: 1),
                3: (first: 2, count: 1),
            ],
            arenas: [arena],
            totalNodeCount: 4
        )

        // Sanity: the tree really is shaped the way this test claims.
        #expect(tree.path(at: 2) == "/Users/tester/Library/Caches/ChildA")
        #expect(tree.path(at: 3) == "/Users/tester/Library/Caches")

        let result = await SpaceAnalyzer().analyze(tree: tree)
        let appCaches = result.categories.first { $0.id == "application_caches" }

        // Pinned current behavior: ChildA (index 2) is visited before Caches (index 3), so it
        // is not yet a "descendant of a claimed node" when its turn comes — it hits the
        // direct-child branch and is claimed on its own, in addition to Caches's own later,
        // separate exact-match claim. Two claims, two paths, sizes NOT deduplicated.
        #expect(appCaches?.fileCount == 2)
        #expect(appCaches?.totalSize == 12_345 + 999)
        #expect(appCaches?.matchedPaths == [
            "/Users/tester/Library/Caches/ChildA",
            "/Users/tester/Library/Caches",
        ])
    }
}
