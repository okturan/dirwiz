import Foundation

public struct JSONExportOptions: Sendable {
    public var maxDepth: Int?
    public var minSize: UInt64
    public var includeFiles: Bool
    public var prettyPrint: Bool

    public init(
        maxDepth: Int? = nil,
        minSize: UInt64 = 0,
        includeFiles: Bool = true,
        prettyPrint: Bool = true
    ) {
        self.maxDepth = maxDepth
        self.minSize = minSize
        self.includeFiles = includeFiles
        self.prettyPrint = prettyPrint
    }
}

public struct JSONExporter: Sendable {
    public init() {}

    /// Export tree as hierarchical JSON data.
    ///
    /// Streams bytes directly from the flat node array via `JSONWriter` instead of
    /// materializing the whole tree as a `[String: Any]` graph and handing it to
    /// Foundation's general-purpose JSON serializer — large scans no longer duplicate
    /// every node as boxed Foundation objects before serializing.
    public func export(
        tree: FileTree,
        options: JSONExportOptions = JSONExportOptions()
    ) async throws -> Data {
        let (nodes, stringPool, _) = tree.pathBuildingSnapshot()
        var writer = JSONWriter(pretty: options.prettyPrint)

        guard !nodes.isEmpty else {
            writer.beginObject()
            writer.endObject()
            return writer.data
        }

        // Matches the original behavior: if the root itself is below the size
        // threshold, the whole export degenerates to an empty object (the per-child
        // minSize check below never runs for the root, since it has no parent loop
        // to apply it).
        if options.minSize > 0, nodes[0].displaySize < options.minSize {
            writer.beginObject()
            writer.endObject()
            return writer.data
        }

        try writeTree(nodes: nodes, stringPool: stringPool, options: options, into: &writer)
        return writer.data
    }

    /// Export tree as hierarchical JSON to a file URL.
    public func export(
        tree: FileTree,
        to url: URL,
        options: JSONExportOptions = JSONExportOptions()
    ) async throws {
        let data = try await export(tree: tree, options: options)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Private

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// One entry in the explicit walk stack: a directory whose object and "children"
    /// array are already open, plus the pre-filtered list of child indices still to
    /// be written at `childDepth`.
    private struct PendingDirectory {
        let childIndices: [Int]
        let childDepth: Int
        var position: Int = 0
    }

    /// Iterative (non-recursive) depth-first walk over the flat node array, writing
    /// directly into `writer`. An explicit stack stands in for the call stack used by
    /// the old recursive `buildNode`, so arbitrarily deep trees can't overflow it.
    private func writeTree(
        nodes: [FileNode],
        stringPool: Data,
        options: JSONExportOptions,
        into writer: inout JSONWriter
    ) throws {
        /// Child indices of `index` that survive `includeFiles`/`minSize`, or nil if
        /// `index` shouldn't recurse at all (not a directory, has no children, or is
        /// at the `maxDepth` cutoff). An empty (non-nil) result means the directory
        /// had children before filtering, so it still gets a "children": [] key.
        func filteredChildren(of index: Int, depth: Int) -> [Int]? {
            let node = nodes[index]
            guard node.isDirectory, node.firstChildIndex != FileNode.invalid else { return nil }
            let atDepthLimit = options.maxDepth.map { depth >= $0 } ?? false
            guard !atDepthLimit else { return nil }

            let start = Int(node.firstChildIndex)
            let end = min(start + Int(node.childCount), nodes.count)
            guard start < end else { return nil }

            var result: [Int] = []
            result.reserveCapacity(end - start)
            for ci in start..<end {
                let child = nodes[ci]
                if !options.includeFiles, !child.isDirectory { continue }
                if options.minSize > 0, child.displaySize < options.minSize { continue }
                result.append(ci)
            }
            return result
        }

        /// Writes a node's fixed fields (name/size/allocatedSize/modifiedDate/type/
        /// extension) and leaves its object open — the caller decides whether to open
        /// a "children" array next or close the object immediately.
        func writeHeader(_ index: Int) {
            let node = nodes[index]
            let name = nameFromPool(node: node, stringPool: stringPool)
            let date = Date(timeIntervalSince1970: TimeInterval(node.modifiedDate))

            writer.beginObject()
            writer.key("name")
            writer.string(name)
            writer.key("size")
            writer.uint(node.fileSize)
            writer.key("allocatedSize")
            writer.uint(node.allocatedSize)
            writer.key("modifiedDate")
            writer.string(Self.iso8601Formatter.string(from: date))
            writer.key("type")
            writer.string(node.isDirectory ? "directory" : "file")
            if let ext = extractExtension(name) {
                writer.key("extension")
                writer.string(ext)
            }
        }

        var nodesVisited = 0
        func checkCancellationPeriodically() throws {
            nodesVisited += 1
            if nodesVisited.isMultiple(of: 4096) {
                try Task.checkCancellation()
            }
        }

        try checkCancellationPeriodically()
        writeHeader(0)
        guard let rootChildren = filteredChildren(of: 0, depth: 0) else {
            writer.endObject()
            return
        }
        writer.key("children")
        writer.beginArray()
        var stack: [PendingDirectory] = [PendingDirectory(childIndices: rootChildren, childDepth: 1)]

        while !stack.isEmpty {
            var frame = stack.removeLast()
            guard frame.position < frame.childIndices.count else {
                // This directory's children are exhausted: close its array, then its object.
                writer.endArray()
                writer.endObject()
                continue
            }

            let childIndex = frame.childIndices[frame.position]
            frame.position += 1
            let depth = frame.childDepth
            stack.append(frame)

            try checkCancellationPeriodically()
            writer.beginElement()
            writeHeader(childIndex)
            if let grandchildren = filteredChildren(of: childIndex, depth: depth) {
                writer.key("children")
                writer.beginArray()
                stack.append(PendingDirectory(childIndices: grandchildren, childDepth: depth + 1))
            } else {
                writer.endObject()
            }
        }
    }

    private func extractExtension(_ name: String) -> String? {
        guard let dotIdx = name.lastIndex(of: ".") else { return nil }
        let ext = String(name[name.index(after: dotIdx)...])
        return ext.isEmpty ? nil : ext
    }

    private func nameFromPool(node: FileNode, stringPool: Data) -> String {
        let start = Int(node.nameOffset)
        let end = start + Int(node.nameLength)
        guard end <= stringPool.count else { return "" }
        return String(data: stringPool[start..<end], encoding: .utf8) ?? ""
    }
}

/// Minimal streaming JSON writer used by `JSONExporter`: appends directly to a byte
/// buffer instead of building an intermediate `[String: Any]` object graph that a
/// general-purpose serializer would need to walk a second time. Supports exactly the
/// shape `JSONExporter` needs (objects, arrays, strings, unsigned integers, bools)
/// plus an indentation mode for `prettyPrint`.
struct JSONWriter {
    private var buffer: [UInt8] = []
    private let pretty: Bool
    private var depth = 0
    /// One entry per currently-open object/array: whether it has already written a
    /// member, which determines whether the next member needs a leading comma.
    private var hasMemberStack: [Bool] = []

