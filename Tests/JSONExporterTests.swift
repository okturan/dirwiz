import Testing
import Foundation
@testable import DirWizCore

/// Contract tests for `JSONExporter`. Written against the pre-rewrite implementation
/// (`JSONSerialization` over a `[String: Any]` graph) and re-run unchanged against the
/// streaming rewrite — these pin field names, value types, nesting, and filtering
/// semantics so the rewrite can't silently change the exported schema.
///
/// Structure is asserted via `JSONSerialization` parsing, not raw bytes: key order and
/// exact byte layout are not part of the contract, only that the same fields/values/
/// nesting come out.
@Suite("JSONExporter Tests")
struct JSONExporterTests {

    // MARK: - Helpers

    private func scan(_ layout: [String: UInt64]) async throws -> (tree: FileTree, cleanup: () -> Void) {
        let (path, cleanup) = try createTempTree(layout)
        let scanner = FileScanner()
        let tree = FileTree()
        await scanner.scan(path: path, progress: ScanProgress(), tree: tree)
        return (tree, cleanup)
    }

    private func parse(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        return try #require(obj as? [String: Any])
    }

    /// `dict["children"]` re-keyed by "name". Child order is not part of the contract
    /// (the scanner enqueues concurrently), so tests look children up by name.
    private func childrenByName(_ dict: [String: Any]) -> [String: [String: Any]] {
        guard let children = dict["children"] as? [[String: Any]] else { return [:] }
        var result: [String: [String: Any]] = [:]
        for child in children {
            if let name = child["name"] as? String {
                result[name] = child
            }
        }
        return result
    }

    /// True if the parsed JSON number is integer-typed rather than a float/double —
    /// i.e. the exporter wrote it without a decimal point, so a `UInt64` field
    /// round-trips as an integer and not `123.0`.
    private func isIntegerJSONNumber(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        return type != "f" && type != "d"
    }

    // MARK: - Test 1: Full export schema/structure

    @Test("Full export: schema, fields, and structure match the scanned tree")
    func fullExportMatchesScannedTree() async throws {
        let (tree, cleanup) = try await scan([
            "docs/readme.txt": 100,
            "docs/notes.md": 200,
            "images/photo.jpg": 500,
            "empty_dir/": 0,
        ])
        defer { cleanup() }

        let data = try await JSONExporter().export(tree: tree, options: JSONExportOptions())
        let root = try parse(data)

        #expect(root["name"] as? String == tree.name(at: 0))
        #expect(root["type"] as? String == "directory")
        #expect(root["size"] as? UInt64 == tree.nodes[0].fileSize)
        #expect(isIntegerJSONNumber(root["size"]))
        #expect(root["allocatedSize"] as? UInt64 == tree.nodes[0].allocatedSize)
        #expect(isIntegerJSONNumber(root["allocatedSize"]))
        #expect(root["extension"] == nil, "root temp dir name has no dot")

        let modifiedDate = try #require(root["modifiedDate"] as? String)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let parsedDate = try #require(formatter.date(from: modifiedDate))
        #expect(Int(parsedDate.timeIntervalSince1970) == Int(tree.nodes[0].modifiedDate))

        let rootChildren = childrenByName(root)
        #expect(Set(rootChildren.keys) == ["docs", "images", "empty_dir"])

        // empty_dir never had any children in the raw tree: no "children" key at all.
        let emptyDir = try #require(rootChildren["empty_dir"])
        #expect(emptyDir["type"] as? String == "directory")
        #expect(emptyDir["children"] == nil)
        #expect(emptyDir["extension"] == nil)

        let docs = try #require(rootChildren["docs"])
        #expect(docs["type"] as? String == "directory")
        let docsChildren = childrenByName(docs)
        #expect(docsChildren.count == 2)

        let readme = try #require(docsChildren["readme.txt"])
        #expect(readme["type"] as? String == "file")
        #expect(readme["size"] as? UInt64 == 100)
        #expect(readme["extension"] as? String == "txt")
        #expect(readme["children"] == nil, "files never have a children key")

        let notes = try #require(docsChildren["notes.md"])
        #expect(notes["type"] as? String == "file")
        #expect(notes["size"] as? UInt64 == 200)
        #expect(notes["extension"] as? String == "md")

        let images = try #require(rootChildren["images"])
        let imagesChildren = childrenByName(images)
        #expect(imagesChildren.count == 1)
        let photo = try #require(imagesChildren["photo.jpg"])
        #expect(photo["size"] as? UInt64 == 500)
        #expect(photo["extension"] as? String == "jpg")
    }

    // MARK: - Test 2: maxDepth

