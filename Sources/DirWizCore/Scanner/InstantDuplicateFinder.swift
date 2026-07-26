import Foundation

/// A set of files that share a size and a name. **Not** confirmed duplicates.
///
/// This is deliberately a DIFFERENT type from `DuplicateGroup`, not a flag on it. The
/// cleanup and trash paths take `DuplicateGroup`, so a heuristic candidate cannot reach
/// them by accident - the compiler enforces the gate that a boolean would leave to
/// reviewer discipline. Files only become a `DuplicateGroup` by passing byte verification.
public struct InstantDuplicateCandidate: Identifiable, Sendable {
    public let id = UUID()
    public let fileSize: UInt64
    /// The shared name, as displayed (original case of the first member).
    public let name: String
    public let paths: [String]

    public init(fileSize: UInt64, name: String, paths: [String]) {
        self.fileSize = fileSize
        self.name = name
        self.paths = paths
    }

    /// Bytes that WOULD be reclaimed if these turn out to be identical. Phrased as
    /// "potential" everywhere in the UI, because nothing here has been content-verified.
    public var potentialWaste: UInt64 {
        guard paths.count > 1 else { return 0 }
        return fileSize * UInt64(paths.count - 1)
    }
}

public struct InstantDuplicateReport: Sendable {
    public let candidates: [InstantDuplicateCandidate]
    public let filesConsidered: Int
    public let elapsedTime: TimeInterval
    /// False when the work was cancelled partway; results are then incomplete.
    public let completed: Bool

    public var totalPotentialWaste: UInt64 {
        candidates.reduce(0) { $0 + $1.potentialWaste }
    }
}

/// Groups files by `(size, case-folded name)` using only the scanned tree - zero file
/// content reads, so it finishes in well under a second where the hashing scan takes
/// minutes. It answers "what is worth verifying?", never "what is safe to delete?".
public struct InstantDuplicateFinder: Sendable {
    public let minimumFileSize: UInt64
    /// Match names case-insensitively. Default true: APFS is case-insensitive by default,
    /// so `Report.PDF` and `report.pdf` are the same name to most users.
    public let caseInsensitiveNames: Bool

    public init(minimumFileSize: UInt64 = 1_048_576, caseInsensitiveNames: Bool = true) {
        self.minimumFileSize = max(1, minimumFileSize)
        self.caseInsensitiveNames = caseInsensitiveNames
    }

    /// Key combining size and folded name. Two files collide only if both match.
    private struct Key: Hashable {
        let size: UInt64
        let name: String
    }

    public func findCandidates(in tree: FileTree) -> InstantDuplicateReport {
        let start = CFAbsoluteTimeGetCurrent()
        let snapshot = tree.pathBuildingSnapshot()
        let nodes = snapshot.nodes

        // Pass 1: bucket every qualifying file by (size, folded name).
        var buckets: [Key: [UInt32]] = [:]
        var considered = 0
        let completed = FileTree.forEachFileInSnapshot(nodes) { index, node in
            guard node.fileSize >= minimumFileSize else { return }
            let raw = FileTree.nameFromSnapshot(at: UInt32(index), nodes: nodes,
                                                stringPool: snapshot.stringPool)
            guard !raw.isEmpty else { return }
            considered += 1
            let folded = caseInsensitiveNames ? raw.lowercased() : raw
            buckets[Key(size: node.fileSize, name: folded), default: []].append(UInt32(index))
        }

        guard completed else {
            return InstantDuplicateReport(candidates: [], filesConsidered: considered,
                                          elapsedTime: CFAbsoluteTimeGetCurrent() - start,
                                          completed: false)
        }

        // Pass 2: collapse hardlinks, drop singletons, build paths.
        var candidates: [InstantDuplicateCandidate] = []
        for (key, indices) in buckets {
            guard indices.count > 1 else { continue }

            // Files sharing (device, inode) are ONE file with several names. Counting them
            // as duplicates would promise space that deleting them cannot reclaim.
            var seenIdentities = Set<Int64>()
            var representatives: [UInt32] = []
            for idx in indices {
                let node = nodes[Int(idx)]
                let identity = Int64(node.device) << 48 ^ Int64(bitPattern: node.inode)
                if node.inode != 0 {
                    guard seenIdentities.insert(identity).inserted else { continue }
                }
                representatives.append(idx)
            }
            guard representatives.count > 1 else { continue }

            let paths = representatives.map {
                FileTree.pathFromSnapshot(at: $0, nodes: nodes,
                                          stringPool: snapshot.stringPool,
                                          rootPath: snapshot.rootPath)
            }
            let displayName = FileTree.nameFromSnapshot(at: representatives[0], nodes: nodes,
                                                        stringPool: snapshot.stringPool)
            candidates.append(InstantDuplicateCandidate(
                fileSize: key.size, name: displayName, paths: paths
            ))
        }

        // Biggest opportunity first; name breaks ties so repeated runs are stable.
        candidates.sort {
            $0.potentialWaste != $1.potentialWaste
                ? $0.potentialWaste > $1.potentialWaste
                : $0.name < $1.name
        }

        return InstantDuplicateReport(candidates: candidates, filesConsidered: considered,
                                      elapsedTime: CFAbsoluteTimeGetCurrent() - start,
                                      completed: true)
    }
}

/// Promotes heuristic candidates to confirmed, actionable duplicate groups.
///
/// This is the ONLY way an `InstantDuplicateCandidate` becomes a `DuplicateGroup`, and it
/// goes through `DuplicateContentVerifier`, the same byte-exact comparison (opening with
/// `O_NOFOLLOW`) that already guards the full scan's trash path. Nothing here trusts the
/// name-and-size heuristic that produced the candidate.
public enum InstantDuplicateVerifier {

    /// Byte-verifies one candidate.
    ///
    /// Returns possibly SEVERAL groups, or none: files sharing a name and size routinely
    /// differ in content, and a candidate can also split into two genuine sub-groups. A
    /// single-group return type would have forced a lie in exactly those cases.
    public static func verify(_ candidate: InstantDuplicateCandidate) -> [DuplicateGroup] {
        let groups = DuplicateContentVerifier.exactGroups(
            paths: candidate.paths, expectedSize: candidate.fileSize
        )
        return groups.map { paths in
            // hash 0: these groups are established by direct byte comparison, not by a
            // hash, and no consumer reads the field for verified-by-content groups.
            DuplicateGroup(fileSize: candidate.fileSize, hash: 0, paths: paths.sorted())
        }
    }

    /// Verifies many candidates, newest results first by wasted space.
    ///
    /// Cooperatively cancellable: verification does real I/O, so a user switching away
    /// must not leave it grinding. Returns what was confirmed before the cancel.
    public static func verifyAll(_ candidates: [InstantDuplicateCandidate]) -> [DuplicateGroup] {
        var confirmed: [DuplicateGroup] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            confirmed.append(contentsOf: verify(candidate))
        }
        confirmed.sort {
            $0.wastedSpace != $1.wastedSpace
                ? $0.wastedSpace > $1.wastedSpace
                : ($0.paths.first ?? "") < ($1.paths.first ?? "")
        }
        return confirmed
    }
}
