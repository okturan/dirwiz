import Foundation

/// Persists a scanned `FileTree` so the next launch can warm-start instead of
/// re-enumerating the volume. FAIL-CLOSED: `load` returns `nil` on ANY doubt —
/// a nil cache simply means a cold scan, i.e. today's behavior.
///
/// Binary format (little-endian), current version 1:
///
/// | Field | Type |
/// |---|---|
/// | magic | 4 bytes "DWTC" |
/// | formatVersion | UInt32 = 1 |
/// | nodeStride | UInt32 = MemoryLayout<FileNode>.stride (layout guard) |
/// | savedAt | Float64 (timeIntervalSince1970) |
/// | lastEventId | UInt64 |
/// | rootPathLen UInt16 + UTF-8 bytes | |
/// | isCaseSensitive | UInt8 |
/// | volumeUUIDLen UInt16 + UTF-8 bytes | empty if unavailable at save time |
/// | nodeCount | UInt32 |
/// | stringPoolLen | UInt64 |
/// | nodes raw bytes | nodeCount × nodeStride |
/// | stringPool bytes | |
/// | checksum | UInt64 FNV-1a 64 over everything before it |
///
/// Any change to `FileNode`'s stored layout MUST bump `formatVersion` — the stride
/// guard catches size changes but not same-size field reorders.
public enum TreeCache {
    public struct Payload: Sendable {
        public let tree: FileTree
        public let lastEventId: UInt64
        public let savedAt: Date
    }

    private static let appSupportOverrideEnv = "DIRWIZ_APP_SUPPORT_DIR"

    private enum Binary {
        static let magic = Data([0x44, 0x57, 0x54, 0x43]) // "DWTC"
        static let formatVersion: UInt32 = 1
    }

    /// Reasons a load can fail. Structural failures (the file itself is garbage) are
    /// invalidated by `load`; "doesn't apply" failures (wrong root, wrong volume) leave
    /// the file alone since it may still be valid for its actual owner.
    fileprivate enum DecodeError: Error {
        case invalidHeader
        case truncated
        case checksumMismatch
        case structuralInvalid
        case rootPathMismatch
        case volumeMismatch

        var isStructuralCorruption: Bool {
            switch self {
            case .invalidHeader, .truncated, .checksumMismatch, .structuralInvalid:
                return true
            case .rootPathMismatch, .volumeMismatch:
                return false
            }
        }
    }

    // MARK: - Save

    public static func save(tree: FileTree, lastEventId: UInt64) throws {
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()
        let isCaseSensitive = tree.isCaseSensitive

        let rootPathBytes = Array(rootPath.utf8)
        guard rootPathBytes.count <= Int(UInt16.max) else {
            throw DecodeError.invalidHeader
        }
        let volumeUUIDBytes = Array(volumeUUIDString(for: rootPath).utf8)
        guard volumeUUIDBytes.count <= Int(UInt16.max) else {
            throw DecodeError.invalidHeader
        }
        guard nodes.count <= Int(UInt32.max) else {
            throw DecodeError.invalidHeader
        }

        var data = Data()
        data.reserveCapacity(
            64 + rootPathBytes.count + volumeUUIDBytes.count
                + nodes.count * MemoryLayout<FileNode>.stride + stringPool.count
        )

        data.append(Binary.magic)
        data.appendLE(Binary.formatVersion)
        data.appendLE(UInt32(MemoryLayout<FileNode>.stride))
        data.appendLE(Date().timeIntervalSince1970)
        data.appendLE(lastEventId)
        data.appendLE(UInt16(rootPathBytes.count))
        data.append(contentsOf: rootPathBytes)
        data.append(isCaseSensitive ? 1 : 0)
        data.appendLE(UInt16(volumeUUIDBytes.count))
        data.append(contentsOf: volumeUUIDBytes)
        data.appendLE(UInt32(nodes.count))
        data.appendLE(UInt64(stringPool.count))
        nodes.withUnsafeBytes { data.append(contentsOf: $0) }
        data.append(stringPool)

        data.appendLE(fnv1a64(data))

        let url = cacheURL(for: rootPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Load

    public static func load(for rootPath: String) -> Payload? {
        let url = cacheURL(for: rootPath)
        guard let data = try? Data(contentsOf: url) else { return nil }

        do {
            return try decode(data: data, requestedRootPath: rootPath)
        } catch let error as DecodeError {
            if error.isStructuralCorruption {
                invalidate(for: rootPath)
            }
            return nil
        } catch {
            return nil
        }
    }

    public static func invalidate(for rootPath: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: rootPath))
    }

    public static func cacheURL(for rootPath: String) -> URL {
        cacheDirectoryURL().appendingPathComponent(cacheFilename(for: rootPath))
    }

    // MARK: - Decode

