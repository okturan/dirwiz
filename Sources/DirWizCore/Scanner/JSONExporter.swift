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
    public func export(
        tree: FileTree,
        options: JSONExportOptions = JSONExportOptions()
    ) async throws -> Data {
        let (nodes, stringPool, _) = tree.pathBuildingSnapshot()
        guard !nodes.isEmpty else {
            return try JSONSerialization.data(withJSONObject: [String: Any](), options: [])
        }

        let root = try await buildNode(
            index: 0,
            depth: 0,
            nodes: nodes,
            stringPool: stringPool,
            options: options
        )
        let jsonOptions: JSONSerialization.WritingOptions = options.prettyPrint
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        return try JSONSerialization.data(withJSONObject: root, options: jsonOptions)
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

    private func buildNode(
        index: Int,
        depth: Int,
        nodes: [FileNode],
        stringPool: Data,
        options: JSONExportOptions
    ) async throws -> [String: Any] {
        try Task.checkCancellation()

        let node = nodes[index]
        let displaySize = node.allocatedSize > 0 ? node.allocatedSize : node.fileSize

        // Skip nodes below size threshold
        if options.minSize > 0, displaySize < options.minSize {
            return [:]
        }

        let name = nameFromPool(node: node, stringPool: stringPool)
        let date = Date(timeIntervalSince1970: TimeInterval(node.modifiedDate))

        var dict: [String: Any] = [
            "name": name,
            "size": node.fileSize,
            "allocatedSize": node.allocatedSize,
            "modifiedDate": Self.iso8601Formatter.string(from: date),
            "type": node.isDirectory ? "directory" : "file",
        ]

        // Extract extension from name
        if let dotIdx = name.lastIndex(of: ".") {
            let ext = String(name[name.index(after: dotIdx)...])
            if !ext.isEmpty {
                dict["extension"] = ext
            }
        }

        // Recurse into children for directories
        if node.isDirectory, node.firstChildIndex != FileNode.invalid {
            let atDepthLimit = options.maxDepth.map { depth >= $0 } ?? false
            if !atDepthLimit {
                var children: [[String: Any]] = []
                let start = Int(node.firstChildIndex)
                let end = min(start + Int(node.childCount), nodes.count)
                for ci in start..<end {
                    let child = nodes[ci]
                    let childDisplay = child.allocatedSize > 0 ? child.allocatedSize : child.fileSize

                    if !options.includeFiles, !child.isDirectory { continue }
                    if options.minSize > 0, childDisplay < options.minSize { continue }

                    let childDict = try await buildNode(
                        index: ci,
                        depth: depth + 1,
                        nodes: nodes,
                        stringPool: stringPool,
                        options: options
                    )
                    if !childDict.isEmpty {
                        children.append(childDict)
                    }
                }
                dict["children"] = children
            }
        }

        return dict
    }

    private func nameFromPool(node: FileNode, stringPool: Data) -> String {
        let start = Int(node.nameOffset)
        let end = start + Int(node.nameLength)
        guard end <= stringPool.count else { return "" }
        return String(data: stringPool[start..<end], encoding: .utf8) ?? ""
    }
}
