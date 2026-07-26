import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// The filters added by the search-filter-upgrade change: extension multi-select, a size
/// band, modified-date bounds and folder scope. Every one is an O(1) per-node predicate
/// over data the scan already captured - no filesystem reads - so the instant feel holds.
@Suite("Search Filter Upgrade Tests")
struct SearchFilterUpgradeTests {

    /// Flat tree of files directly under the root.
    private func flatTree(_ files: [(name: String, size: UInt64, modified: UInt32)]) -> FileTree {
        let tree = FileTree()
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "root")
        var children: [(node: FileNode, name: String)] = []
        for f in files {
            var n = FileNode()
            n.fileSize = f.size
            n.modifiedDate = f.modified
            n.extensionHash = extensionHash(f.name)
            children.append((node: n, name: f.name))
        }
        tree.addChildren(children, parentIndex: 0)
        return tree
    }

    private func search(_ tree: FileTree, _ query: String, _ filters: SearchFilters) -> SearchResult {
        let nodes = tree.nodesSnapshot()
        let (pool, entries) = tree.searchIndexSnapshot()
        return SearchEngine.search(query: query, nodes: nodes, searchPool: pool,
                                   searchEntries: entries, filters: filters)
    }

    private func names(_ tree: FileTree, _ r: SearchResult) -> Set<String> {
        Set(r.matchingIndices.map { tree.name(at: $0) })
    }

    // MARK: - Extension multi-select

    @Test("Extension set is OR-combined, not AND-combined")
    func extensionSetIsOr() {
        let tree = flatTree([("a.png", 10, 100), ("b.jpg", 10, 100), ("c.txt", 10, 100)])
        var f = SearchFilters()
        f.extensionHashes = [extensionHash("x.png"), extensionHash("x.jpg")]
        let r = search(tree, "", f)
        #expect(names(tree, r) == ["a.png", "b.jpg"],
                "selecting two extensions must match either, not both at once")
    }

    /// The single-hash drill-down and the multi-select must never AND together - that would
    /// make any two-extension selection match exactly nothing.
    @Test("A non-empty extension set overrides the single-hash drill-down")
    func extensionSetWinsOverSingle() {
        let tree = flatTree([("a.png", 10, 100), ("b.jpg", 10, 100)])
        var f = SearchFilters()
        f.extensionHash = extensionHash("x.txt")      // matches neither
        f.extensionHashes = [extensionHash("x.png")]
        let r = search(tree, "", f)
        #expect(names(tree, r) == ["a.png"])
    }

    @Test("An empty extension set does not filter anything out")
    func emptyExtensionSetIsInert() {
        let tree = flatTree([("a.png", 10, 100), ("b.jpg", 10, 100)])
        var f = SearchFilters()
        f.extensionHashes = []
        f.extensionHash = extensionHash("x.png")
        #expect(names(tree, search(tree, "", f)) == ["a.png"],
                "an empty set must fall through to the drill-down, not match nothing")
    }

    // MARK: - Size band

    @Test("Size bounds are inclusive at both ends")
    func sizeBandIsInclusive() {
        let tree = flatTree([("small.bin", 100, 1), ("mid.bin", 500, 1), ("big.bin", 900, 1)])
        var f = SearchFilters()
        f.minimumSize = 100
        f.maximumSize = 900
        #expect(names(tree, search(tree, ".bin", f)) == ["small.bin", "mid.bin", "big.bin"])

        f.minimumSize = 101
        f.maximumSize = 899
        #expect(names(tree, search(tree, ".bin", f)) == ["mid.bin"])
    }

    @Test("An inverted size band matches nothing and says so up front")
    func invertedBandIsUnsatisfiable() {
        let tree = flatTree([("a.bin", 500, 1)])
        var f = SearchFilters()
        f.minimumSize = 900
        f.maximumSize = 100
        #expect(f.isUnsatisfiable)
        #expect(search(tree, ".bin", f).totalMatches == 0)
    }

    // MARK: - Date bounds

    @Test("Date bounds are inclusive and exclude unknown dates")
    func dateBounds() {
        // modifiedDate 0 is the scanner's "unknown", not the epoch.
        let tree = flatTree([
            ("old.log", 10, 1_000),
            ("mid.log", 10, 2_000),
            ("new.log", 10, 3_000),
            ("undated.log", 10, 0),
        ])
        var f = SearchFilters()
        f.modifiedAfter = 2_000
        #expect(names(tree, search(tree, ".log", f)) == ["mid.log", "new.log"],
                "the lower bound is inclusive")

        f = SearchFilters()
        f.modifiedBefore = 2_000
        #expect(names(tree, search(tree, ".log", f)) == ["old.log", "mid.log"],
                "the upper bound is inclusive")

        f = SearchFilters()
        f.modifiedAfter = 1_500
        f.modifiedBefore = 2_500
        let windowed = names(tree, search(tree, ".log", f))
        #expect(windowed == ["mid.log"])
        #expect(!windowed.contains("undated.log"),
                "an unknown date must never be claimed to fall inside a window")
    }

    @Test("An inverted date window matches nothing")
    func invertedDateWindow() {
        let tree = flatTree([("a.log", 10, 2_000)])
        var f = SearchFilters()
        f.modifiedAfter = 3_000
        f.modifiedBefore = 1_000
        #expect(f.isUnsatisfiable)
        #expect(search(tree, ".log", f).totalMatches == 0)
    }

    // MARK: - Folder scope

    /// root ├── alpha ── deep ── buried.txt
    ///      └── beta  ── sibling.txt
    private func nestedTree() -> (FileTree, alpha: UInt32, beta: UInt32) {
        let tree = FileTree()
        var root = FileNode(); root.isDirectory = true
        tree.addNode(root, name: "root")

        var a = FileNode(); a.isDirectory = true
        var b = FileNode(); b.isDirectory = true
        tree.addChildren([(node: a, name: "alpha"), (node: b, name: "beta")], parentIndex: 0)
        let alpha: UInt32 = 1, beta: UInt32 = 2

        var deep = FileNode(); deep.isDirectory = true
        tree.addChildren([(node: deep, name: "deep")], parentIndex: alpha)
        let deepIdx: UInt32 = 3

        var buried = FileNode(); buried.fileSize = 10; buried.extensionHash = extensionHash("x.txt")
        tree.addChildren([(node: buried, name: "buried.txt")], parentIndex: deepIdx)

        var sib = FileNode(); sib.fileSize = 10; sib.extensionHash = extensionHash("x.txt")
        tree.addChildren([(node: sib, name: "sibling.txt")], parentIndex: beta)

        return (tree, alpha, beta)
    }

    @Test("Scope includes deep descendants and excludes siblings")
    func scopeMembership() throws {
        let (tree, alpha, beta) = nestedTree()
        let nodes = tree.nodesSnapshot()

        let alphaScope = try #require(SearchEngine.scopeBitset(rootIndex: alpha, nodes: nodes))
        #expect(alphaScope.contains(Int(alpha)), "the scope root is inside its own scope")
        #expect(!alphaScope.contains(0), "an ancestor is not inside the scope")
        #expect(!alphaScope.contains(Int(beta)), "a sibling subtree is excluded")

        var f = SearchFilters()
        f.scope = alphaScope
        #expect(names(tree, search(tree, ".txt", f)) == ["buried.txt"],
                "a grandchild two levels down is still in scope")

        f.scope = SearchEngine.scopeBitset(rootIndex: beta, nodes: nodes)
        #expect(names(tree, search(tree, ".txt", f)) == ["sibling.txt"])
    }

    @Test("Scoping to the tree root keeps everything")
    func scopeAtRootKeepsAll() throws {
        let (tree, _, _) = nestedTree()
        var f = SearchFilters()
        f.scope = try #require(SearchEngine.scopeBitset(rootIndex: 0, nodes: tree.nodesSnapshot()))
        #expect(names(tree, search(tree, ".txt", f)) == ["buried.txt", "sibling.txt"])
    }

    @Test("An out-of-range scope root yields no bitset rather than a crash")
    func scopeOutOfRange() {
        let (tree, _, _) = nestedTree()
        #expect(SearchEngine.scopeBitset(rootIndex: 9_999, nodes: tree.nodesSnapshot()) == nil)
    }

    // MARK: - Composition

    /// The headline claim: filters AND across kinds and OR within the extension set.
    @Test("All filter kinds compose")
    func allFiltersCompose() throws {
        let tree = FileTree()
        var root = FileNode(); root.isDirectory = true
        tree.addNode(root, name: "root")
        var dir = FileNode(); dir.isDirectory = true
        tree.addChildren([(node: dir, name: "target")], parentIndex: 0)
        let target: UInt32 = 1

        func file(_ name: String, _ size: UInt64, _ mod: UInt32) -> (node: FileNode, name: String) {
            var n = FileNode(); n.fileSize = size; n.modifiedDate = mod
            n.extensionHash = extensionHash(name)
            return (node: n, name: name)
        }
        tree.addChildren([
            file("keep.png", 500, 2_000),      // matches everything
            file("toobig.png", 5_000, 2_000),  // fails the size band
            file("tooold.png", 500, 10),       // fails the date window
            file("wrong.txt", 500, 2_000),     // fails the extension set
        ], parentIndex: target)
        // Outside the scope, but otherwise a perfect match.
        tree.addChildren([file("outside.png", 500, 2_000)], parentIndex: 0)

        var f = SearchFilters()
        f.scope = try #require(SearchEngine.scopeBitset(rootIndex: target, nodes: tree.nodesSnapshot()))
        f.extensionHashes = [extensionHash("x.png"), extensionHash("x.jpg")]
        f.minimumSize = 100
        f.maximumSize = 1_000
        f.modifiedAfter = 1_000
        f.modifiedBefore = 3_000

        #expect(names(tree, search(tree, "", f)) == ["keep.png"])
    }
}

