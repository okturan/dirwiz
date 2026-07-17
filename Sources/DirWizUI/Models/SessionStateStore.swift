import Foundation

/// Per-volume, path-keyed exploration session: which folders were expanded, what was
/// selected, where the treemap was rooted. `expandedPaths` is kept sorted so re-encoding
/// an otherwise-unchanged `Set` doesn't churn the stored JSON.
struct SessionSnapshot: Codable, Equatable {
    var expandedPaths: [String]
    var selectedPath: String?
    var treemapRootPath: String?
}

/// Persists `SessionSnapshot`s to `UserDefaults`, one JSON blob per volume root path
/// (mirrors `ColumnWidthsStore`'s shape). Fail-soft throughout: corrupt or missing data
/// yields `nil`/an empty session, never a crash — a lost session just means the next
/// launch reopens at the volume root instead of where the user left off.
@MainActor
@Observable
final class SessionStateStore {
    /// Above this many expanded folders, restoring them is noise rather than a
    /// convenience (and an unbounded set could grow the stored JSON without limit) — cap
    /// and drop the arbitrary excess (paths carry no recency to prefer one over another,
    /// so sorted-then-truncated is as good a cut as any). Revisit only on evidence.
    static let maxExpandedPaths = 2000

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Encodes and stores `snapshot` under `rootPath`'s key, capping/sorting
    /// `expandedPaths` first. Best-effort: an encode failure silently drops the save,
    /// same "worst case is a cold empty session" fallback as everywhere else here.
    func save(_ snapshot: SessionSnapshot, forVolume rootPath: String) {
        var capped = snapshot
        capped.expandedPaths.sort()
        if capped.expandedPaths.count > Self.maxExpandedPaths {
            capped.expandedPaths.removeLast(capped.expandedPaths.count - Self.maxExpandedPaths)
        }
        guard let data = try? JSONEncoder().encode(capped) else { return }
        defaults.set(data, forKey: Self.storageKey(forVolume: rootPath))
    }

    /// Loads the snapshot for `rootPath`, or `nil` when nothing is stored, or the stored
    /// bytes don't decode as `SessionSnapshot` (wrong type, malformed JSON, ...).
    func load(forVolume rootPath: String) -> SessionSnapshot? {
        guard let data = defaults.data(forKey: Self.storageKey(forVolume: rootPath)) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Exposed (rather than kept private) so tests can inject corrupt data at the exact
    /// key the store reads from — mirrors `TemporalSnapshot.snapshotURL(for:)`.
    static func storageKey(forVolume rootPath: String) -> String {
        "sessionState.\(String(fnv1a64(rootPath), radix: 16))"
    }

    /// Same 3-line FNV-1a algorithm as `TemporalSnapshot`'s private helper, duplicated
    /// rather than shared — that file is off-limits here (plan 038) and DirWizUI can't
    /// reach a `private` member of a DirWizCore type regardless.
    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
