import Foundation

/// A capped, per-volume history of recent warm-start decisions (warm-start-observability):
/// makes a *pattern* across launches visible ("cold-scanned 4 of the last 5 times, always
/// citing the same reason") instead of only the single most recent `lastScanSummary` line,
/// which the next scan immediately overwrites.
///
/// Deliberately NOT held to `TreeCache`'s fail-closed binary discipline: losing this
/// history costs nothing functionally (unlike losing a multi-hundred-MB tree cache, which
/// forces a full cold rescan), so a missing or malformed file just reads as "no history
/// yet" rather than a rejection with a reason to explain. Plain JSON — human-inspectable
/// with `cat`, which is itself a nice diagnostic property for exactly the kind of
/// after-the-fact investigation this feature exists to shorten.
public enum WarmStartHistory {
    public struct Entry: Codable, Sendable, Equatable {
        public let date: Date
        public let wasWarm: Bool
        public let reason: String?
        public let itemCount: Int
        public let elapsedSeconds: Double

        public init(date: Date, wasWarm: Bool, reason: String?, itemCount: Int, elapsedSeconds: Double) {
            self.date = date
            self.wasWarm = wasWarm
            self.reason = reason
            self.itemCount = itemCount
            self.elapsedSeconds = elapsedSeconds
        }
    }

    /// Oldest entries are evicted first once a volume's history exceeds this many.
    public static let maxEntries = 20

    private static let appSupportOverrideEnv = "DIRWIZ_APP_SUPPORT_DIR"

    /// Append `entry` to `rootPath`'s history, capping at `maxEntries` (oldest evicted
    /// first). Best-effort: a write failure is silently swallowed — this is diagnostic
    /// data, not something a user's scan should ever fail over.
    public static func record(_ entry: Entry, for rootPath: String) {
        var entries = load(for: rootPath)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        guard let data = try? JSONEncoder.warmStartHistory.encode(entries) else { return }
        let url = historyURL(for: rootPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// The persisted history for `rootPath`, oldest first. Empty on any doubt — a missing
    /// file, a malformed one, or a decode failure all read the same as "no history yet"
    /// rather than surfacing an error (see the type's doc comment: this is low-stakes,
    /// diagnostic-only data, not `TreeCache`'s fail-closed territory).
    public static func load(for rootPath: String) -> [Entry] {
        let url = historyURL(for: rootPath)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.warmStartHistory.decode([Entry].self, from: data)) ?? []
    }

    /// Test-only escape hatch, mirroring `TreeCache.invalidate` — removes a volume's
    /// history file entirely.
    public static func clear(for rootPath: String) {
        try? FileManager.default.removeItem(at: historyURL(for: rootPath))
    }

    // MARK: - Location

    private static func historyDirectoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment[appSupportOverrideEnv], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("DirWiz/WarmStartHistory", isDirectory: true)
        }

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("DirWiz/WarmStartHistory", isDirectory: true)
    }

    private static func historyURL(for rootPath: String) -> URL {
        historyDirectoryURL().appendingPathComponent(historyFilename(for: rootPath))
    }

    private static func historyFilename(for rootPath: String) -> String {
        // Readable prefix + FNV-1a hash suffix to guarantee uniqueness — mirrors
        // TreeCache/TemporalSnapshot's naming scheme.
        let safe = rootPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: .init(charactersIn: "_"))
        let prefix = safe.isEmpty ? "root" : String(safe.prefix(40))
        return "\(prefix)-\(String(fnv1a64(rootPath), radix: 16)).json"
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

private extension JSONEncoder {
    static let warmStartHistory: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let warmStartHistory: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
