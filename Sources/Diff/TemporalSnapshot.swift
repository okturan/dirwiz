import Foundation

// MARK: - Diff Kinds

/// Classification of how a directory changed between snapshot and current scan.
public enum TemporalDiffKind: UInt8, Sendable {
    case none               = 0  // no significant change
    case new                = 1  // directory is new (green)
    case grown              = 2  // directory grew significantly (blue)
    case shrunk             = 3  // directory shrank significantly (amber)
    case deletedDescendants = 4  // lost sub-directories (red tint on surviving ancestor)
}

// MARK: - Snapshot Types

/// Summary of deleted sub-directories aggregated to a surviving ancestor.
public struct DeletedSummary: Sendable {
    public let bytes: UInt64
    public let count: UInt32
}

/// Result of a diff computation — parallel arrays over the current tree's nodes.
public struct TemporalDiffResult: Sendable {
    public let kinds: [UInt8]        // TemporalDiffKind.rawValue per node
    public let strengths: [Float]    // 0…1 blend strength per node
    public let deletedByNode: [UInt32: DeletedSummary]  // surviving ancestor → deleted summary
}

/// Metadata stored alongside the snapshot data.
public struct TemporalSnapshotMeta: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let rootPath: String   // absolute path returned by tree.path(at: 0)
    public let totalBytes: UInt64
    public let dirCount: Int
}

/// Slim per-directory record stored in the snapshot file.
private struct SnapshotEntry: Codable {
    let path: String   // relative from root, lowercased, e.g. "Users/okan/Downloads"
    let size: UInt64
}

/// Serializable container (metadata + entries).
private struct SnapshotFile: Codable {
    let meta: TemporalSnapshotMeta
    let entries: [SnapshotEntry]
}

// MARK: - TemporalSnapshot

public struct TemporalSnapshot: Sendable {
    public let meta: TemporalSnapshotMeta
    /// Relative path (lowercase, no leading slash) → total bytes.
    let byPath: [String: UInt64]

    // MARK: Persistence

    /// URL where the snapshot for a given root path is persisted.
    public static func snapshotURL(for rootPath: String) -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = support.appendingPathComponent("DirWiz/Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Derive a safe filename from the root path.
        let safe = rootPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: .init(charactersIn: "_"))
        let name = safe.isEmpty ? "root" : safe
        return dir.appendingPathComponent("\(name).tdiff")
    }

    public func save() throws {
        let url = TemporalSnapshot.snapshotURL(for: meta.rootPath)
        let entries = byPath.map { SnapshotEntry(path: $0.key, size: $0.value) }
        let file = SnapshotFile(meta: meta, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }

    public static func load(for rootPath: String) throws -> TemporalSnapshot? {
        let url = snapshotURL(for: rootPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(SnapshotFile.self, from: data)
        var byPath: [String: UInt64] = [:]
        byPath.reserveCapacity(file.entries.count)
        for entry in file.entries {
            byPath[entry.path] = entry.size
        }
        return TemporalSnapshot(meta: file.meta, byPath: byPath)
    }
}
