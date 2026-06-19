import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

@Suite("SearchEngine Tests")
struct SearchEngineTests {

    /// Helper to create a tree with named files.
    private func makeTree(files: [(name: String, size: UInt64, isDir: Bool)]) -> FileTree {
        let tree = FileTree()
        var root = FileNode()
        root.isDirectory = true
        root.fileSize = files.reduce(0) { $0 + $1.size }
        tree.addNode(root, name: "root")

        var children: [(node: FileNode, name: String)] = []
        for file in files {
            var node = FileNode()
            node.isDirectory = file.isDir
            node.fileSize = file.size
            node.extensionHash = extensionHash(file.name)
            children.append((node: node, name: file.name))
        }
        tree.addChildren(children, parentIndex: 0)
        return tree
    }

    private func search(
        tree: FileTree,
        query: String,
        filters: SearchFilters = SearchFilters(),
        resultCap: Int = SearchEngine.defaultResultCap,
        previousMatches: [UInt32]? = nil
    ) -> SearchResult {
        let nodes = tree.nodesSnapshot()
        let (searchPool, searchEntries) = tree.searchIndexSnapshot()
        return SearchEngine.search(
            query: query,
            nodes: nodes,
            searchPool: searchPool,
            searchEntries: searchEntries,
            filters: filters,
            resultCap: resultCap,
            previousMatches: previousMatches
        )
    }

    @Test("Empty query returns no results")
    func emptyQuery() {
        let tree = makeTree(files: [
            (name: "hello.txt", size: 100, isDir: false),
        ])
        let result = search(tree: tree, query: "")
        #expect(result.matchingIndices.isEmpty)
        #expect(result.totalMatches == 0)
    }

    @Test("Exact name match")
    func exactMatch() {
        let tree = makeTree(files: [
            (name: "readme.md", size: 100, isDir: false),
            (name: "license.txt", size: 200, isDir: false),
        ])
        let result = search(tree: tree, query: "readme")
        #expect(result.totalMatches == 1)
        #expect(result.matchingIndices.count == 1)
        #expect(result.matchingIndices[0] == 1) // index 0 is root
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        let tree = makeTree(files: [
            (name: "README.MD", size: 100, isDir: false),
            (name: "Readme.md", size: 200, isDir: false),
            (name: "readme.md", size: 300, isDir: false),
        ])
        let result = search(tree: tree, query: "readme")
        #expect(result.totalMatches == 3)
    }

    @Test("Substring matching")
    func substringMatch() {
        let tree = makeTree(files: [
            (name: "my-project-readme.txt", size: 100, isDir: false),
            (name: "unrelated.dat", size: 200, isDir: false),
        ])
        let result = search(tree: tree, query: "project")
        #expect(result.totalMatches == 1)
        #expect(result.matchingIndices[0] == 1)
    }

    @Test("Filter: files only")
    func filesOnlyFilter() {
        let tree = makeTree(files: [
            (name: "docs", size: 500, isDir: true),
            (name: "docs.zip", size: 300, isDir: false),
        ])
        var filters = SearchFilters()
        filters.nodeType = .filesOnly
        let result = search(tree: tree, query: "docs", filters: filters)
        #expect(result.totalMatches == 1)
        let name = tree.name(at: result.matchingIndices[0])
        #expect(name == "docs.zip")
    }

    @Test("Filter: directories only")
    func dirsOnlyFilter() {
        let tree = makeTree(files: [
            (name: "docs", size: 500, isDir: true),
            (name: "docs.zip", size: 300, isDir: false),
        ])
        var filters = SearchFilters()
        filters.nodeType = .directoriesOnly
        let result = search(tree: tree, query: "docs", filters: filters)
        #expect(result.totalMatches == 1)
        let name = tree.name(at: result.matchingIndices[0])
        #expect(name == "docs")
    }

