import Foundation

/// Pure summarization of a `TemporalDiffResult` into per-kind counts and a size-ranked
/// list of changed directories. Used by the CLI's `diff` command (and any future reporting
/// surface) to turn the node-parallel diff arrays into something printable, without any
/// I/O of its own — this makes it directly unit-testable.
public struct TemporalDiffSummary: Sendable {
    /// One changed directory: where it is, how it changed, and its size at scan time.
    public struct Entry: Sendable {
        public let path: String
        public let kind: TemporalDiffKind
        public let currentSize: UInt64
    }

    public let newCount: Int
    public let grownCount: Int
    public let shrunkCount: Int
    /// Number of surviving directories flagged `.deletedDescendants` in `result.kinds` —
    /// i.e. directories whose own size change (if any) wasn't enough to earn `.grown`/
    /// `.shrunk`, but that lost one or more sub-directories since the snapshot.
    ///
    /// This counts *ancestor directories*, not deleted paths: `TemporalDiffService`
    /// assigns `.deletedDescendants` to a node only when it would otherwise be `.none`
    /// (a stronger `.grown`/`.shrunk` classification always wins — see
    /// `TemporalDiffService.computeDiffSync`), and a single surviving ancestor can absorb
    /// many deleted paths in `deletedByNode`. So this count can be smaller than
    /// `deletedByNode.count` (ancestors that are also `.grown`/`.shrunk` are excluded here)
    /// and smaller still than the sum of each entry's `DeletedSummary.count` (multiple
    /// deleted paths collapsing onto one ancestor).
    public let lostDescendantsCount: Int

    /// Changed directories (any kind other than `.none`), sorted by current size
    /// descending and capped to `topLimit` entries.
    public let topChanged: [Entry]

    /// Summarize a diff result computed over the given node snapshot.
    /// `nodes`, `stringPool`, and `rootPath` must be the same snapshot passed to
    /// `TemporalDiffService.computeDiff` that produced `result` — indices in
    /// `result.kinds` / `result.strengths` are positional over `nodes`.
    public static func summarize(
        result: TemporalDiffResult,
        nodes: [FileNode],
        stringPool: Data,
        rootPath: String,
        topLimit: Int = 20
    ) -> TemporalDiffSummary {
        var newCount = 0
        var grownCount = 0
        var shrunkCount = 0
        var lostDescendantsCount = 0
        var changed: [Entry] = []

        // Defensive: result.kinds is expected to be exactly nodes.count long (that's the
        // contract TemporalDiffService.computeDiff upholds), but don't trust it blindly.
        let count = min(nodes.count, result.kinds.count)
        for i in 0..<count {
            // Only directories are ever classified by TemporalDiffService, but guard
            // defensively rather than trust that invariant from the caller's data.
            guard nodes[i].isDirectory else { continue }
            guard let kind = TemporalDiffKind(rawValue: result.kinds[i]) else { continue }

            switch kind {
            case .none:
                continue
            case .new:
                newCount += 1
            case .grown:
                grownCount += 1
            case .shrunk:
                shrunkCount += 1
            case .deletedDescendants:
                lostDescendantsCount += 1
            }

            let path = FileTree.pathFromSnapshot(
                at: UInt32(i), nodes: nodes, stringPool: stringPool, rootPath: rootPath
            )
            changed.append(Entry(path: path, kind: kind, currentSize: nodes[i].displaySize))
        }

        changed.sort { $0.currentSize > $1.currentSize }
        let cap = max(0, topLimit)
        if changed.count > cap {
            changed.removeLast(changed.count - cap)
        }

        return TemporalDiffSummary(
            newCount: newCount,
            grownCount: grownCount,
            shrunkCount: shrunkCount,
            lostDescendantsCount: lostDescendantsCount,
            topChanged: changed
        )
    }
}
