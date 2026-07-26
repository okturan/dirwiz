import Foundation
import Compression

/// One recorded point on a volume's timeline.
public struct SnapshotCheckpoint: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public let rootPath: String
    public let totalBytes: UInt64
    public let dirCount: Int
    /// Filename inside the volume's checkpoint directory.
    public let filename: String
    /// Bytes on disk after compression, for the store budget.
    public let storedBytes: UInt64
    /// User-named and permanently exempt from retention thinning.
    public var isPinned: Bool
    public var name: String?
    /// What changed since the previous checkpoint. Computed once at creation; kept in the
    /// index so the timeline can be listed without decompressing anything.
    public var summary: CheckpointChangeSummary?

    public init(
        id: UUID = UUID(), createdAt: Date, rootPath: String, totalBytes: UInt64,
        dirCount: Int, filename: String, storedBytes: UInt64,
        isPinned: Bool = false, name: String? = nil, summary: CheckpointChangeSummary? = nil
    ) {
        self.id = id; self.createdAt = createdAt; self.rootPath = rootPath
        self.totalBytes = totalBytes; self.dirCount = dirCount; self.filename = filename
        self.storedBytes = storedBytes; self.isPinned = isPinned; self.name = name
        self.summary = summary
    }
}

/// KB-sized diff summary against the preceding checkpoint.
public struct CheckpointChangeSummary: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let path: String
        public let deltaBytes: Int64
        public init(path: String, deltaBytes: Int64) {
            self.path = path; self.deltaBytes = deltaBytes
        }
    }
    public let totalDelta: Int64
    public let topGrown: [Entry]
    public let topShrunk: [Entry]
    public let deletedCount: Int
    public let deletedBytes: UInt64
    public let addedCount: Int

    public init(totalDelta: Int64, topGrown: [Entry], topShrunk: [Entry],
                deletedCount: Int, deletedBytes: UInt64, addedCount: Int) {
        self.totalDelta = totalDelta; self.topGrown = topGrown; self.topShrunk = topShrunk
        self.deletedCount = deletedCount; self.deletedBytes = deletedBytes
        self.addedCount = addedCount
    }
}

/// LZFSE container around the existing `.tdiff` payload.
///
/// LZFSE comes from Apple's own Compression framework, so the zero-external-dependency
/// rule holds. The header is checked on every read and ANY doubt returns nil - same
/// fail-closed discipline as `TreeCache`: a snapshot that decodes to garbage would produce
/// a confidently wrong diff, which is worse than no diff.
enum SnapshotContainer {
    static let magic: [UInt8] = Array("DWCP".utf8)
    static let version: UInt16 = 1

    /// `version` is the low byte of the version field; the high byte flags storage mode.
    /// LZFSE can EXPAND small or already-dense inputs (and `compression_encode_buffer`
    /// simply returns 0 when the result would not fit), so a stored-uncompressed mode is
    /// required, not an optimisation - without it a small snapshot could never be written.
    static let modeCompressed: UInt8 = 0
    static let modeStored: UInt8 = 1

    static func encode(payload: Data) -> Data? {
        guard !payload.isEmpty else { return nil }

        let mode: UInt8
        let body: Data
        if let compressed = compress(payload), compressed.count < payload.count {
            mode = modeCompressed
            body = compressed
        } else {
            mode = modeStored
            body = payload
        }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(UInt8(version & 0xFF))
        out.append(mode)
        withUnsafeBytes(of: UInt64(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    static func decode(_ data: Data) -> Data? {
        let headerSize = magic.count + 2 + 8
        guard data.count > headerSize, Array(data.prefix(magic.count)) == magic else { return nil }

        let ver = data[data.startIndex + magic.count]
        let mode = data[data.startIndex + magic.count + 1]
        guard ver == UInt8(version & 0xFF) else { return nil }   // unknown version: refuse
        guard mode == modeCompressed || mode == modeStored else { return nil }

        var cursor = magic.count + 2
        let expanded: UInt64 = data.readLE64(at: &cursor)
        // A corrupt length field must not be turned into a huge allocation.
        guard expanded > 0, expanded < 2_000_000_000 else { return nil }

        let body = Data(data.suffix(from: data.startIndex + headerSize))
        if mode == modeStored {
            guard body.count == Int(expanded) else { return nil }
            return body
        }
        guard let out = decompress(body, expectedSize: Int(expanded)),
              out.count == Int(expanded) else { return nil }
        return out
    }

    private static func compress(_ input: Data) -> Data? {
        // Headroom so LZFSE is not reporting "did not fit" for near-incompressible input.
        let capacity = input.count + 1_024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(d, capacity, s, input.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    private static func decompress(_ input: Data, expectedSize: Int) -> Data? {
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(d, expectedSize, s, input.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }
}

private extension Data {
    func readLE16(at cursor: inout Int) -> UInt16 {
        defer { cursor += 2 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt16.self) }.littleEndian
    }
    func readLE64(at cursor: inout Int) -> UInt64 {
        defer { cursor += 8 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) }.littleEndian
    }
}

/// Time-Machine-style thinning, as a pure function so the policy is testable without
/// fabricating files or waiting days.
public enum SnapshotRetention {
    public static let dailyDays = 30
    public static let weeklyWeeks = 12
    public static let monthlyMonths = 12
    public static let defaultBudgetBytes: UInt64 = 500 * 1_024 * 1_024

    /// Returns the checkpoints to DELETE. Pinned checkpoints are never returned: a name is
    /// the user saying "keep this", and retention must not overrule that - not even to stay
    /// under budget, where the honest answer is to tell them rather than delete their pin.
    public static func evictions(
        from checkpoints: [SnapshotCheckpoint],
        now: Date,
        budgetBytes: UInt64 = defaultBudgetBytes
    ) -> [SnapshotCheckpoint] {
        let unpinned = checkpoints.filter { !$0.isPinned }.sorted { $0.createdAt > $1.createdAt }
        guard !unpinned.isEmpty else { return [] }

        var keep = Set<UUID>()
        var seenBucket = Set<String>()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        for checkpoint in unpinned {
            let age = now.timeIntervalSince(checkpoint.createdAt)
            let days = age / 86_400
            // One per bucket, newest first: dailies for a month, then weeklies, then
            // monthlies. Anything older than the last tier falls out entirely.
            let bucket: String?
            if days <= Double(dailyDays) {
                bucket = "d" + isoDay(checkpoint.createdAt, calendar)
            } else if days <= Double(weeklyWeeks * 7) {
                bucket = "w" + isoWeek(checkpoint.createdAt, calendar)
            } else if days <= Double(monthlyMonths * 31) {
                bucket = "m" + isoMonth(checkpoint.createdAt, calendar)
            } else {
                bucket = nil
            }
            if let bucket, seenBucket.insert(bucket).inserted {
                keep.insert(checkpoint.id)
            }
        }

        var evicted = unpinned.filter { !keep.contains($0.id) }

        // Budget sweep, oldest-unpinned-first, over what survived thinning.
        var survivors = unpinned.filter { keep.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        var total = checkpoints.reduce(UInt64(0)) { $0 + $1.storedBytes }
            - evicted.reduce(UInt64(0)) { $0 + $1.storedBytes }
        while total > budgetBytes, !survivors.isEmpty {
            let victim = survivors.removeFirst()
            total -= min(total, victim.storedBytes)
            evicted.append(victim)
        }
        return evicted
    }

    private static func isoDay(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    private static func isoWeek(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
    }
    private static func isoMonth(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }
}