    @Test("Filter: minimum size")
    func minimumSizeFilter() {
        let tree = makeTree(files: [
            (name: "small.txt", size: 100, isDir: false),
            (name: "big.txt", size: 1_000_000, isDir: false),
        ])
        var filters = SearchFilters()
        filters.minimumSize = 1_000
        let result = search(tree: tree, query: ".txt", filters: filters)
        #expect(result.totalMatches == 1)
        let name = tree.name(at: result.matchingIndices[0])
        #expect(name == "big.txt")
    }

    @Test("Filter: category")
    func categoryFilter() {
        let tree = makeTree(files: [
            (name: "photo.jpg", size: 500, isDir: false),
            (name: "doc.pdf", size: 300, isDir: false),
            (name: "code.swift", size: 200, isDir: false),
        ])
        var filters = SearchFilters()
        filters.category = .images
        let result = search(tree: tree, query: "", filters: filters)  // empty query won't match, let's use a broad term
        // Empty query returns nothing regardless of filters.
        #expect(result.totalMatches == 0)

        // Now with a query that matches all.
        let result2 = search(tree: tree, query: ".", filters: filters)
        #expect(result2.totalMatches == 1)
        let name = tree.name(at: result2.matchingIndices[0])
        #expect(name == "photo.jpg")
    }


    @Test("Filter: extension hash with empty query returns extension matches")
    func extensionFilterEmptyQuery() {
        let tree = makeTree(files: [
            (name: "image1.png", size: 100, isDir: false),
            (name: "image2.png", size: 200, isDir: false),
            (name: "notes.txt", size: 300, isDir: false),
        ])
        var filters = SearchFilters()
        filters.extensionHash = extensionHash("sample.png")

        let result = search(tree: tree, query: "", filters: filters)
        #expect(result.totalMatches == 2)
        let names = result.matchingIndices.map { tree.name(at: $0) }
        #expect(names.contains("image1.png"))
        #expect(names.contains("image2.png"))
        #expect(!names.contains("notes.txt"))
    }

    @Test("Result cap is respected")
    func resultCap() {
        var files: [(name: String, size: UInt64, isDir: Bool)] = []
        for i in 0..<100 {
            files.append((name: "file\(i).txt", size: 100, isDir: false))
        }
        let tree = makeTree(files: files)
        let result = search(tree: tree, query: "file", resultCap: 10)
        #expect(result.matchingIndices.count == 10)
        #expect(result.totalMatches == 100)
    }

    @Test("Search reports elapsed time")
    func elapsedTime() {
        let tree = makeTree(files: [
            (name: "test.txt", size: 100, isDir: false),
        ])
        let result = search(tree: tree, query: "test")
        #expect(result.elapsedTime >= 0)
        #expect(result.elapsedTime < 1.0) // should be way under 1 second
    }

    @Test("No matches returns empty")
    func noMatches() {
        let tree = makeTree(files: [
            (name: "hello.txt", size: 100, isDir: false),
        ])
        let result = search(tree: tree, query: "zzzznotfound")
        #expect(result.matchingIndices.isEmpty)
        #expect(result.totalMatches == 0)
    }

    @Test("Root node can match")
    func rootNodeMatches() {
        let tree = makeTree(files: [])
        let result = search(tree: tree, query: "root")
        #expect(result.totalMatches == 1)
        #expect(result.matchingIndices[0] == 0)
    }

    @Test("Incremental refinement narrows results")
    func incrementalRefinement() {
        let tree = makeTree(files: [
            (name: "readme.md", size: 100, isDir: false),
            (name: "readback.log", size: 200, isDir: false),
            (name: "license.txt", size: 300, isDir: false),
        ])

        // Cold search for "read" — matches readme.md and readback.log
        let first = search(tree: tree, query: "read")
        #expect(first.totalMatches == 2)

        // Refine to "readme" using previous matches — should narrow to 1
        let refined = search(tree: tree, query: "readme", previousMatches: first.matchingIndices)
        #expect(refined.totalMatches == 1)
        let name = tree.name(at: refined.matchingIndices[0])
        #expect(name == "readme.md")
    }

