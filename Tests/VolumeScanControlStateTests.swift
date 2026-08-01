import Foundation
import Testing
@testable import DirWizUI

@Suite("State-driven volume scan control")
struct VolumeScanControlStateTests {
    @Test("No selected volume leaves one disabled Scan Volume action")
    func noSelection() {
        let state = resolve(selected: nil, displayedRoot: nil)

        #expect(state == .scanVolume(enabled: false))
        #expect(state.title == "Scan Volume")
        #expect(!state.isEnabled)
        #expect(state.action == .none)
    }

    @Test("An undisplayed selected volume uses the normal scan action")
    func selectedVolumeWithoutDisplayedTree() {
        let state = resolve(selected: "/Volumes/Archive", displayedRoot: nil)

        #expect(state == .scanVolume(enabled: true))
        #expect(state.title == "Scan Volume")
        #expect(state.action == .scanVolume)
    }

    @Test("A matching displayed tree uses Full Rescan for root and mounted volumes")
    func displayedTreeOwnership() {
        #expect(resolve(selected: "/", displayedRoot: "/") == .fullRescan)
        #expect(
            resolve(
                selected: "/Volumes/Archive/../Archive/",
                displayedRoot: "/Volumes/Archive"
            ) == .fullRescan
        )
    }

    @Test("Cache policy cannot make an undisplayed tree look displayed")
    func cachePresenceIsNotPresentationState() {
        // Cache existence is deliberately absent from the resolver. Whether a normal scan can use
        // a cache does not turn this into a user-visible rebuild before that tree is displayed.
        let state = resolve(selected: "/Volumes/Cached", displayedRoot: nil)
        #expect(state == .scanVolume(enabled: true))
    }

    @Test("Switching volumes follows selection rather than the old displayed tree")
    func volumeSwitch() {
        let displayedRoot = "/Volumes/A"

        #expect(resolve(selected: "/Volumes/A", displayedRoot: displayedRoot) == .fullRescan)
        #expect(
            resolve(selected: "/Volumes/B", displayedRoot: displayedRoot)
                == .scanVolume(enabled: true)
        )
        #expect(resolve(selected: "/Volumes/A", displayedRoot: displayedRoot) == .fullRescan)
    }

    @Test("Busy states explain work and reject actions")
    func busyStates() {
        let checking = resolve(
            selected: "/",
            displayedRoot: "/",
            isScanning: true,
            isPreparing: true
        )
        #expect(checking == .checkingChanges)
        #expect(checking.title == "Checking changes…")
        #expect(checking.showsProgress)
        #expect(!checking.isEnabled)
        #expect(checking.action == .none)

        let scanning = resolve(
            selected: "/",
            displayedRoot: "/",
            isScanning: true
        )
        #expect(scanning == .scanning)
        #expect(scanning.title == "Scanning…")
        #expect(scanning.showsProgress)
        #expect(!scanning.isEnabled)
        #expect(scanning.action == .none)

        let updating = resolve(
            selected: "/",
            displayedRoot: "/",
            isApplying: true
        )
        #expect(updating == .updating)
        #expect(updating.title == "Updating…")
        #expect(updating.showsProgress)
        #expect(!updating.isEnabled)
        #expect(updating.action == .none)
    }

    @Test("Scan work has deterministic precedence over a defensive apply overlap")
    func busyPrecedence() {
        #expect(
            resolve(
                selected: "/",
                displayedRoot: "/",
                isScanning: true,
                isPreparing: true,
                isApplying: true
            ) == .checkingChanges
        )
        #expect(
            resolve(
                selected: "/",
                displayedRoot: "/",
                isScanning: true,
                isApplying: true
            ) == .scanning
        )
    }

    @Test("Launch refresh settles from busy to the displayed tree's Full Rescan")
    func launchRestoreLifecycle() {
        let selected = "/Volumes/Restored"

        #expect(
            resolve(
                selected: selected,
                displayedRoot: selected,
                isScanning: true,
                isPreparing: true
            ) == .checkingChanges
        )
        #expect(
            resolve(selected: selected, displayedRoot: selected, isScanning: true) == .scanning
        )
        #expect(resolve(selected: selected, displayedRoot: selected) == .fullRescan)
    }

    @Test("Live apply settles back to Full Rescan for the still-displayed tree")
    func liveApplyLifecycle() {
        let selected = "/Volumes/Live"

        #expect(
            resolve(selected: selected, displayedRoot: selected, isApplying: true) == .updating
        )
        // Cancelled or failed automatic work has no active flag; if its tree remains displayed,
        // the only manual operation is still the forced-cold rebuild.
        #expect(resolve(selected: selected, displayedRoot: selected) == .fullRescan)
    }

    @Test("Label state and dispatched callback change together")
    func actionRouting() {
        var normalScans = 0
        var fullScans = 0
        let onScan = { normalScans += 1 }
        let onFullRescan = { fullScans += 1 }

        resolve(selected: "/Volumes/B", displayedRoot: "/Volumes/A")
            .perform(onScan: onScan, onFullRescan: onFullRescan)
        #expect(normalScans == 1)
        #expect(fullScans == 0)

        resolve(selected: "/Volumes/A", displayedRoot: "/Volumes/A")
            .perform(onScan: onScan, onFullRescan: onFullRescan)
        #expect(normalScans == 1)
        #expect(fullScans == 1)

        resolve(
            selected: "/Volumes/A",
            displayedRoot: "/Volumes/A",
            isApplying: true
        ).perform(onScan: onScan, onFullRescan: onFullRescan)
        #expect(normalScans == 1)
        #expect(fullScans == 1)
    }

    private func resolve(
        selected path: String?,
        displayedRoot: String?,
        isScanning: Bool = false,
        isPreparing: Bool = false,
        isApplying: Bool = false
    ) -> VolumeScanControlState {
        VolumeScanControlState.resolve(
            selectedVolume: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
            displayedTreeRootPath: displayedRoot,
            isScanning: isScanning,
            isPreparingScan: isPreparing,
            isApplyingChanges: isApplying
        )
    }
}