/// Date presets and the UI-level scope/filter state.
@Suite("Search Filter State Tests")
@MainActor
struct SearchFilterStateTests {

    // MARK: - Date presets

    @Test("Recent presets bound below, older-than presets bound above")
    func presetDirection() {
        // Comfortably past 2 years of seconds, so the test's own arithmetic cannot
        // underflow UInt32 while checking that the implementation does not either.
        let now: UInt32 = 2_000_000_000
        let recent = SearchDatePreset.last7Days.bounds(now: now)
        #expect(recent.after == now - 7 * 86_400)
        #expect(recent.before == nil, "'last 7 days' has no upper bound - now is the top")

        let old = SearchDatePreset.olderThan1Year.bounds(now: now)
        #expect(old.after == nil)
        #expect(old.before == now - 365 * 86_400)

        let any = SearchDatePreset.any.bounds(now: now)
        #expect(any.after == nil && any.before == nil)
    }

    /// `now` is unsigned. A clock near the epoch would underflow a naive subtraction into a
    /// far-future bound that silently matches nothing.
    @Test("A near-epoch clock saturates at zero instead of wrapping")
    func presetsDoNotUnderflow() {
        for preset in SearchDatePreset.allCases {
            let b = preset.bounds(now: 5)
            #expect((b.after ?? 0) <= 5)
            #expect((b.before ?? 0) <= 5)
        }
        #expect(SearchDatePreset.olderThan2Years.bounds(now: 5).before == 0)
    }

