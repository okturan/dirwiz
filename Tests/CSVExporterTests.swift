import Testing
import Foundation
@testable import DirWizCore

/// Contract tests for `CSVExporter`, extracted from `ContentView.buildCSV`/`csvQuote`
/// in plan 018. These pin the header text, the largest-first walk order, the row-cap
/// off-by-one (the cap check counts the header row that's already in `lines`), the
/// formula-injection/quoting guard, and extension parsing — so the extraction can't
/// silently change exported output.
@Suite("CSVExporter Tests")
struct CSVExporterTests {

    // MARK: - Helpers

    private func scan(_ layout: [String: UInt64]) async throws -> (tree: FileTree, cleanup: () -> Void) {
        let (path, cleanup) = try createTempTree(layout)
        let scanner = FileScanner()
        let tree = FileTree()
        await scanner.scan(path: path, progress: ScanProgress(), tree: tree)
        return (tree, cleanup)
    }

    /// Split a CSV export into its lines, dropping the single empty trailing element
    /// produced by splitting on the exporter's trailing "\n".
    private func lines(_ csv: String) -> [String] {
        var result = csv.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    /// The Path column up to (but not including) the first comma. Only valid for
    /// fixtures whose paths contain no comma/quote/newline, i.e. where the field is
    /// never quoted — fixtures with special characters are checked via full-substring
    /// matches instead (see `pathQuotingContract`).
    private func pathColumn(_ row: String) -> String {
        String(row.prefix { $0 != "," })
    }

    /// Look up a node's flat-array index by exact name match. Test-only: production
    /// code (and CSVExporter itself) never needs to search by name.
    private func nodeIndex(in tree: FileTree, named targetName: String) -> UInt32? {
        let (nodes, stringPool, _) = tree.pathBuildingSnapshot()
        for (i, node) in nodes.enumerated() {
            let start = Int(node.nameOffset)
            let end = start + Int(node.nameLength)
            guard end <= stringPool.count else { continue }
            if String(data: stringPool[start..<end], encoding: .utf8) == targetName {
                return UInt32(i)
            }
        }
        return nil
    }

    // MARK: - Header row

    @Test("Header row matches the pinned schema exactly")
    func headerRowExact() async throws {
        let (tree, cleanup) = try await scan(["a.txt": 10])
        defer { cleanup() }

        let csv = CSVExporter().export(tree: tree, rootIndex: 0)
        #expect(
            lines(csv).first
                == "Path,Type,On Disk (bytes),On Disk (human),Logical Size (bytes),Extension,Depth"
        )
    }

    // MARK: - Byte-identical reproduction

    /// Pins the exact row format (field order, separators, trailing newline) by
    /// rebuilding the expected row from values read back off the scanned node, rather
    /// than hardcoding sizes that depend on the filesystem's real block allocation.
    /// `rootIndex` is pointed at the file itself (not the tree root) so the export
    /// contains exactly one data row with no directory-aggregation involved.
    @Test("Full export for a single-file root reproduces the pinned row format byte-for-byte")
    func fullExportByteIdenticalForKnownTree() async throws {
        let (tree, cleanup) = try await scan(["note.txt": 1234])
        defer { cleanup() }

        let fileIndex = try #require(nodeIndex(in: tree, named: "note.txt"))
        let node = try #require(tree.node(at: fileIndex))
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()
        let expectedPath = FileTree.pathFromSnapshot(
            at: fileIndex, nodes: nodes, stringPool: stringPool, rootPath: rootPath
        )
        let expectedHuman = SizeFormatter.shared.format(node.displaySize)

        let csv = CSVExporter().export(tree: tree, rootIndex: fileIndex)
        let expected = "Path,Type,On Disk (bytes),On Disk (human),Logical Size (bytes),Extension,Depth\n"
            + "\(expectedPath),file,\(node.displaySize),\(expectedHuman),\(node.fileSize),txt,0\n"

        #expect(csv == expected)
    }

    // MARK: - Largest-first walk order

    @Test("Children are visited largest-first by on-disk size")
    func largestFirstOrder() async throws {
        let (tree, cleanup) = try await scan([
            "small.txt": 10,
            "medium.txt": 100_000,
            "large.txt": 500_000,
        ])
        defer { cleanup() }

        let csv = CSVExporter().export(tree: tree, rootIndex: 0)
        let dataRows = Array(lines(csv).dropFirst())
        #expect(dataRows.count == 4, "root + 3 files")

        #expect(pathColumn(dataRows[0]) == tree.rootPath, "root itself is always the first row")
        #expect(pathColumn(dataRows[1]).hasSuffix("large.txt"))
        #expect(pathColumn(dataRows[2]).hasSuffix("medium.txt"))
        #expect(pathColumn(dataRows[3]).hasSuffix("small.txt"))
    }

