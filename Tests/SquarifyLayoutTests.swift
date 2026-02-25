import Testing
import CoreGraphics
@testable import DirWizLib

@Suite("Squarify Layout Tests")
struct SquarifyLayoutTests {

    /// Helper to create a simple tree with a root and N leaf children of given sizes.
    private func makeTree(childSizes: [UInt64]) -> FileTree {
        let tree = FileTree()
        var rootNode = FileNode()
        rootNode.isDirectory = true
        rootNode.fileSize = childSizes.reduce(0, +)
        let rootIndex = tree.addNode(rootNode, name: "root")

        var children: [(node: FileNode, name: String)] = []
        for (i, size) in childSizes.enumerated() {
            var child = FileNode()
            child.fileSize = size
            child.extensionHash = extensionHash("file\(i).txt")
            children.append((node: child, name: "file\(i).txt"))
        }
        tree.addChildren(children, parentIndex: rootIndex)
        return tree
    }

    @Test("Layout produces rectangles for all children")
    func layoutAllChildren() {
        let tree = makeTree(childSizes: [100, 50, 30, 20])
        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        #expect(rects.count == 4, "Should produce one rect per leaf child")
    }

    @Test("Total area of rectangles matches bounds area")
    func totalAreaMatchesBounds() {
        let tree = makeTree(childSizes: [100, 80, 60, 40, 20])
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rects = SquarifyLayout.layout(nodes: tree.nodesSnapshot(), rootIndex: 0, bounds: bounds)

        let totalArea = rects.reduce(Float(0)) { $0 + $1.width * $1.height }
        let boundsArea = Float(bounds.width * bounds.height)

        // Allow small floating point tolerance.
        let diff = Swift.abs(totalArea - boundsArea)
        #expect(diff < boundsArea * 0.01, "Total rect area should match bounds area within 1%")
    }

    @Test("Rectangles tile without overlap")
    func noOverlap() {
        let tree = makeTree(childSizes: [200, 100, 80, 60, 40, 20, 10, 5])
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let rects = SquarifyLayout.layout(nodes: tree.nodesSnapshot(), rootIndex: 0, bounds: bounds)

        // Check no pair of rects significantly overlaps.
        for i in 0..<rects.count {
            for j in (i+1)..<rects.count {
                let a = rects[i]
                let b = rects[j]

                let overlapX = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
                let overlapY = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
                let overlapArea = overlapX * overlapY

                // Allow up to 1px overlap due to floating point.
                #expect(overlapArea < 2.0,
                    "Rects \(i) and \(j) overlap by \(overlapArea) pixels")
            }
        }
    }

    @Test("All rectangles are within bounds")
    func withinBounds() {
        let tree = makeTree(childSizes: [500, 300, 200, 100, 50])
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let rects = SquarifyLayout.layout(nodes: tree.nodesSnapshot(), rootIndex: 0, bounds: bounds)

        for (i, rect) in rects.enumerated() {
            #expect(rect.x >= -0.5, "Rect \(i) x (\(rect.x)) out of bounds")
            #expect(rect.y >= -0.5, "Rect \(i) y (\(rect.y)) out of bounds")
            #expect(rect.x + rect.width <= Float(bounds.width) + 0.5,
                "Rect \(i) exceeds right bound")
            #expect(rect.y + rect.height <= Float(bounds.height) + 0.5,
                "Rect \(i) exceeds bottom bound")
        }
    }

    @Test("Single child fills entire bounds")
    func singleChildFillsBounds() {
        let tree = makeTree(childSizes: [100])
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        let rects = SquarifyLayout.layout(nodes: tree.nodesSnapshot(), rootIndex: 0, bounds: bounds)

        #expect(rects.count == 1)
        let rect = rects[0]
        #expect(abs(rect.width - 500) < 1.0)
        #expect(abs(rect.height - 300) < 1.0)
    }

    @Test("Larger files get larger rectangles")
    func largerFilesGetLargerRects() {
        let tree = makeTree(childSizes: [1000, 500, 100])
        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        #expect(rects.count == 3)

        // Sort rects by their node index to match the original order.
        let sorted = rects.sorted { $0.nodeIndex < $1.nodeIndex }
        let areas = sorted.map { $0.width * $0.height }

        #expect(areas[0] > areas[1], "1000-byte file should have larger area than 500-byte file")
        #expect(areas[1] > areas[2], "500-byte file should have larger area than 100-byte file")
    }

    @Test("Small rectangles are culled with minPixelSize")
    func smallRectsCulled() {
        // One very large file and many tiny files.
        var sizes: [UInt64] = [1_000_000]
        for _ in 0..<100 {
            sizes.append(1)
        }
        let tree = makeTree(childSizes: sizes)

        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            minPixelSize: 2.0
        )

        // Should have fewer rects than 101 because many tiny files are culled.
        #expect(rects.count < 101, "Tiny rects should be culled: got \(String(describing: rects.count))")
        #expect(rects.count >= 1, "Should have at least the large file")
    }

    @Test("Nested directories produce deeper rects")
    func nestedDirectoriesDepth() {
        let tree = FileTree()

        // root (dir) -> subdir (dir) -> file.txt
        var root = FileNode()
        root.isDirectory = true
        root.fileSize = 100
        tree.addNode(root, name: "root")

        var subdir = FileNode()
        subdir.isDirectory = true
        subdir.fileSize = 100
        tree.addChildren([(node: subdir, name: "subdir")], parentIndex: 0)

        var file = FileNode()
        file.fileSize = 100
        file.extensionHash = extensionHash("data.txt")
        tree.addChildren([(node: file, name: "data.txt")], parentIndex: 1)

        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        #expect(rects.count == 1) // Only the leaf file
        #expect(rects[0].depth == 2, "Nested leaf should have depth 2")
    }

    @Test("Empty directory produces a single rect")
    func emptyDirectory() {
        let tree = FileTree()
        var root = FileNode()
        root.isDirectory = true
        root.fileSize = 0
        tree.addNode(root, name: "empty")

        let rects = SquarifyLayout.layout(
            nodes: tree.nodesSnapshot(),
            rootIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        #expect(rects.count == 1, "Empty directory should produce itself as a rect")
    }
}