    // MARK: - Scope state

    @Test("Scope is stored by path and clears with a notice")
    func scopeLifecycle() {
        let state = SearchState()
        #expect(!state.hasActiveFilters)

        state.setScope(path: "/Users/x/Projects", name: "Projects")
        #expect(state.scopePath == "/Users/x/Projects")
        #expect(state.scopeName == "Projects")
        #expect(state.hasActiveFilters)

        state.clearScope(notice: "gone")
        #expect(state.scopePath == nil)
        #expect(state.scopeClearedNotice == "gone",
                "a scope that vanishes must say so, not silently widen the search")

        // Setting a new scope clears the stale notice.
        state.setScope(path: "/tmp", name: "tmp")
        #expect(state.scopeClearedNotice == nil)
    }

    @Test("An unnamed scope falls back to its path rather than showing a blank chip")
    func scopeNameFallback() {
        let state = SearchState()
        state.setScope(path: "/some/where", name: "")
        #expect(state.scopeName == "/some/where")
    }

    @Test("Scoping search switches to the Search tab")
    func scopeSearchSwitchesTab() {
        let app = AppState()
        app.activeTab = .treeView
        app.scopeSearch(toPath: "/a/b", name: "b")
        #expect(app.activeTab == .search)
        #expect(app.search.scopePath == "/a/b")
    }

    /// Every filter kind must count as "active", or its chip never renders and the user
    /// cannot see - let alone remove - a filter that is silently narrowing their results.
    @Test("Every filter kind registers as active")
    func allFilterKindsRegisterAsActive() {
        for mutate in [
            { (s: SearchState) in s.extensionFilter = 1 },
            { (s: SearchState) in s.extensionFilters = [1: ".png"] },
            { (s: SearchState) in s.maximumSize = 100 },
            { (s: SearchState) in s.datePreset = .last7Days },
            { (s: SearchState) in s.setScope(path: "/x", name: "x") },
        ] {
            let state = SearchState()
            mutate(state)
            #expect(state.hasActiveFilters)
            state.reset()
            #expect(!state.hasActiveFilters, "reset must clear every filter kind")
        }
    }

    // MARK: - Path-keyed resolution

    /// The reason scope is a path: indices do not survive tree mutations.
    @Test("A scope path resolves to the right node and fails closed when absent")
    func scopeResolvesByPath() async throws {
        let (root, cleanup) = try createTempTree([
            "alpha/one.bin": 1_000,
            "beta/two.bin": 1_000,
        ])
        defer { cleanup() }

        let tree = FileTree()
        let scanner = FileScanner(computeBundleSizes: false, deferTreeMaterialization: false)
        await scanner.scan(path: root, progress: ScanProgress(), tree: tree)

        let alpha = try #require(tree.nodeIndex(forPath: root + "/alpha"))
        #expect(tree.name(at: alpha) == "alpha")
        #expect(tree.nodeIndex(forPath: root) == 0, "the scan root resolves to index 0")
        #expect(tree.nodeIndex(forPath: root + "/does-not-exist") == nil)
        #expect(tree.nodeIndex(forPath: "/completely/elsewhere") == nil)
    }
}

