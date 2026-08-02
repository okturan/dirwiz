import Foundation
import DirWizCore

/// A pure decision for reconciling the mounted-volume list with the selected scan target.
///
/// Mount notifications are availability facts, not scan actions. Most list changes therefore keep
/// the current target exactly as-is. Recovery is reserved for the three states where that target is
/// no longer truthful: a selected volume disappeared, the explicit combined choice became
/// impossible, or first launch discovery proved the remembered volume is absent.
struct VolumeAvailabilityDecision: Equatable, Sendable {
    enum RecoveryReason: Equatable, Sendable {
        case selectedVolumeUnavailable(String)
        case combinedSelectionUnavailable
        case rememberedVolumeUnavailable(String)

        var logDescription: String {
            switch self {
            case .selectedVolumeUnavailable(let path):
                "selected volume unavailable: \(path)"
            case .combinedSelectionUnavailable:
                "combined selection unavailable"
            case .rememberedVolumeUnavailable(let path):
                "remembered volume unavailable: \(path)"
            }
        }
    }

    let selectedVolume: URL?
    let selectedScope: MountTraversalScope
    let recoveryReason: RecoveryReason?
}

enum VolumeAvailabilityPolicy {
    static func resolve(
        availableVolumeURLs: [URL],
        selectedVolume: URL?,
        selectedScope: MountTraversalScope,
        rememberedVolumePath: String?
    ) -> VolumeAvailabilityDecision {
        let available = availableVolumeURLs.sorted {
            normalizedPath($0.path) < normalizedPath($1.path)
        }
        let fallback = available.first(where: { normalizedPath($0.path) == "/" })
            ?? available.first

        if selectedScope == .combinedVolumes {
            guard available.count < 2 else {
                return VolumeAvailabilityDecision(
                    selectedVolume: URL(fileURLWithPath: "/", isDirectory: true),
                    selectedScope: .combinedVolumes,
                    recoveryReason: nil
                )
            }
            return VolumeAvailabilityDecision(
                selectedVolume: fallback,
                selectedScope: .selectedVolume,
                recoveryReason: .combinedSelectionUnavailable
            )
        }

        if let selectedVolume {
            let selectedPath = normalizedPath(selectedVolume.path)
            if let mountedSelection = available.first(where: {
                normalizedPath($0.path) == selectedPath
            }) {
                return VolumeAvailabilityDecision(
                    selectedVolume: mountedSelection,
                    selectedScope: selectedScope,
                    recoveryReason: nil
                )
            }
            return VolumeAvailabilityDecision(
                selectedVolume: fallback,
                selectedScope: .selectedVolume,
                recoveryReason: .selectedVolumeUnavailable(selectedVolume.path)
            )
        }

        if let rememberedVolumePath, !rememberedVolumePath.isEmpty {
            let rememberedPath = normalizedPath(rememberedVolumePath)
            if let rememberedVolume = available.first(where: {
                normalizedPath($0.path) == rememberedPath
            }) {
                // A still-mounted remembered target with no restored cache keeps the existing
                // empty-launch contract: select it and let the user choose Scan Volume.
                return VolumeAvailabilityDecision(
                    selectedVolume: rememberedVolume,
                    selectedScope: .selectedVolume,
                    recoveryReason: nil
                )
            }
            return VolumeAvailabilityDecision(
                selectedVolume: fallback,
                selectedScope: .selectedVolume,
                recoveryReason: .rememberedVolumeUnavailable(rememberedVolumePath)
            )
        }

        // Truly fresh launch: choose a friendly concrete row but do not turn volume discovery into
        // an unsolicited whole-disk scan.
        return VolumeAvailabilityDecision(
            selectedVolume: fallback,
            selectedScope: .selectedVolume,
            recoveryReason: nil
        )
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