    private static func decode(data: Data, requestedRootPath: String) throws -> Payload {
        var cursor = 0

        guard let magic = data.readBytes(count: 4, at: &cursor), Data(magic) == Binary.magic else {
            throw DecodeError.invalidHeader
        }

        let version: UInt32 = try data.readLE(at: &cursor)
        guard version == Binary.formatVersion else {
            throw DecodeError.invalidHeader
        }

        let nodeStride: UInt32 = try data.readLE(at: &cursor)
        let stride = MemoryLayout<FileNode>.stride
        guard nodeStride == UInt32(stride) else {
            throw DecodeError.invalidHeader
        }

        let savedAtRaw: Double = try data.readLE(at: &cursor)
        let lastEventId: UInt64 = try data.readLE(at: &cursor)

        let rootPathLen: UInt16 = try data.readLE(at: &cursor)
        guard let rootPathRaw = data.readBytes(count: Int(rootPathLen), at: &cursor),
              let rootPath = String(bytes: rootPathRaw, encoding: .utf8) else {
            throw DecodeError.truncated
        }
        guard rootPath == requestedRootPath else {
            throw DecodeError.rootPathMismatch
        }

        guard let caseByte = data.readBytes(count: 1, at: &cursor) else {
            throw DecodeError.truncated
        }
        let isCaseSensitive = caseByte[caseByte.startIndex] != 0

        let volumeUUIDLen: UInt16 = try data.readLE(at: &cursor)
        guard let volumeUUIDRaw = data.readBytes(count: Int(volumeUUIDLen), at: &cursor),
              let storedVolumeUUID = String(bytes: volumeUUIDRaw, encoding: .utf8) else {
            throw DecodeError.truncated
        }
        guard storedVolumeUUID == volumeUUIDString(for: rootPath) else {
            throw DecodeError.volumeMismatch
        }

        let nodeCount: UInt32 = try data.readLE(at: &cursor)
        let stringPoolLen: UInt64 = try data.readLE(at: &cursor)

        // Bounds-check declared sizes against what's actually left in the file BEFORE
        // allocating anything — a hostile/corrupt header declaring millions of nodes
        // must not force a huge pre-allocation (plan-016 clamp discipline).
        let checksumSize = 8
        let remaining = data.count - cursor - checksumSize
        guard remaining >= 0 else { throw DecodeError.truncated }
        guard stringPoolLen <= UInt64(Int.max) else { throw DecodeError.truncated }
        let nodesByteCount = Int(nodeCount) * stride
        guard nodesByteCount <= remaining else { throw DecodeError.truncated }
        guard Int(stringPoolLen) <= remaining - nodesByteCount else { throw DecodeError.truncated }

        guard let nodeBytes = data.readBytes(count: nodesByteCount, at: &cursor) else {
            throw DecodeError.truncated
        }
        guard let poolBytes = data.readBytes(count: Int(stringPoolLen), at: &cursor) else {
            throw DecodeError.truncated
        }

        let checksummedRegion = data.subdata(in: 0..<cursor)
        let storedChecksum: UInt64 = try data.readLE(at: &cursor)
        guard fnv1a64(checksummedRegion) == storedChecksum else {
            throw DecodeError.checksumMismatch
        }
        guard cursor == data.count else {
            throw DecodeError.truncated
        }

        // Reconstruct nodes via unaligned loads — the slice's start offset within the
        // file isn't guaranteed to satisfy FileNode's alignment, so `bindMemory` would
        // be unsafe. No long-lived pointer aliasing: everything is copied into `nodes`.
        var nodes = [FileNode]()
        nodes.reserveCapacity(Int(nodeCount))
        nodeBytes.withUnsafeBytes { raw in
            for i in 0..<Int(nodeCount) {
                nodes.append(raw.loadUnaligned(fromByteOffset: i * stride, as: FileNode.self))
            }
        }
        let stringPool = Data(poolBytes)

        try validateStructure(nodes: nodes, stringPoolCount: stringPool.count)

        let tree = FileTree()
        tree.installLoadedContents(
            nodes: nodes,
            stringPool: stringPool,
            rootPath: rootPath,
            isCaseSensitive: isCaseSensitive
        )
        return Payload(tree: tree, lastEventId: lastEventId, savedAt: Date(timeIntervalSince1970: savedAtRaw))
    }

    /// A corrupt cache can otherwise become an out-of-bounds read later in treemap/search
    /// hot paths — this O(n) pass is the last line of defense before that ever happens.
    private static func validateStructure(nodes: [FileNode], stringPoolCount: Int) throws {
        let count = nodes.count
        for node in nodes {
            if node.parentIndex != FileNode.invalid, Int(node.parentIndex) >= count {
                throw DecodeError.structuralInvalid
            }
            if node.firstChildIndex != FileNode.invalid {
                let end = Int(node.firstChildIndex) + Int(node.childCount)
                guard end <= count else { throw DecodeError.structuralInvalid }
            }
            let nameEnd = Int(node.nameOffset) + Int(node.nameLength)
            guard nameEnd <= stringPoolCount else { throw DecodeError.structuralInvalid }
        }
    }

    // MARK: - Location

    private static func cacheDirectoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment[appSupportOverrideEnv], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("DirWiz/TreeCache", isDirectory: true)
        }

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("DirWiz/TreeCache", isDirectory: true)
    }

    private static func cacheFilename(for rootPath: String) -> String {
        // Readable prefix + FNV-1a hash suffix to guarantee uniqueness (mirrors
        // TemporalSnapshot's naming scheme).
        let safe = rootPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: .init(charactersIn: "_"))
        let prefix = safe.isEmpty ? "root" : String(safe.prefix(40))
        return "\(prefix)-\(String(fnv1a64(rootPath), radix: 16)).dwtc"
    }

    private static func volumeUUIDString(for path: String) -> String {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]),
              let uuid = values.volumeUUIDString else {
            return ""
        }
        return uuid
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
        }
        return hash
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
            throw TreeCache.DecodeError.truncated
        }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) }.littleEndian
    }

    func readLE(at cursor: inout Int) throws -> Double {
        let raw: UInt64 = try readLE(at: &cursor)
        return Double(bitPattern: raw)
    }
}
