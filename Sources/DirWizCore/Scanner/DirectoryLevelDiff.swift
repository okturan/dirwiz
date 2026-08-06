import Foundation

/// What one directory's entry level looks like, reduced to the facts that decide whether
/// a cached child can be kept.
///
/// Only identity and shape live here - never size or dates. Metadata differences are
/// applied in place to a kept child and must not make it look structurally changed.
public struct DirectoryEntryIdentity: Hashable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let isBundle: Bool

    public init(name: String, isDirectory: Bool, isBundle: Bool) {
        self.name = name
        self.isDirectory = isDirectory
        self.isBundle = isBundle
    }
}

/// Reconciles a changed directory against its cached children.
///
/// The whole point of `selective-child-rescan`: an FSEvents event on a directory says
/// only "this directory's own level is stale". Re-enumerating its entire subtree because
/// of that is what made one new folder inside a 400k-file directory cost 400k items, both
/// in the admission estimate ("~84% of files changed") and in the actual patch. Comparing
/// the fresh level with the cached one tells us exactly which children need work, and the
/// rest keep their subtrees untouched - changes inside them arrive as their own events.
///
/// Pure and allocation-light so it is testable without a filesystem and cheap to run per
/// changed directory.
public enum DirectoryLevelDiff {

    public struct Result: Equatable, Sendable {
        /// Present on both sides with the same shape: keep the node and its subtree,
        /// refresh its metadata in place.
        public var unchanged: [String] = []
        /// On disk but not in the cache: enumerate this entry's subtree and install it.
        public var added: [String] = []
        /// In the cache but not on disk: remove this child's subtree.
        public var removed: [String] = []
        /// Same name, different shape (file↔directory, plain↔bundle). Removal plus
        /// addition, because the node's meaning changed - its cached descendants, if any,
        /// describe something that no longer exists.
        public var typeChanged: [String] = []

        /// Nothing structural to do: every entry is present on both sides with the same
        /// shape, so the patch is a pure in-place metadata refresh.
        public var isMetadataOnly: Bool {
            added.isEmpty && removed.isEmpty && typeChanged.isEmpty
        }

        /// Entries whose subtrees must be enumerated: fresh arrivals plus the additions
        /// implied by a type change.
        public var requiresEnumeration: [String] { added + typeChanged }

        /// Entries whose cached subtrees must go: departures plus the removals implied by
        /// a type change.
        public var requiresRemoval: [String] { removed + typeChanged }
    }

    /// - Parameters:
    ///   - cached: the directory's children as the cached tree has them.
    ///   - fresh: the directory's children as just read from disk.
    ///   - isCaseSensitive: how the owning volume compares names. On a case-insensitive
    ///     volume "Photos" and "photos" are the same entry, so treating them as an
    ///     add plus a remove would delete and re-read a subtree for nothing. A case-only
    ///     RENAME is still structural on both kinds of volume, because the stored name is
    ///     user-visible - it is reported through `typeChanged` so the entry is replaced.
    public static func compare(
        cached: [DirectoryEntryIdentity],
        fresh: [DirectoryEntryIdentity],
        isCaseSensitive: Bool
    ) -> Result {
        var result = Result()

        func key(_ name: String) -> String {
            isCaseSensitive ? name : name.lowercased()
        }

        var cachedByKey: [String: DirectoryEntryIdentity] = [:]
        cachedByKey.reserveCapacity(cached.count)
        for entry in cached { cachedByKey[key(entry.name)] = entry }

        var seenKeys = Set<String>()
        seenKeys.reserveCapacity(fresh.count)

        for entry in fresh {
            let entryKey = key(entry.name)
            seenKeys.insert(entryKey)
            guard let match = cachedByKey[entryKey] else {
                result.added.append(entry.name)
                continue
            }
            if match.isDirectory == entry.isDirectory
                && match.isBundle == entry.isBundle
                && match.name == entry.name {
                result.unchanged.append(entry.name)
            } else {
                // Shape or exact spelling differs: the cached node describes something
                // else now, so replace it rather than patch metadata onto it.
                result.typeChanged.append(entry.name)
            }
        }

        for entry in cached where !seenKeys.contains(key(entry.name)) {
            result.removed.append(entry.name)
        }

        return result
    }
}
