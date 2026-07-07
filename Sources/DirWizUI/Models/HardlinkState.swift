import Foundation
import DirWizCore
import Observation

/// Focused sub-model for hardlink scan state.
/// Extracted from AppState to reduce god-object complexity.
@MainActor
@Observable
public final class HardlinkState {
    /// Hardlink groups (populated after hardlink scan).
    public var hardlinkGroups: [HardlinkGroup] = []

    /// Hardlinks tab UI state: expanded hardlink group IDs.
    public var hardlinkExpandedGroups: Set<UUID> = []

    /// Hardlinks tab UI state: progress of current hardlink scan.
    public var hardlinkProgress: (processed: Int, total: Int) = (0, 0)

    /// Whether a hardlink scan is in progress.
    public var isHardlinkScanRunning: Bool = false

    public init() {}

    /// Reset hardlink state for a new scan.
    public func reset() {
        hardlinkGroups = []
        hardlinkExpandedGroups = []
        hardlinkProgress = (0, 0)
        isHardlinkScanRunning = false
    }
}