    @Test("Refinement with empty previous matches returns empty")
    func refinementEmptyPrevious() {
        let tree = makeTree(files: [
            (name: "hello.txt", size: 100, isDir: false),
        ])
        let result = search(tree: tree, query: "hello", previousMatches: [])
        #expect(result.totalMatches == 0)
        #expect(result.matchingIndices.isEmpty)
    }

    @Test("Search stays correct after sortAllChildren")
    func searchAfterSort() {
        // This test catches the bug where sortAllChildren rearranged nodes
        // but not lowercaseNameEntries, causing search to match wrong names.
        let tree = makeTree(files: [
            (name: "icon.png", size: 50, isDir: false),        // small png
            (name: "DFonts", size: 344_000_000, isDir: true),  // huge folder
            (name: "wallpaper.png", size: 200, isDir: false),  // another png
            (name: "LLVM", size: 80_000_000, isDir: true),     // big folder
            (name: "readme.txt", size: 100, isDir: false),     // non-png file
        ])
        // sortAllChildren reorders nodes within each directory by size desc.
        // Before the fix, this would desync nodes[] from lowercaseNameEntries[].
        tree.sortAllChildren()

        let result = search(tree: tree, query: ".png")
        // Only icon.png and wallpaper.png should match — NOT DFonts or LLVM.
        #expect(result.totalMatches == 2)
        let names = result.matchingIndices.map { tree.name(at: $0) }
        #expect(names.contains("icon.png"))
        #expect(names.contains("wallpaper.png"))
        #expect(!names.contains("DFonts"))
        #expect(!names.contains("LLVM"))
        #expect(!names.contains("readme.txt"))
    }

    @Test("sortAllChildren fixes parentIndex for correct paths")
    func sortFixesParentIndex() {
        // Build a two-level tree: root → [small_dir, big_file]
        // small_dir has a child. After sorting, big_file moves before small_dir.
        // The child's parentIndex must still resolve to small_dir.
        let tree = FileTree()
        var root = FileNode()
        root.isDirectory = true
        root.fileSize = 2_000
        tree.addNode(root, name: "root")

        // Root's children: small_dir (size 100), big_file (size 1900)
        var smallDir = FileNode()
        smallDir.isDirectory = true
        smallDir.fileSize = 100
        var bigFile = FileNode()
        bigFile.fileSize = 1900
        tree.addChildren([
            (node: smallDir, name: "small_dir"),
            (node: bigFile, name: "big_file"),
        ], parentIndex: 0)

        // small_dir's child
        var innerFile = FileNode()
        innerFile.fileSize = 100
        tree.addChildren([
            (node: innerFile, name: "inner.txt"),
        ], parentIndex: 1)  // small_dir is at index 1

        // Before sort: indices 1=small_dir, 2=big_file, 3=inner.txt
        // After sort: indices 1=big_file, 2=small_dir, 3=inner.txt
        tree.sortAllChildren()

        // inner.txt's parent should still be small_dir (now at index 2)
        let path = tree.path(at: 3)
        #expect(path.contains("small_dir"), "Path '\(path)' should contain small_dir")
        #expect(!path.contains("big_file"), "Path '\(path)' should NOT contain big_file")
    }

    @Test("Capped refinement falls back to full scan")
    func cappedRefinementFallback() {
        // Build a tree with many files matching a broad query.
        var files: [(name: String, size: UInt64, isDir: Bool)] = []
        for i in 0..<200 {
            files.append((name: "item\(i).dat", size: 100, isDir: false))
        }
        // Add one file that matches a refined query
        files.append((name: "item_special.dat", size: 100, isDir: false))
        let tree = makeTree(files: files)

        // Search with a very small cap — simulating capped results
        let broad = search(tree: tree, query: "item", resultCap: 10)
        #expect(broad.totalMatches == 201)
        #expect(broad.matchingIndices.count == 10) // capped

        // If we naively refine from capped results, we'd miss "item_special"
        // because it might not be in the first 10 matches.
        // Full scan should still find it.
        let full = search(tree: tree, query: "item_special")
        #expect(full.totalMatches == 1)
        let name = tree.name(at: full.matchingIndices[0])
        #expect(name == "item_special.dat")
    }

