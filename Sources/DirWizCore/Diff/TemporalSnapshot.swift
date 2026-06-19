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
    /// Whether the snapshot was taken on a case-sensitive volume.
    /// Defaults to false for backward compatibility with existing snapshots.
    public let isCaseSensitive: Bool

    public init(id: UUID, createdAt: Date, rootPath: String, totalBytes: UInt64, dirCount: Int, isCaseSensitive: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.rootPath = rootPath
        self.totalBytes = totalBytes
        self.dirCount = dirCount
        self.isCaseSensitive = isCaseSensitive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        totalBytes = try container.decode(UInt64.self, forKey: .totalBytes)
        dirCount = try container.decode(Int.self, forKey: .dirCount)
        isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive) ?? false
    }
}

/// Slim per-directory record stored in the snapshot file.
// Legacy JSON support.
private struct SnapshotEntry: Codable {
    let path: String   // relative from root, lowercased, e.g. "Users/okan/Downloads"
    let size: UInt64
}

/// Serializable container (metadata + entries).
// Legacy JSON support.
private struct SnapshotFile: Codable {
    let meta: TemporalSnapshotMeta
    let entries: [SnapshotEntry]
}

private enum TemporalSnapshotBinary {
    static let magic = Data([0x54, 0x44, 0x53, 0x4E]) // "TDSN"
    /// v1: original format; v2: adds isCaseSensitive byte after rootPath
    static let version: UInt32 = 2
}

private enum TemporalSnapshotFormatError: Error {
    case unsupportedFormat
    case invalidBinaryHeader
    case unsupportedBinaryVersion(UInt32)
    case truncatedBinary
    case invalidUTF8
}

// MARK: - TemporalSnapshot

public struct TemporalSnapshot: Sendable {
    public let meta: TemporalSnapshotMeta
    /// Relative path (lowercase, no leading slash) → total bytes.
    let byPath: [String: UInt64]

    // MARK: Persistence

    private static let appSupportOverrideEnv = "DIRWIZ_APP_SUPPORT_DIR"

    /// URL where the snapshot for a given root path is persisted.
    /// Uses a hash suffix to avoid collisions between paths that differ only in
    /// whitespace or separators (e.g., "/Volumes/A B" vs "/Volumes/A_B").
    public static func snapshotURL(for rootPath: String) -> URL {
        snapshotDirectoryURL().appendingPathComponent(snapshotFilename(for: rootPath))
    }

