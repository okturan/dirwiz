import Foundation
import DirWizCore

/// The one persistent scan control in the volume sidebar.
///
/// Cache presence deliberately is not an input. A cache is scan-planner state, not proof that the
/// selected volume owns the tree currently displayed. Keeping presentation and action in one value
/// also prevents a `Full Rescan` label from dispatching the normal scan callback (or vice versa)
/// after a volume switch.
enum VolumeScanControlState: Equatable, Sendable {
    case scanVolume(enabled: Bool)
    case scanAllVolumes(enabled: Bool)
    case fullRescan
    case checkingChanges
    case scanning
    case updating

    enum Action: Equatable, Sendable {
        case none
        case scanVolume
        case fullRescan
    }

    static func resolve(
        selectedVolume: URL?,
        selectedMountTraversalScope: MountTraversalScope = .selectedVolume,
        displayedTreeRootPath: String?,
        displayedTreeMountTraversalScope: MountTraversalScope? = .selectedVolume,
        isScanning: Bool,
        isPreparingScan: Bool,
        isApplyingChanges: Bool
    ) -> VolumeScanControlState {
        // `isPreparingScan` refines `isScanning`; keep scan work ahead of the defensive
        // `isApplyingChanges` overlap so an impossible flag combination is still deterministic.
        if isScanning {
            return isPreparingScan ? .checkingChanges : .scanning
        }
        if isApplyingChanges {
            return .updating
        }
        if displayedTreeBelongsToSelectedVolume(
            selectedVolume: selectedVolume,
            selectedMountTraversalScope: selectedMountTraversalScope,
            displayedTreeRootPath: displayedTreeRootPath,
            displayedTreeMountTraversalScope: displayedTreeMountTraversalScope
        ) {
            return .fullRescan
        }
        if selectedMountTraversalScope == .combinedVolumes {
            return .scanAllVolumes(enabled: selectedVolume != nil)
        }
        return .scanVolume(enabled: selectedVolume != nil)
    }

    static func displayedTreeBelongsToSelectedVolume(
        selectedVolume: URL?,
        selectedMountTraversalScope: MountTraversalScope,
        displayedTreeRootPath: String?,
        displayedTreeMountTraversalScope: MountTraversalScope?
    ) -> Bool {
        guard let selectedVolume,
              let displayedTreeRootPath,
              let displayedTreeMountTraversalScope else { return false }
        return normalizedVolumePath(selectedVolume.path) == normalizedVolumePath(displayedTreeRootPath)
            && selectedMountTraversalScope == displayedTreeMountTraversalScope
    }

    var title: String {
        switch self {
        case .scanVolume: "Scan Volume"
        case .scanAllVolumes: "Scan All Volumes"
        case .fullRescan: "Full Rescan"
        case .checkingChanges: "Checking changes…"
        case .scanning: "Scanning…"
        case .updating: "Updating…"
        }
    }

    var systemImage: String? {
        switch self {
        case .scanVolume, .scanAllVolumes: "magnifyingglass"
        case .fullRescan: "arrow.clockwise"
        case .checkingChanges, .scanning, .updating: nil
        }
    }

    var showsProgress: Bool {
        switch self {
        case .checkingChanges, .scanning, .updating: true
        case .scanVolume, .scanAllVolumes, .fullRescan: false
        }
    }

    var isEnabled: Bool {
        switch self {
        case .scanVolume(let enabled): enabled
        case .scanAllVolumes(let enabled): enabled
        case .fullRescan: true
        case .checkingChanges, .scanning, .updating: false
        }
    }

    var action: Action {
        switch self {
        case .scanVolume(enabled: true), .scanAllVolumes(enabled: true): .scanVolume
        case .fullRescan: .fullRescan
        case .scanVolume(enabled: false), .scanAllVolumes(enabled: false),
             .checkingChanges, .scanning, .updating: .none
        }
    }

    var helpText: String {
        switch self {
        case .scanVolume(enabled: true):
            "Scan the selected volume"
        case .scanVolume(enabled: false):
            "Select a volume to scan"
        case .scanAllVolumes(enabled: true):
            "Scan all mounted volumes into one combined map"
        case .scanAllVolumes(enabled: false):
            "Connect at least two volumes to use a combined map"
        case .fullRescan:
            "Ignore the last scan's cache and re-enumerate everything"
        case .checkingChanges:
            "Checking the last scan for filesystem changes"
        case .scanning:
            "Scanning the selected volume"
        case .updating:
            "Applying filesystem changes to the displayed tree"
        }
    }

    func perform(onScan: () -> Void, onFullRescan: () -> Void) {
        switch action {
        case .none: return
        case .scanVolume: onScan()
        case .fullRescan: onFullRescan()
        }
    }

    private static func normalizedVolumePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