    init(pretty: Bool) {
        self.pretty = pretty
        buffer.reserveCapacity(1 << 16)
    }

    var data: Data { Data(buffer) }

    mutating func beginObject() {
        buffer.append(UInt8(ascii: "{"))
        hasMemberStack.append(false)
        depth += 1
    }

    mutating func endObject() {
        depth -= 1
        if hasMemberStack.removeLast() { writeNewlineAndIndent() }
        buffer.append(UInt8(ascii: "}"))
    }

    mutating func beginArray() {
        buffer.append(UInt8(ascii: "["))
        hasMemberStack.append(false)
        depth += 1
    }

    mutating func endArray() {
        depth -= 1
        if hasMemberStack.removeLast() { writeNewlineAndIndent() }
        buffer.append(UInt8(ascii: "]"))
    }

    /// Call before writing an object member's value; handles comma/newline/indent and
    /// the key's own `"key":` text.
    mutating func key(_ name: String) {
        writeSeparatorIfNeeded()
        writeEscapedString(name)
        buffer.append(UInt8(ascii: ":"))
        if pretty { buffer.append(UInt8(ascii: " ")) }
    }

    /// Call before writing an array element's value; handles comma/newline/indent.
    mutating func beginElement() {
        writeSeparatorIfNeeded()
    }

    mutating func string(_ value: String) {
        writeEscapedString(value)
    }

    mutating func uint(_ value: UInt64) {
        buffer.append(contentsOf: String(value).utf8)
    }

    mutating func bool(_ value: Bool) {
        buffer.append(contentsOf: (value ? "true" : "false").utf8)
    }

    // MARK: - Private

    private mutating func writeSeparatorIfNeeded() {
        guard !hasMemberStack.isEmpty else { return }
        let last = hasMemberStack.count - 1
        if hasMemberStack[last] {
            buffer.append(UInt8(ascii: ","))
        }
        writeNewlineAndIndent()
        hasMemberStack[last] = true
    }

    private mutating func writeNewlineAndIndent() {
        guard pretty else { return }
        buffer.append(UInt8(ascii: "\n"))
        buffer.append(contentsOf: repeatElement(UInt8(ascii: " "), count: depth * 2))
    }

    /// Escapes quote, backslash, and control characters (`\u{XXXX}`, per RFC 8259);
    /// everything else is passed through as its natural UTF-8 encoding.
    private mutating func writeEscapedString(_ value: String) {
        buffer.append(UInt8(ascii: "\""))
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                buffer.append(contentsOf: "\\\"".utf8)
            case "\\":
                buffer.append(contentsOf: "\\\\".utf8)
            default:
                if scalar.value < 0x20 {
                    buffer.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
                } else {
                    buffer.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        buffer.append(UInt8(ascii: "\""))
    }
}
