import Foundation

/// Exports a `FileTree` as a flat CSV report. Moved out of `DirWiz/ContentView.swift`
/// (plan 018) so the walk order, row cap, and quoting/formula-injection guard are
/// testable and reusable outside the app target.
public struct CSVExporter: Sendable {
    public init() {}

    /// Walk the tree depth-first from `rootIndex`, visiting each directory's children
    /// largest-first (by on-disk size), capped at `maxRows` data rows (the header row
    /// does not count against the cap).
    public func export(tree: FileTree, rootIndex: UInt32, maxRows: Int = 500) -> String {
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()

        struct StackEntry { var index: UInt32; var depth: Int }
        var stack: [StackEntry] = [StackEntry(index: rootIndex, depth: 0)]
        var lines: [String] = ["Path,Type,On Disk (bytes),On Disk (human),Logical Size (bytes),Extension,Depth"]
        lines.reserveCapacity(maxRows + 2)

        while !stack.isEmpty && lines.count <= maxRows {
            let entry = stack.removeLast()
            let i = Int(entry.index)
            guard i < nodes.count else { continue }
            let node = nodes[i]

            let path = FileTree.pathFromSnapshot(
                at: entry.index, nodes: nodes, stringPool: stringPool, rootPath: rootPath
            )
            let ext: String
            if node.isDirectory {
                ext = ""
            } else {
                let nameStart = Int(node.nameOffset)
                let nameEnd = min(nameStart + Int(node.nameLength), stringPool.count)
                if let name = String(data: stringPool[nameStart..<nameEnd], encoding: .utf8),
                   let dot = name.range(of: ".", options: .backwards),
                   dot.lowerBound != name.startIndex {
                    ext = String(name[name.index(after: dot.lowerBound)...])
                } else {
                    ext = ""
                }
            }

            lines.append([
                Self.csvQuote(path),
                node.isDirectory ? "directory" : "file",
                "\(node.displaySize)",
                Self.csvQuote(SizeFormatter.shared.format(node.displaySize)),
                "\(node.fileSize)",
                Self.csvQuote(ext),
                "\(entry.depth)",
            ].joined(separator: ","))

            guard node.isDirectory, node.firstChildIndex != FileNode.invalid,
                  node.childCount > 0 else { continue }
            let start = Int(node.firstChildIndex)
            let end = min(start + Int(node.childCount), nodes.count)
            guard start < end else { continue }
            // Push smallest-first so the largest child pops first (LIFO).
            let childIndices = (start..<end).sorted { nodes[$0].displaySize < nodes[$1].displaySize }
            for ci in childIndices {
                stack.append(StackEntry(index: UInt32(ci), depth: entry.depth + 1))
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Prefix with a tab to neutralize spreadsheet formula injection (filenames
    /// starting with =, +, -, @ are treated as formulas in Excel/Sheets), then quote
    /// the field if it contains a comma, quote, or newline.
    private static func csvQuote(_ value: String) -> String {
        let safe: String
        if let first = value.first, "=+-@\t".contains(first) {
            safe = "\t" + value
        } else {
            safe = value
        }
        guard safe.contains(",") || safe.contains("\"") || safe.contains("\n") else {
            return safe
        }
        return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
