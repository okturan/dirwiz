import Testing
import Foundation
@testable import DirWizLib

@Suite("TreeTable Performance Tests")
struct TreeTablePerformanceTests {

    @Test("flattenedItemsBuildsQuickly")
    func flattenedItemsBuildsQuickly() {
        let tree = makeTreeWith5000Nodes()

        // Warm cache/code paths before timing.
        _ = flattenedAllVisibleItems(tree: tree)

        let clock = ContinuousClock()
        let start = clock.now
        let items = flattenedAllVisibleItems(tree: tree)
        let elapsed = clock.now - start
        let elapsedSeconds = seconds(elapsed)

        #expect(items.count == 5_000)
        #expect(elapsedSeconds < 0.010, "Expected < 10ms, got \(elapsedSeconds)s")
    }

    @Test("revealScrollDelayIsAdequate")
    func revealScrollDelayIsAdequate() throws {
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testDir.deletingLastPathComponent()
        let sourcePath = repoRoot.appendingPathComponent("Sources/Views/TreeTableView.swift").path
        let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
        let pattern = #"\.now\(\)\s*\+\s*([0-9]*\.?[0-9]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        let delays: [Double] = matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return nil }
            return Double(nsSource.substring(with: range))
        }

        guard let revealDelay = delays.max() else {
            Issue.record("Could not find asyncAfter delay in TreeTableView.swift")
            return
        }

        #expect(revealDelay >= 0.10, "Expected reveal delay >= 0.10s, got \(revealDelay)s")
    }

    private func makeTreeWith5000Nodes() -> FileTree {
        let tree = FileTree()

        var root = FileNode()
        root.isDirectory = true
        root.fileSize = 500 * (100 + ((10...18).reduce(0, +)))
        _ = tree.addNode(root, name: "root")

        var rootChildren: [(node: FileNode, name: String)] = []
        rootChildren.reserveCapacity(500)

        for i in 0..<500 {
            var dir = FileNode()
            dir.isDirectory = true
            dir.fileSize = 100 + ((10...18).reduce(0, +))
            rootChildren.append((node: dir, name: "dir\(i)"))
        }

        _ = tree.addChildren(rootChildren, parentIndex: 0)

        for i in 0..<500 {
            let dirIndex = UInt32(1 + i)
            var files: [(node: FileNode, name: String)] = []
            files.reserveCapacity(9)

            for j in 0..<9 {
                var file = FileNode()
                file.isDirectory = false
                file.fileSize = UInt64(10 + j)
                files.append((node: file, name: "file\(i)-\(j).txt"))
            }
            _ = tree.addChildren(files, parentIndex: dirIndex)
        }

        return tree
    }

    private func flattenedAllVisibleItems(tree: FileTree) -> [TreeNodeItem] {
        let nodes = tree.nodesSnapshot()
        var result: [TreeNodeItem] = []
        result.reserveCapacity(nodes.count)

        let roots = rootChildren(tree: tree, nodes: nodes)
        for item in roots {
            collectAllVisible(item, into: &result)
        }
        return result
    }

    private func rootChildren(tree: FileTree, nodes: [FileNode]) -> [TreeNodeItem] {
        let children = TreeNodeItem(
            id: 0,
            tree: tree,
            nodes: nodes,
            depth: -1,
            sortKey: .size,
            sortAscending: false
        ).children

        if children.isEmpty {
            return [TreeNodeItem(id: 0, tree: tree, nodes: nodes, depth: 0, sortKey: .size, sortAscending: false)]
        }
        return children
    }

    private func collectAllVisible(_ item: TreeNodeItem, into result: inout [TreeNodeItem]) {
        result.append(item)
        guard item.isDirectory else { return }
        for child in item.children {
            collectAllVisible(child, into: &result)
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
