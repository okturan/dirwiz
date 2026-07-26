import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Auto-apply is background mutation of the displayed tree, so the guards matter more than
/// the feature. These pin the ones whose failure would be silent.
@Suite("Live Refresh Coordinator Tests")
@MainActor
struct LiveRefreshCoordinatorTests {

    /// `canStartHeavyTask` requires a tree — correctly, since there is nothing to splice
    /// into without one. Every state here gets a minimal one so the tests exercise the
    /// policy rather than the no-tree short circuit.
    private func stateWithTree() -> AppState {
        let state = AppState()
        let tree = FileTree()
        var root = FileNode(); root.isDirectory = true
        tree.addNode(root, name: "root")
        state.fileTree = tree
        return state
    }

    private func change(_ path: String) -> DirectoryChangeSummary {
        DirectoryChangeSummary(id: path, path: path, changeCount: 1, lastChangeDate: Date(),
                               hasCreations: true, hasDeletions: false, hasModifications: false)
    }

    /// The supervision invariant: a policy tick during a scan must not apply, and must not
    /// touch scan state. Auto-apply added a second writer to the tree, so this is the case
    /// that would corrupt a scan in progress.
    @Test("A tick during an active scan never applies")
    func noApplyDuringScan() {
        let state = stateWithTree()
        state.scanProgress.isScanning = true
        state.fsChanges = [change("/tmp/x")]
        state.lastLiveChangeAt = nil

        state.evaluateLiveRefresh()
        #expect(state.liveRefreshDecision == .deferred(reason: .scanning))
        #expect(state.scanProgress.isScanning, "evaluating must not mutate scan state")
    }

    /// `applyAccumulatedChanges` already refuses while another heavy task holds the slot;
    /// the policy must reach the same verdict so the pill can explain the wait.
    @Test("Applies defer while another heavy task holds the slot, then resume")
    func deferWhileHeavyTaskRuns() {
        let state = stateWithTree()
        state.fsChanges = [change("/tmp/x")]

        state.isApplyingChanges = true   // occupies the .applyChanges slot
        state.evaluateLiveRefresh()
        #expect(state.liveRefreshDecision == .deferred(reason: .heavyTaskRunning))

        state.isApplyingChanges = false
        state.evaluateLiveRefresh()
        #expect(state.liveRefreshDecision == .apply, "the deferral must not latch")
    }

    /// The temporal-diff overlay is index-keyed to a specific tree. Splicing under it would
    /// repaint the diff onto renumbered nodes without any visible sign of being wrong.
    @Test("Applies defer while the temporal-diff overlay is on")
    func deferWhileTemporalDiffActive() {
        let state = stateWithTree()
        state.fsChanges = [change("/tmp/x")]
        state.temporalDiff.isTemporalDiffEnabled = true

        state.evaluateLiveRefresh()
        #expect(state.liveRefreshDecision == .deferred(reason: .temporalDiffActive))

        state.temporalDiff.isTemporalDiffEnabled = false
        state.evaluateLiveRefresh()
        #expect(state.liveRefreshDecision == .apply)
    }

    @Test("Pausing blocks applies entirely but keeps changes pending")
    func pauseBlocksApplies() {
        let state = stateWithTree()
        state.fsChanges = [change("/tmp/x")]

        state.liveRefreshPaused = true
        state.evaluateLiveRefresh()
        #expect(state.liveRefreshDecision == .deferred(reason: .paused))
        #expect(state.fsChanges.count == 1,
                "pausing suppresses the automatic splice; it must not discard the queue")

        state.toggleLiveRefreshPaused()
        #expect(!state.liveRefreshPaused)
        #expect(state.liveRefreshDecision == .apply)

        state.liveRefreshPaused = false   // restore the shared UserDefaults key
    }

    /// Pausing is a considered choice; silently resuming next launch would be exactly the
    /// surprise the pause exists to prevent.
    @Test("The pause preference persists")
    func pausePersists() {
        let state = stateWithTree()
        let original = state.liveRefreshPaused
        defer {
            state.liveRefreshPaused = original
            UserDefaults.standard.set(original, forKey: AppState.livePausedKey)
        }

        state.liveRefreshPaused = true
        #expect(UserDefaults.standard.bool(forKey: AppState.livePausedKey))

        let relaunched = AppState()
        #expect(relaunched.liveRefreshPaused, "a fresh launch must honour the pause")
    }

    @Test("A storm routes to a full rescan rather than grinding splices")
    func stormRoutesToRescan() {
        let state = stateWithTree()
        state.fsChanges = (0...LiveRefreshPolicy.stormThreshold).map {
            change("/tmp/d\($0)")
        }
        state.evaluateLiveRefresh()
        #expect(state.liveRefreshDecision == .storm(pendingCount: state.fsChanges.count))
    }

    /// Starting a new scan must tear the loop down: the tree it was watching is about to be
    /// replaced, and a surviving task would splice into a stale object.
    @Test("Starting a new scan stops the live loop")
    func newScanStopsLoop() {
        let state = stateWithTree()
        state.isFSMonitoringActive = true
        state.fsChanges = [change("/tmp/x")]
        state.lastLiveChangeAt = CFAbsoluteTimeGetCurrent()

        state.resetForNewScan()

        #expect(!state.isFSMonitoringActive)
        #expect(state.liveRefreshTask == nil)
        #expect(state.lastLiveChangeAt == nil)
        #expect(state.liveRefreshDecision == .idle)
    }

    @Test("Stopping monitoring clears the loop and its verdict")
    func stopClearsState() {
        let state = stateWithTree()
        state.isFSMonitoringActive = true
        state.liveRefreshDecision = .apply

        state.stopLiveMonitoring()

        #expect(!state.isFSMonitoringActive)
        #expect(state.liveRefreshTask == nil)
        #expect(state.liveRefreshDecision == .idle)
    }
}