    private static func snapshotDirectoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment[appSupportOverrideEnv], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("DirWiz/Snapshots", isDirectory: true)
        }

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("DirWiz/Snapshots", isDirectory: true)
    }

    private static func snapshotFilename(for rootPath: String) -> String {
        // Readable prefix + FNV-1a hash suffix to guarantee uniqueness.
        let safe = rootPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: .init(charactersIn: "_"))
        let prefix = safe.isEmpty ? "root" : String(safe.prefix(40))
        return "\(prefix)-\(String(fnv1a64(rootPath), radix: 16)).tdiff"
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    public func save() throws {
        let url = TemporalSnapshot.snapshotURL(for: meta.rootPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Sort by path for deterministic output (Dictionary iteration order is unstable).
        let entries = byPath
            .map { SnapshotEntry(path: $0.key, size: $0.value) }
            .sorted { $0.path < $1.path }
        let data = try binaryData(entries: entries)
        try data.write(to: url, options: .atomic)
    }

    public static func load(for rootPath: String) throws -> TemporalSnapshot? {
        let url = snapshotURL(for: rootPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if data.starts(with: TemporalSnapshotBinary.magic) {
            return try loadBinary(data: data)
        }
        if data.first == UInt8(ascii: "{") {
            return try loadLegacyJSON(data: data)
        }
        throw TemporalSnapshotFormatError.unsupportedFormat
    }

    private func binaryData(entries: [SnapshotEntry]) throws -> Data {
        let rootPathLength = meta.rootPath.utf8.count
        guard rootPathLength <= Int(UInt16.max) else {
            throw TemporalSnapshotFormatError.invalidBinaryHeader
        }
        guard meta.dirCount >= 0 && meta.dirCount <= Int(UInt32.max) else {
            throw TemporalSnapshotFormatError.invalidBinaryHeader
        }

        var data = Data()
        data.reserveCapacity(64 + rootPathLength + (entries.count * 16))

        data.append(TemporalSnapshotBinary.magic)
        data.appendLE(TemporalSnapshotBinary.version)

        var uuid = meta.id.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }

        data.appendLE(meta.createdAt.timeIntervalSince1970)
        data.appendLE(meta.totalBytes)
        data.appendLE(UInt32(meta.dirCount))
        data.appendLE(UInt16(rootPathLength))
        data.append(contentsOf: meta.rootPath.utf8)
        // v2: case-sensitivity flag
        data.append(meta.isCaseSensitive ? 1 : 0)

        for entry in entries {
            let pathLength = entry.path.utf8.count
            guard pathLength <= Int(UInt16.max) else {
                throw TemporalSnapshotFormatError.invalidBinaryHeader
            }
            data.appendLE(UInt16(pathLength))
            data.append(contentsOf: entry.path.utf8)
            data.appendLE(entry.size)
        }
        return data
    }

    private static func loadBinary(data: Data) throws -> TemporalSnapshot {
        var cursor = 0

        guard let magic = data.readBytes(count: 4, at: &cursor), Data(magic) == TemporalSnapshotBinary.magic else {
            throw TemporalSnapshotFormatError.invalidBinaryHeader
        }

        let version: UInt32 = try data.readLE(at: &cursor)
        guard version == 1 || version == 2 else {
            throw TemporalSnapshotFormatError.unsupportedBinaryVersion(version)
        }

        guard let uuidBytes = data.readBytes(count: 16, at: &cursor) else {
            throw TemporalSnapshotFormatError.truncatedBinary
        }
        let uuid = uuidBytes.withUnsafeBytes { raw -> UUID in
            let tuple = raw.bindMemory(to: UInt8.self)
            return UUID(uuid: (
                tuple[0], tuple[1], tuple[2], tuple[3],
                tuple[4], tuple[5], tuple[6], tuple[7],
                tuple[8], tuple[9], tuple[10], tuple[11],
                tuple[12], tuple[13], tuple[14], tuple[15]
            ))
        }

        let createdAtRaw: Double = try data.readLE(at: &cursor)
        let totalBytes: UInt64 = try data.readLE(at: &cursor)
        let dirCountRaw: UInt32 = try data.readLE(at: &cursor)
        let rootPathLength: UInt16 = try data.readLE(at: &cursor)

        guard let rootPathRaw = data.readBytes(count: Int(rootPathLength), at: &cursor),
              let rootPath = String(bytes: rootPathRaw, encoding: .utf8) else {
            throw TemporalSnapshotFormatError.invalidUTF8
        }

        // v2 adds a case-sensitivity byte; v1 defaults to false.
        var isCaseSensitive = false
        if version >= 2 {
            guard let flagBytes = data.readBytes(count: 1, at: &cursor) else {
                throw TemporalSnapshotFormatError.truncatedBinary
            }
            isCaseSensitive = flagBytes[flagBytes.startIndex] != 0
        }

        var byPath: [String: UInt64] = [:]
        byPath.reserveCapacity(Int(dirCountRaw))

        while cursor < data.count {
            let pathLength: UInt16 = try data.readLE(at: &cursor)
            guard let pathRaw = data.readBytes(count: Int(pathLength), at: &cursor),
                  let path = String(bytes: pathRaw, encoding: .utf8) else {
                throw TemporalSnapshotFormatError.invalidUTF8
            }
            let size: UInt64 = try data.readLE(at: &cursor)
            byPath[path] = size
        }

        // Validate that the number of entries read matches the header's declared count.
        // A mismatch indicates a truncated or corrupted snapshot file.
        if byPath.count != Int(dirCountRaw) {
            throw TemporalSnapshotFormatError.truncatedBinary
        }

        let meta = TemporalSnapshotMeta(
            id: uuid,
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            rootPath: rootPath,
            totalBytes: totalBytes,
            dirCount: Int(dirCountRaw),
            isCaseSensitive: isCaseSensitive
        )
        return TemporalSnapshot(meta: meta, byPath: byPath)
    }

    private static func loadLegacyJSON(data: Data) throws -> TemporalSnapshot {
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

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Double) {
        appendLE(value.bitPattern)
    }

    func readBytes(count: Int, at cursor: inout Int) -> Data? {
        guard count >= 0, cursor >= 0, cursor + count <= self.count else { return nil }
        defer { cursor += count }
        return self[cursor..<(cursor + count)]
    }

    func readLE<T: FixedWidthInteger>(at cursor: inout Int) throws -> T {
        let width = MemoryLayout<T>.size
        guard let bytes = readBytes(count: width, at: &cursor) else {
            throw TemporalSnapshotFormatError.truncatedBinary
        }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) }.littleEndian
    }

    func readLE(at cursor: inout Int) throws -> Double {
        let raw: UInt64 = try readLE(at: &cursor)
        return Double(bitPattern: raw)
    }
}