    // MARK: - maxRows cap

    @Test("maxRows caps data rows; the cap check counts the header row already appended")
    func maxRowsCapsDataRows() async throws {
        var layout: [String: UInt64] = [:]
        for i in 0..<8 { layout["file\(i).txt"] = 100 }
        let (tree, cleanup) = try await scan(layout)
        defer { cleanup() }

        let csv = CSVExporter().export(tree: tree, rootIndex: 0, maxRows: 5)
        let allLines = lines(csv)

        // header (1) + 5 data rows: `lines.count <= maxRows` is checked with the
        // header already counted, so exactly `maxRows` data rows come out of the 9
        // available nodes (root + 8 files), not maxRows + 1.
        #expect(allLines.count == 6)
        let dataRows = allLines.dropFirst()
        #expect(
            dataRows.filter { $0.contains(".txt") }.count == 4,
            "root's own row plus 4 of the 8 files fit before the cap stops the walk"
        )
    }

    @Test("maxRows larger than the tree does not pad output")
    func maxRowsAboveTreeSizeIsNoOp() async throws {
        let (tree, cleanup) = try await scan(["only.txt": 10])
        defer { cleanup() }

        let csv = CSVExporter().export(tree: tree, rootIndex: 0, maxRows: 500)
        #expect(lines(csv).count == 3, "header + root + only.txt, well under the cap")
    }

    // MARK: - csvQuote contract

    @Test("Path fields containing a comma, quote, or newline are quoted and escaped")
    func pathQuotingContract() async throws {
        let (tree, cleanup) = try await scan([
            "a,b.txt": 10,
            "a\"b.txt": 10,
            "a\nb.txt": 10,
        ])
        defer { cleanup() }

        let csv = CSVExporter().export(tree: tree, rootIndex: 0)
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()

        for name in ["a,b.txt", "a\"b.txt", "a\nb.txt"] {
            let index = try #require(nodeIndex(in: tree, named: name))
            let rawPath = FileTree.pathFromSnapshot(
                at: index, nodes: nodes, stringPool: stringPool, rootPath: rootPath
            )
            let expectedQuoted = "\"" + rawPath.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            #expect(csv.contains(expectedQuoted), "expected quoted path for \(name)")
        }
    }

    @Test("Extensions starting with =, +, -, or @ get a tab prefix to neutralize formula injection")
    func extensionFormulaInjectionGuard() async throws {
        let (tree, cleanup) = try await scan([
            "f1.=eq": 10,
            "f2.+plus": 10,
            "f3.-dash": 10,
            "f4.@at": 10,
        ])
        defer { cleanup() }

        let csv = CSVExporter().export(tree: tree, rootIndex: 0)
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()

        for (fileName, ext) in [
            ("f1.=eq", "=eq"), ("f2.+plus", "+plus"), ("f3.-dash", "-dash"), ("f4.@at", "@at"),
        ] {
            let index = try #require(nodeIndex(in: tree, named: fileName))
            let path = FileTree.pathFromSnapshot(
                at: index, nodes: nodes, stringPool: stringPool, rootPath: rootPath
            )
            let row = try #require(lines(csv).first { $0.hasPrefix(path + ",") })
            let fields = row.components(separatedBy: ",")
            #expect(
                fields[5] == "\t\(ext)",
                "extension starting with a formula-injection char gets a tab prefix, but isn't quoted since it has no comma/quote/newline"
            )
        }
    }

    // MARK: - Extension column parsing

    @Test("Extension column: dotted, leading-dot, and no-dot names")
    func extensionColumnParsing() async throws {
        let (tree, cleanup) = try await scan([
            "archive.tar.gz": 10,
            ".gitignore": 10,
            "Makefile": 10,
        ])
        defer { cleanup() }

        let csv = CSVExporter().export(tree: tree, rootIndex: 0)
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()

        func extensionField(for name: String) throws -> String {
            let index = try #require(nodeIndex(in: tree, named: name))
            let path = FileTree.pathFromSnapshot(
                at: index, nodes: nodes, stringPool: stringPool, rootPath: rootPath
            )
            let row = try #require(lines(csv).first { $0.hasPrefix(path + ",") })
            return row.components(separatedBy: ",")[5]
        }

        #expect(try extensionField(for: "archive.tar.gz") == "gz", "extension is the substring after the LAST dot")
        #expect(try extensionField(for: ".gitignore") == "", "leading-dot names have no extension")
        #expect(try extensionField(for: "Makefile") == "", "no-dot names have no extension")
    }
}
