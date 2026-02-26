import Foundation
import Observation

/// Focused sub-model for temporal diff overlay state.
/// Extracted from AppState to reduce god-object complexity.
/// Note: temporalDiffToken, temporalDiffTask, and the task coordination remain in AppState.
@MainActor
@Observable
public final class TemporalDiffState {
    /// Snapshot loaded from disk for comparison (nil = none taken yet).
    public var temporalSnapshot: TemporalSnapshot?

    /// Whether the temporal diff overlay is currently active.
    public var isTemporalDiffEnabled: Bool = false

    /// Whether a snapshot save/build is in progress.
    public var isSnapshotBuilding: Bool = false

    /// Bumped each time diff results are applied (GPU change detection).
    public var temporalDiffGeneration: UInt64 = 0

    /// Per-node diff kind (TemporalDiffKind.rawValue). Files are always .none.
    public var temporalDiffKinds: [UInt8] = []

    /// Per-node blend strength [0,1] for the diff tint.
    public var temporalDiffStrengths: [Float] = []

    /// Surviving ancestors → count/bytes of deleted descendants (for tooltips).
    public var temporalDiffDeletedCounts: [UInt32: DeletedSummary] = [:]

    public init() {}

    /// Reset temporal diff state for a new scan.
    public func reset() {
        temporalDiffKinds = []
        temporalDiffStrengths = []
        temporalDiffDeletedCounts = [:]
        temporalDiffGeneration = 0
        isTemporalDiffEnabled = false
    }
}