    @Test("maxDepth: nodes below cutoff are absent; directory at cutoff has no children key")
    func maxDepthCutoff() async throws {
        let (tree, cleanup) = try await scan([
            "top.txt": 10,
            "a/mid.txt": 20,
            "a/b/deep.txt": 30,
        ])
        defer { cleanup() }

        let options = JSONExportOptions(maxDepth: 1)
        let data = try await JSONExporter().export(tree: tree, options: options)
        let root = try parse(data)

        let rootChildren = childrenByName(root)
        #expect(Set(rootChildren.keys) == ["top.txt", "a"])

        let a = try #require(rootChildren["a"])
        #expect(a["type"] as? String == "directory")
        #expect(a["children"] == nil, "directory AT the depth cutoff has no children key")
    }

    // MARK: - Test 3: minSize

    @Test("minSize: sub-threshold entries pruned; directories pruned by their own aggregate size")
    func minSizeFiltersByAggregateSize() async throws {
        let (tree, cleanup) = try await scan([
            "small.txt": 10,
            "big.txt": 100_000,
            "dir_small/tiny.txt": 5,
            "dir_mixed/tiny2.txt": 5,
            "dir_mixed/big2.txt": 100_000,
        ])
        defer { cleanup() }

        let options = JSONExportOptions(minSize: 50_000)
        let data = try await JSONExporter().export(tree: tree, options: options)
        let root = try parse(data)

        let rootChildren = childrenByName(root)
        #expect(
            Set(rootChildren.keys) == ["big.txt", "dir_mixed"],
            "small.txt (10 bytes) and dir_small (aggregate 5 bytes) are below the 50_000 threshold"
        )

        let dirMixed = try #require(rootChildren["dir_mixed"])
        let mixedChildren = childrenByName(dirMixed)
        #expect(
            Set(mixedChildren.keys) == ["big2.txt"],
            "dir_mixed's own aggregate (100_005) clears the threshold, but tiny2.txt (5 bytes) does not"
        )
    }

    // MARK: - Test 4: includeFiles: false

    @Test("includeFiles false: no file entries anywhere; directory hierarchy intact")
    func includeFilesFalseHidesFiles() async throws {
        let (tree, cleanup) = try await scan([
            "top.txt": 50,
            "docs/readme.txt": 100,
            "docs/notes.md": 200,
            "images/photo.jpg": 500,
            "empty_dir/": 0,
        ])
        defer { cleanup() }

        let options = JSONExportOptions(includeFiles: false)
        let data = try await JSONExporter().export(tree: tree, options: options)
        let root = try parse(data)

        let rootChildren = childrenByName(root)
        #expect(
            Set(rootChildren.keys) == ["docs", "images", "empty_dir"],
            "top.txt is a file and must be excluded"
        )

        func assertNoFiles(_ dict: [String: Any]) {
            #expect(dict["type"] as? String != "file")
            if let children = dict["children"] as? [[String: Any]] {
                for child in children { assertNoFiles(child) }
            }
        }
        assertNoFiles(root)

        // docs/images had children in the raw tree that were all filtered out: the
        // "children" key is present but empty. empty_dir never had children at all:
        // the key is absent entirely. This distinction is part of the contract.
        let docs = try #require(rootChildren["docs"])
        #expect((docs["children"] as? [[String: Any]])?.isEmpty == true)
        let images = try #require(rootChildren["images"])
        #expect((images["children"] as? [[String: Any]])?.isEmpty == true)
        let emptyDir = try #require(rootChildren["empty_dir"])
        #expect(emptyDir["children"] == nil)
    }

    // MARK: - Test 5: prettyPrint

    @Test("prettyPrint true vs false: both parse; only pretty contains newlines")
    func prettyPrintToggle() async throws {
        let (tree, cleanup) = try await scan([
            "docs/readme.txt": 100,
            "images/photo.jpg": 500,
        ])
        defer { cleanup() }

        let prettyData = try await JSONExporter().export(
            tree: tree, options: JSONExportOptions(prettyPrint: true))
        let compactData = try await JSONExporter().export(
            tree: tree, options: JSONExportOptions(prettyPrint: false))

        _ = try parse(prettyData)
        _ = try parse(compactData)

        let prettyString = try #require(String(data: prettyData, encoding: .utf8))
        let compactString = try #require(String(data: compactData, encoding: .utf8))
        #expect(prettyString.contains("\n"))
        #expect(!compactString.contains("\n"))
    }

    // MARK: - Test 6: Special characters round-trip

    @Test("Special characters in filenames round-trip through export and parse")
    func specialCharactersRoundTrip() async throws {
        let names: [String: UInt64] = [
            "quote\".txt": 11,
            "back\\slash.txt": 22,
            "line\nbreak.txt": 33,
            "caf\u{E9}.txt": 44,
        ]
        let (tree, cleanup) = try await scan(names)
        defer { cleanup() }

        let data = try await JSONExporter().export(tree: tree, options: JSONExportOptions())
        let root = try parse(data)
        let rootChildren = childrenByName(root)

        #expect(Set(rootChildren.keys) == Set(names.keys))
        for (name, size) in names {
            let child = try #require(rootChildren[name], "missing round-tripped entry for \(name)")
            #expect(child["size"] as? UInt64 == size)
            #expect(child["extension"] as? String == "txt")
        }
    }
}
