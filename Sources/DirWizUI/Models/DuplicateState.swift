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
    }
}
