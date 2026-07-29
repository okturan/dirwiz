import Foundation
import DirWizCore
import Observation

/// Focused sub-model for duplicate scan state.
/// Extracted from AppState to reduce god-object complexity.
@MainActor
@Observable
public final class DuplicateState {
    /// Duplicate file groups (populated after duplicate scan).
    public var duplicateGroups: [DuplicateGroup] = []

    /// Duplicates tab UI state: checked file paths.
    public var duplicateCheckedPaths: Set<String> = []

    /// Duplicates tab UI state: expanded duplicate group IDs.
    public var duplicateExpandedGroups: Set<UUID> = []

    /// Duplicates tab UI state: progress of current duplicate scan.
    public var duplicateProgress: (processed: Int, total: Int) = (0, 0)

    /// Whether a duplicate scan is in progress.
    public var isDuplicateScanRunning: Bool = false

    /// Current phase of an active duplicate scan.
    public var duplicatePhase: DuplicateScanPhase = .groupingBySize

    /// Minimum file size used by the most recently started duplicate scan.
    public var lastDuplicateScanMinimumSize: UInt64 = 1_048_576

    // MARK: - Instant (heuristic) duplicates

    /// Name+size candidates from the in-memory pass. NOT content-verified, and a different
    /// type from `DuplicateGroup` so they cannot reach the trash paths.
    public var instantCandidates: [InstantDuplicateCandidate] = []

    /// True while the instant pass is running. Distinct from `isDuplicateScanRunning`,
    /// which means the exhaustive content scan.
    public var isInstantGroupingRunning: Bool = false

    /// Guards against a stale instant pass overwriting a newer one, matching the
    /// token discipline used by the other background analyses.
    public var instantToken: UInt64 = 0

    /// Candidate ids currently being byte-verified.
    public var verifyingCandidateIDs: Set<String> = []

    /// Groups confirmed in this session, so the UI can point at what a Verify produced
    /// instead of leaving the row to vanish silently.
    public var lastConfirmedGroupIDs: Set<UUID> = []
    /// What the most recent verification found, phrased for a human.
    public var lastVerifyOutcome: String?

    /// Candidate ids that were verified and produced NO identical group - same name, same
    /// size, different bytes. Surfaced so a rejected candidate reads as a checked answer
    /// rather than as a button that did nothing.
    public var rejectedCandidateIDs: Set<String> = []

    /// Files considered by the last instant pass, for the "scanned N files" line.
    public var instantFilesConsidered: Int = 0
    public var instantElapsedMs: Double = 0

    public var totalPotentialWaste: UInt64 {
        instantCandidates.reduce(0) { $0 + $1.potentialWaste }
    }

    /// Removes candidates whose paths are all accounted for by a confirmed group, so a
    /// verified group is not also still listed as an unverified guess.
    public func pruneVerifiedCandidates() {
        guard !duplicateGroups.isEmpty else { return }
        let confirmed = Set(duplicateGroups.flatMap(\.paths))
        instantCandidates.removeAll { candidate in
            candidate.paths.allSatisfy { confirmed.contains($0) }
        }
    }

    public init() {}

    /// Reset duplicate state for a new scan.
    public func reset() {
        duplicateGroups = []
        duplicateCheckedPaths = []
        duplicateExpandedGroups = []
        duplicateProgress = (0, 0)
        isDuplicateScanRunning = false
        duplicatePhase = .groupingBySize
        lastDuplicateScanMinimumSize = 1_048_576
        resetInstant()
    }

    /// Cleared both on a new scan and after any tree mutation - the candidate paths may no
    /// longer exist, and a stale candidate offering to verify a trashed file is worse than
    /// no candidate at all.
    public func resetInstant() {
        instantCandidates = []
        isInstantGroupingRunning = false
        instantToken &+= 1
        verifyingCandidateIDs = []
        rejectedCandidateIDs = []
        lastConfirmedGroupIDs = []
        lastVerifyOutcome = nil
        instantFilesConsidered = 0
        instantElapsedMs = 0
    }
}