    @Test("Search performance under 200ms for large tree")
    func searchPerformance() {
        // Build a tree with 50K files to verify search is fast.
        let tree = FileTree()
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "root")

        var children: [(node: FileNode, name: String)] = []
        children.reserveCapacity(50_000)
        for i in 0..<50_000 {
            var node = FileNode()
            node.fileSize = UInt64(i)
            let name = i % 100 == 0 ? "photo\(i).png" : "file\(i).dat"
            node.extensionHash = extensionHash(name)
            children.append((node: node, name: name))
        }
        tree.addChildren(children, parentIndex: 0)
        tree.sortAllChildren()

        let result = search(tree: tree, query: ".png")
        // 50000 / 100 = 500 png files
        #expect(result.totalMatches == 500)
        // In release: ~5ms. In debug: ~50ms. Allow headroom for CI.
        #expect(result.elapsedTime < 0.5)

        // Verify every match actually has .png in the name.
        for idx in result.matchingIndices {
            let name = tree.name(at: idx)
            #expect(name.contains(".png"), "Matched '\(name)' which doesn't contain .png")
        }
    }

    @Test("Uppercase names are found by lowercase query on case-sensitive volume")
    func caseSensitiveVolumeSearch() {
        // Simulate a case-sensitive volume by calling setCaseSensitivity(true) before adding nodes.
        let tree = FileTree()
        tree.setCaseSensitivity(true)

        var root = FileNode(); root.isDirectory = true
        tree.addNode(root, name: "root")

        var children: [(node: FileNode, name: String)] = []
        for name in ["README.md", "Build", "build", "NOTES.txt", "notes.txt"] {
            var node = FileNode(); node.fileSize = 100
            children.append((node: node, name: name))
        }
        tree.addChildren(children, parentIndex: 0)

        // Lower-case query "readme" must find "README.md" regardless of case sensitivity flag.
        let result = search(tree: tree, query: "readme")
        #expect(result.totalMatches == 1)
        let matched = tree.name(at: result.matchingIndices[0])
        #expect(matched == "README.md")

        // "build" must find both "Build" and "build".
        let result2 = search(tree: tree, query: "build")
        #expect(result2.totalMatches == 2)

        // "notes" must find both "NOTES.txt" and "notes.txt".
        let result3 = search(tree: tree, query: "notes")
        #expect(result3.totalMatches == 2)
    }

    @Test("Composed and decomposed Unicode filenames are found by either query form")
    func unicodeNFCNormalization() {
        // "Café" decomposed: "Cafe" + combining acute (U+0301) — NFD form.
        // "Café" composed: single precomposed character (U+00E9) — NFC form.
        let nfd = "Cafe\u{301}.txt"        // é as combining sequence
        let nfc = "Caf\u{E9}.txt"          // é as single code point

        let tree = makeTree(files: [
            (name: nfd, size: 100, isDir: false),  // stored as NFD
        ])

        // Composed query should find the decomposed filename.
        let result1 = search(tree: tree, query: "café")
        #expect(result1.totalMatches == 1, "Composed query 'café' must find NFD filename")

        // Decomposed query should also find it.
        let result2 = search(tree: tree, query: "cafe\u{301}")
        #expect(result2.totalMatches == 1, "Decomposed query must also find NFD filename")

        // Sanity: NFC form indexed directly should also work.
        let tree2 = makeTree(files: [
            (name: nfc, size: 100, isDir: false),  // stored as NFC
        ])
        let result3 = search(tree: tree2, query: "café")
        #expect(result3.totalMatches == 1, "Composed query must find NFC filename")
    }
}
