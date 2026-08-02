import Foundation

/// A volume's timeline: many compressed checkpoints plus a small JSON index.
///
/// Replaces the single-slot `.tdiff` file that every camera click overwrote. The index
/// exists so the timeline can be listed - dates, names, change summaries - without
/// decompressing a single checkpoint.
///
/// The index is a CACHE, not the truth: it is rebuilt from the directory whenever it is
/// missing or unreadable. Losing it must degrade to "names and summaries are gone", never
/// to "your checkpoints are gone".
public struct SnapshotStore: Sendable {
    public let rootPath: String
    /// Scope-qualified identity used only for the on-disk directory name. Snapshot
    /// metadata retains the real root path so path resolution and diff validation do not
    /// receive a synthetic path.
    public let storageIdentity: String

    private static let appSupportOverrideEnv = "DIRWIZ_APP_SUPPORT_DIR"
    private static let indexFilename = "index.json"

    public init(rootPath: String, storageIdentity: String? = nil) {
        self.rootPath = rootPath
        self.storageIdentity = storageIdentity ?? rootPath
    }

    // MARK: - Layout

    static func baseDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment[appSupportOverrideEnv], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("DirWiz/Snapshots", isDirectory: true)
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("DirWiz/Snapshots", isDirectory: true)
    }

    public var directory: URL {
        SnapshotStore.baseDirectory()
            .appendingPathComponent("v2-" + SnapshotStore.volumeKey(storageIdentity), isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent(SnapshotStore.indexFilename) }

    static func volumeKey(_ rootPath: String) -> String {
        let safe = rootPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: .init(charactersIn: "_"))
        let prefix = safe.isEmpty ? "root" : String(safe.prefix(40))
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in rootPath.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return "\(prefix)-\(String(hash, radix: 16))"
    }

    // MARK: - Index

    private struct Index: Codable {
        var checkpoints: [SnapshotCheckpoint]
    }

    /// All checkpoints, newest first.
    public func list() -> [SnapshotCheckpoint] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder.snapshotDecoder.decode(Index.self, from: data) {
            // Drop entries whose file has vanished - an index promising a checkpoint that
            // cannot be opened is worse than a shorter list.
            let present = index.checkpoints.filter {
                fm.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
            }
            return present.sorted { $0.createdAt > $1.createdAt }
        }
        return rebuildIndexFromDirectory()
    }

    /// Self-healing: reconstruct what can be known from the files themselves.
    ///
    /// Names, pins and change summaries live only in the index and are genuinely lost, so
    /// recovered checkpoints are marked pinned - the store cannot tell which the user cared
    /// about, and silently thinning them away after an index loss would compound the damage.
    @discardableResult
    private func rebuildIndexFromDirectory() -> [SnapshotCheckpoint] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        var recovered: [SnapshotCheckpoint] = []
        for url in files where url.pathExtension == "dwcp" {
            guard let data = try? Data(contentsOf: url),
                  let payload = SnapshotContainer.decode(data),
                  let snapshot = try? TemporalSnapshot.decodePayload(payload) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            recovered.append(SnapshotCheckpoint(
                id: snapshot.meta.id,
                createdAt: snapshot.meta.createdAt,
                rootPath: snapshot.meta.rootPath,
                totalBytes: snapshot.meta.totalBytes,
                dirCount: snapshot.meta.dirCount,
                filename: url.lastPathComponent,
                storedBytes: UInt64(size),
                isPinned: true,
                name: "Recovered"
            ))
        }
        recovered.sort { $0.createdAt > $1.createdAt }
        try? writeIndex(recovered)
        return recovered
    }

    private func writeIndex(_ checkpoints: [SnapshotCheckpoint]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.snapshotEncoder.encode(Index(checkpoints: checkpoints))
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Creating checkpoints

    /// Writes a checkpoint and applies retention. Returns the created checkpoint.
    @discardableResult
    public func createCheckpoint(
        from snapshot: TemporalSnapshot,
        name: String? = nil,
        pinned: Bool = false,
        now: Date = Date(),
        budgetBytes: UInt64 = SnapshotRetention.defaultBudgetBytes
    ) throws -> SnapshotCheckpoint {
        let payload = try snapshot.encodedPayload()
        guard let container = SnapshotContainer.encode(payload: payload) else {
            throw SnapshotStoreError.encodeFailed
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Read the existing timeline BEFORE writing the new file. `list()` self-heals a
        // missing index by adopting every .dwcp on disk, so listing after the write would
        // adopt the half-committed checkpoint as a "Recovered" pin and then add it again.
        var existing = list()

        // Summarise against the immediate predecessor while it is still cheap to load.
        var summary: CheckpointChangeSummary?
        if let previous = existing.first, let prevSnapshot = try? load(previous) {
            summary = SnapshotStore.summarize(from: prevSnapshot, to: snapshot)
        }

        let filename = "\(Int(now.timeIntervalSince1970))-\(snapshot.meta.id.uuidString.prefix(8)).dwcp"
        let url = directory.appendingPathComponent(filename)
        try container.write(to: url, options: .atomic)

        let checkpoint = SnapshotCheckpoint(
            id: snapshot.meta.id,
            createdAt: snapshot.meta.createdAt,
            rootPath: snapshot.meta.rootPath,
            totalBytes: snapshot.meta.totalBytes,
            dirCount: snapshot.meta.dirCount,
            filename: filename,
            storedBytes: UInt64(container.count),
            isPinned: pinned || name != nil,
            name: name,
            summary: summary
        )
        existing.insert(checkpoint, at: 0)

        // Retention runs AFTER the new checkpoint is on disk and in the list, so the new
        // one participates in thinning rather than being exempt by accident.
        let evictions = SnapshotRetention.evictions(from: existing, now: now, budgetBytes: budgetBytes)
        let evictedIDs = Set(evictions.map(\.id))
        for victim in evictions {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(victim.filename))
        }
        let remaining = existing.filter { !evictedIDs.contains($0.id) }
        try writeIndex(remaining)
        return checkpoint
    }

    public func load(_ checkpoint: SnapshotCheckpoint) throws -> TemporalSnapshot {
        let url = directory.appendingPathComponent(checkpoint.filename)
        let data = try Data(contentsOf: url)
        guard let payload = SnapshotContainer.decode(data) else {
            throw SnapshotStoreError.decodeFailed
        }
        return try TemporalSnapshot.decodePayload(payload)
    }

    /// Newest checkpoint's snapshot, the default diff baseline.
    public func loadLatest() -> TemporalSnapshot? {
        guard let latest = list().first else { return nil }
        return try? load(latest)
    }

    public func totalStoredBytes() -> UInt64 {
        list().reduce(0) { $0 + $1.storedBytes }
    }

    public func setPinned(_ pinned: Bool, name: String?, for id: UUID) {
        var all = list()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].isPinned = pinned
        all[idx].name = name
        try? writeIndex(all)
    }

    public func delete(_ checkpoint: SnapshotCheckpoint) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(checkpoint.filename))
        try? writeIndex(list().filter { $0.id != checkpoint.id })
    }

    // MARK: - Legacy migration

    /// Imports the pre-store single-slot `.tdiff`, if present, as a pinned checkpoint.
    ///
    /// Pinned and named because it is the user's only existing baseline - the one thing
    /// that must not be thinned away by the retention policy on its first run. The original
    /// file is renamed rather than deleted, so a failed migration is recoverable.
    @discardableResult
    public func importLegacySnapshotIfPresent() -> SnapshotCheckpoint? {
        // A legacy snapshot carries only the real root path. It cannot prove whether a
        // `/` tree crossed mounts, so only the legacy-compatible selected-volume store
        // may adopt it; combined/unrestricted stores start clean.
        guard storageIdentity == rootPath else { return nil }
        let legacyURL = TemporalSnapshot.snapshotURL(for: rootPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path) else { return nil }
        guard let legacy = try? TemporalSnapshot.load(for: rootPath) else { return nil }
        guard list().isEmpty else { return nil }   // never re-import over a live store

        let created = try? createCheckpoint(
            from: legacy, name: "Legacy snapshot", pinned: true, now: legacy.meta.createdAt
        )
        if created != nil {
            try? fm.moveItem(at: legacyURL,
                             to: legacyURL.appendingPathExtension("imported"))
        }
        return created
    }

    // MARK: - Summaries

    /// Per-directory deltas between two snapshots, capped to the few entries a card shows.
    static func summarize(from old: TemporalSnapshot, to new: TemporalSnapshot,
                          topCount: Int = 5) -> CheckpointChangeSummary {
        let oldTotals = old.pathTotals
        let newTotals = new.pathTotals

        var deltas: [(String, Int64)] = []
        var deletedCount = 0
        var deletedBytes: UInt64 = 0
        var addedCount = 0

        for (path, oldSize) in oldTotals {
            if let newSize = newTotals[path] {
                let delta = Int64(bitPattern: newSize) - Int64(bitPattern: oldSize)
                if delta != 0 { deltas.append((path, delta)) }
            } else {
                deletedCount += 1
                deletedBytes += oldSize
                deltas.append((path, -Int64(bitPattern: oldSize)))
            }
        }
        for (path, newSize) in newTotals where oldTotals[path] == nil {
            addedCount += 1
            deltas.append((path, Int64(bitPattern: newSize)))
        }

        let grown = deltas.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(topCount)
        let shrunk = deltas.filter { $0.1 < 0 }.sorted { $0.1 < $1.1 }.prefix(topCount)

        return CheckpointChangeSummary(
            totalDelta: Int64(bitPattern: new.meta.totalBytes) - Int64(bitPattern: old.meta.totalBytes),
            topGrown: grown.map { CheckpointChangeSummary.Entry(path: $0.0, deltaBytes: $0.1) },
            topShrunk: shrunk.map { CheckpointChangeSummary.Entry(path: $0.0, deltaBytes: $0.1) },
            deletedCount: deletedCount,
            deletedBytes: deletedBytes,
            addedCount: addedCount
        )
    }
}

/// Whether a scan completion is worth recording. Pure, so the throttle is testable.
public enum AutoCheckpointPolicy {
    public static let minimumIntervalSeconds: TimeInterval = 6 * 3_600
    /// Growth that justifies a checkpoint even inside the interval - a big change is worth
    /// recording precisely because it is the one you will want to look back at.
    public static let significantGrowthFraction = 0.01

    public static func shouldCheckpoint(
        latest: SnapshotCheckpoint?,
        now: Date,
        currentTotalBytes: UInt64,
        minimumInterval: TimeInterval = minimumIntervalSeconds
    ) -> Bool {
        guard let latest else { return true }   // nothing recorded yet
        if now.timeIntervalSince(latest.createdAt) >= minimumInterval { return true }

        guard latest.totalBytes > 0 else { return true }
        let delta = abs(Int64(bitPattern: currentTotalBytes) - Int64(bitPattern: latest.totalBytes))
        return Double(delta) / Double(latest.totalBytes) > significantGrowthFraction
    }
}

public enum SnapshotStoreError: Error {
    case encodeFailed
    case decodeFailed
}

extension JSONEncoder {
    static var snapshotEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]   // stable on disk, so diffs are meaningful
        return e
    }
}

extension JSONDecoder {
    static var snapshotDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
