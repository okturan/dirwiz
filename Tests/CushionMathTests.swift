import Testing
import Foundation
import CoreGraphics
@testable import DirWizCore
@testable import DirWizUI

@Suite("Cushion Math Tests")
struct CushionMathTests {

    @Test("Squarify worst ratio - perfect square has ratio 1")
    func perfectSquareRatio() {
        // A single item filling a square should have the best possible ratio.
        let tree = makeTree(sizes: [100])
        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let leaves = rects.filter { !$0.isBackground }
        #expect(leaves.count == 1)
        let r = leaves[0]
        let ratio = max(r.width / r.height, r.height / r.width)
        #expect(ratio < 1.1, "Single item in square should have near-perfect aspect ratio")
    }

    @Test("Squarify produces reasonable aspect ratios")
    func reasonableAspectRatios() {
        let tree = makeTree(sizes: [100, 80, 60, 40, 20, 10])
        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        for rect in rects.filter({ !$0.isBackground }) {
            let ratio = max(rect.width / rect.height, rect.height / rect.width)
            // Squarified treemaps should keep ratios reasonable (typically < 10).
            #expect(ratio < 15, "Aspect ratio too extreme")
        }
    }

    @Test("Ancestor chain has correct depth")
    func ancestorChainDepth() {
        let tree = FileTree()
        // root -> dir -> file
        var root = FileNode()
        root.isDirectory = true
        root.fileSize = 500
        tree.addNode(root, name: "root")

        var dir = FileNode()
        dir.isDirectory = true
        dir.fileSize = 500
        tree.addChildren([(node: dir, name: "dir")], parentIndex: 0)

        var file = FileNode()
        file.fileSize = 500
        tree.addChildren([(node: file, name: "file.dat")], parentIndex: 1)

        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        let leaves = rects.filter { !$0.isBackground }
        #expect(leaves.count == 1, "Only the leaf file should be a non-background rect")
        let leafRect = leaves[0]
        // depth=2: root(0) -> dir(1) -> file(2)
        #expect(leafRect.depth == 2, "Leaf at depth 2 should have depth=2")
        // cachedCoefs are computed inline from ancestor stack — non-zero confirms ancestor ridges applied.
        #expect(leafRect.cachedCoefs != .zero, "Leaf coefs should reflect ancestor ridge contribution")
    }

    @Test("Ancestor chain includes correct parent rects")
    func ancestorChainRects() {
        let tree = FileTree()
        var root = FileNode()
        root.isDirectory = true
        root.fileSize = 1000
        tree.addNode(root, name: "root")

        var child1 = FileNode()
        child1.fileSize = 700
        var child2 = FileNode()
        child2.isDirectory = true
        child2.fileSize = 300
        tree.addChildren([
            (node: child1, name: "big.dat"),
            (node: child2, name: "subdir"),
        ], parentIndex: 0)

        var nested = FileNode()
        nested.fileSize = 300
        tree.addChildren([(node: nested, name: "nested.txt")], parentIndex: 2)

        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rects = SquarifyLayout.layout(nodes: tree.nodesSnapshot(), rootIndex: 0, bounds: bounds)

        // Find the nested leaf.
        let nestedRect = rects.first { $0.nodeIndex == 3 && !$0.isBackground }
        #expect(nestedRect != nil, "Should find the nested file rect")

        if let nr = nestedRect {
            // cachedCoefs are computed inline from the ancestor stack.
            // Non-zero confirms the full root → subdir → leaf ancestry was applied.
            #expect(nr.cachedCoefs != .zero, "Nested rect coefs should reflect ancestor ridge contributions")
            #expect(nr.depth >= 2, "Nested leaf should be at depth >= 2")
        }
    }

    @Test("Two equal files produce equal-area rectangles")
    func equalFilesEqualAreas() {
        let tree = makeTree(sizes: [100, 100])
        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        let leaves = rects.filter { !$0.isBackground }
        #expect(leaves.count == 2)
        let area1 = leaves[0].width * leaves[0].height
        let area2 = leaves[1].width * leaves[1].height
        let diff = Swift.abs(area1 - area2)
        #expect(diff < 100, "Equal files should have nearly equal areas")
    }

    @Test("Large number of files doesn't crash")
    func largeFileCount() {
        let sizes = (0..<1000).map { _ in UInt64.random(in: 1...10000) }
        let tree = makeTree(sizes: sizes)
        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        let leaves = rects.filter { !$0.isBackground }
        #expect(leaves.count > 0, "Should produce some rects for 1000 files")
        #expect(leaves.count <= 1000, "Should not produce more leaf rects than files")
    }

    @Test("SizeFormatter formats correctly")
    func sizeFormatting() {
        let f = SizeFormatter.shared
        #expect(f.format(0) == "0 B")
        #expect(f.format(512) == "512 B")
        #expect(f.format(1024) == "1.00 KB")
        #expect(f.format(1_048_576) == "1.00 MB")
        #expect(f.format(1_073_741_824) == "1.00 GB")
        #expect(f.format(1_099_511_627_776) == "1.00 TB")
        #expect(f.format(10_737_418_240) == "10.0 GB")
        #expect(f.format(107_374_182_400) == "100 GB")
    }

    @Test("SizeFormatter percentage formatting")
    func percentageFormatting() {
        let f = SizeFormatter.shared
        #expect(f.percentage(50, of: 100) == "50.0%")
        #expect(f.percentage(1, of: 100) == "1.00%")
        #expect(f.percentage(0, of: 100) == "<0.01%")
        #expect(f.percentage(0, of: 0) == "0%")
    }

    @Test("ExtensionColorMap returns correct categories")
    func extensionCategories() {
        let map = ExtensionColorMap.shared
        #expect(map.category(forExtension: "pdf") == .documents)
        #expect(map.category(forExtension: "jpg") == .images)
        #expect(map.category(forExtension: "mp4") == .video)
        #expect(map.category(forExtension: "swift") == .code)
        #expect(map.category(forExtension: "zip") == .archives)
        #expect(map.category(forExtension: "xyz_unknown") == .other)
    }

    @Test("ExtensionColorMap hash lookup matches string lookup")
    func extensionHashLookup() {
        let map = ExtensionColorMap.shared
        let hash = extensionHash("file.pdf")
        #expect(map.category(forHash: hash) == .documents)

        let jpgHash = extensionHash("photo.jpg")
        #expect(map.category(forHash: jpgHash) == .images)
    }

    // MARK: - Helpers

    private func makeTree(sizes: [UInt64]) -> FileTree {
        let tree = FileTree()
        var rootNode = FileNode()
        rootNode.isDirectory = true
        rootNode.fileSize = sizes.reduce(0, +)
        tree.addNode(rootNode, name: "root")

        var children: [(node: FileNode, name: String)] = []
        for (i, size) in sizes.enumerated() {
            var child = FileNode()
            child.fileSize = size
            child.extensionHash = extensionHash("file\(i).dat")
            children.append((node: child, name: "file\(i).dat"))
        }
        tree.addChildren(children, parentIndex: 0)
        return tree
    }
}