/// The whole premise of these filters is that they are O(1) per node over data the scan
/// already holds, so search stays instant. This is the gate on that claim.
extension PerformanceSensitiveSuites {

    @Suite("Search Filter Latency Tests")
    struct SearchFilterLatencyTests {

        @Test("All filters active still searches a large tree in instant range")
        func allFiltersStayInstant() throws {
            let tree = FileTree()
            var root = FileNode(); root.isDirectory = true
            tree.addNode(root, name: "root")

            // 200k files spread over 200 directories - a realistically large subtree.
            var dirs: [(node: FileNode, name: String)] = []
            for d in 0..<200 {
                var n = FileNode(); n.isDirectory = true
                dirs.append((node: n, name: "dir\(d)"))
            }
            tree.addChildren(dirs, parentIndex: 0)

            let exts = ["png", "jpg", "txt", "swift", "bin"]
            for d in 0..<200 {
                var files: [(node: FileNode, name: String)] = []
                files.reserveCapacity(1_000)
                for f in 0..<1_000 {
                    let name = "file\(f).\(exts[f % exts.count])"
                    var n = FileNode()
                    n.fileSize = UInt64(100 + (f % 5_000))
                    n.modifiedDate = UInt32(1_500_000_000 + f)
                    n.extensionHash = extensionHash(name)
                    files.append((node: n, name: name))
                }
                tree.addChildren(files, parentIndex: UInt32(d + 1))
            }

            let nodes = tree.nodesSnapshot()
            let (pool, entries) = tree.searchIndexSnapshot()
            #expect(nodes.count > 200_000)

            var f = SearchFilters()
            f.scope = SearchEngine.scopeBitset(rootIndex: 1, nodes: nodes)
            f.extensionHashes = [extensionHash("x.png"), extensionHash("x.jpg")]
            f.minimumSize = 100
            f.maximumSize = 4_000
            f.modifiedAfter = 1_500_000_000
            f.modifiedBefore = 1_500_001_000

            // Best-of-5: this asserts an upper bound, so the fastest run is the honest measure
            // of the code rather than of whatever else the machine was doing.
            var best = Double.greatestFiniteMagnitude
            var matches = 0
            for _ in 0..<5 {
                let r = SearchEngine.search(query: "file", nodes: nodes, searchPool: pool,
                                            searchEntries: entries, filters: f)
                best = min(best, r.elapsedTime)
                matches = r.totalMatches
            }
            print("[search filters] 200k nodes, all filters: \(String(format: "%.1f", best * 1000))ms, \(matches) matches")
            #expect(matches > 0, "control: the filter combination actually matches something")
            // Same reasoning as the duplicate benchmark: the meaningful number is release
            // (~23 ms). Debug on a contended runner needs headroom, but a filter that
            // stopped being O(1) per node would miss even the loose bound by a wide margin.
            #if DEBUG
            #expect(best < 2.0, "search must stay in instant range, took \(best * 1000)ms")
            #else
            #expect(best < 0.2, "search must stay in instant range, took \(best * 1000)ms")
            #endif
        }

        /// Building the scope bitset is the one added pass over the whole tree, so it gets its
        /// own bound - an O(depth) ancestor walk per node is what this design avoids.
        @Test("Scope bitset construction is a single cheap pass")
        func scopeBitsetIsCheap() {
            let tree = FileTree()
            var root = FileNode(); root.isDirectory = true
            tree.addNode(root, name: "root")
            var kids: [(node: FileNode, name: String)] = []
            for i in 0..<100_000 {
                var n = FileNode(); n.fileSize = 1
                kids.append((node: n, name: "f\(i)"))
            }
            tree.addChildren(kids, parentIndex: 0)
            let nodes = tree.nodesSnapshot()

            var best = Double.greatestFiniteMagnitude
            for _ in 0..<5 {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = SearchEngine.scopeBitset(rootIndex: 0, nodes: nodes)
                best = min(best, CFAbsoluteTimeGetCurrent() - t0)
            }
            print("[search filters] scope bitset over 100k nodes: \(String(format: "%.2f", best * 1000))ms")
            #if DEBUG
            #expect(best < 0.5, "bitset build took \(best * 1000)ms")
            #else
            #expect(best < 0.05, "bitset build took \(best * 1000)ms")
            #endif
        }
    }

} // extension PerformanceSensitiveSuites
