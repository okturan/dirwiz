import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Coverage for plan 040: the scan-flow supervision invariant documented on
/// `AppState.startScan` (`AppState+Scan.swift`) — after any scan flow exits by ANY path,
/// either a newer flow has already published its own fresh `ScanProgress`, or the
/// currently-published one is honestly terminal (`isScanning == false`). Wave 7's flows
/// (launch auto-refresh, warm patch, preserving-cold, replay-wait windows) introduced exit
/// paths that could leave the *displayed* `ScanProgress` frozen mid-scan; this suite pins
/// the reproduction of that incident plus the supervisor's other guarantees.
///
/// Nested under `AppSupportEnvSuites` (TestHelpers.swift) and wrapped in
/// `withTemporaryAppSupportDir` throughout: every test here drives `restoreOnLaunch` /
/// `startFullRescan` to completion, and a completed cold scan's deferred bundle sizing
/// always ends with a `TreeCache.save` — both read `DIRWIZ_APP_SUPPORT_DIR`.
extension AppSupportEnvSuites {

@Suite("Scan Supervision Tests")
struct ScanSupervisionTests {

    private static let layout: [String: UInt64] = [
        "docs/readme.txt": 100,
        "docs/notes.md": 200,
        "images/photo.jpg": 500,
    ]

    private static let lastScannedVolumePathKey = "lastScannedVolumePath"

    private func makeEphemeralDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// Polls `condition` on the main actor until it's true or `timeout` elapses — mirrors
    /// `LaunchRestoreTests`'/`AppliedChangesTests`' helper of the same name (duplicated
    /// rather than shared, matching this repo's per-suite convention for these small
    /// test-only helpers).
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        pollInterval: Duration = .milliseconds(20),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func nodeIndex(in tree: FileTree, pathSuffix suffix: String) -> UInt32? {
        let nodes = tree.nodesSnapshot()
        for i in nodes.indices where tree.path(at: UInt32(i)).hasSuffix(suffix) {
            return UInt32(i)
        }
        return nil
    }

    private func scanFixture(at path: String) async -> FileTree {
        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)
        return tree
    }

    /// A large-ish real fixture, big enough that a real on-disk scan is still running a
    /// few milliseconds in — same trick `LaunchRestoreTests.cancellingColdRefreshBehindStaleKeepsStaleViewBody`
    /// uses to get a reliable window to land a cancel/supersede mid-flight.
    private func manyFilesLayout() -> [String: UInt64] {
        var layout: [String: UInt64] = [:]
        for dir in 0..<150 {
            for file in 0..<40 {
                layout["dir\(dir)/file\(file).dat"] = UInt64(file + 1)
            }
        }
        return layout
    }

    /// FSEvents reports the fully resolved on-disk path for a watched root; `/tmp`-based
    /// fixtures live under `/var`, itself a symlink to `/private/var` that Foundation's
    /// `resolvingSymlinksInPath` deliberately leaves untouched. Resolve through raw
    /// `realpath(3)` so the root we scan/watch and the root FSEvents reports changes under
    /// are the same string — same helper as `WarmStartTests`, duplicated per this repo's
    /// per-suite convention.
    private func realDirectoryPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The FSEvents daemon journals asynchronously; give it a moment to catch up before
    /// treating "now" as a clean boundary — same helper as `WarmStartTests`.
    private func settleFSEventsJournal() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    // MARK: - 1. The incident reproduction

    @Test("The incident: clicking Scan Volume then Full Rescan during the launch auto-refresh's replay-wait never strands the UI")
    func incidentReproduction() async throws {
        try await withTemporaryAppSupportDir {
            try await self.incidentReproductionBody()
        }
    }

    @MainActor
    private func incidentReproductionBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)
        try TreeCache.save(tree: tree, lastEventId: FSEventsJournal.currentEventId())

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(path, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        state.restoreOnLaunch()  // launch auto-refresh begins its own replay-wait

        // The user's reported sequence: click "Scan Volume", then immediately "Full
        // Rescan" — both landing before the auto-refresh's (or the first click's) own
        // replay-wait has resolved. Calling both synchronously back-to-back, with no
        // `await` in between, guarantees this: `startScan` only ever suspends inside a
        // `Task` it launches and returns immediately, so nothing here has had a chance
        // to progress before the next call lands.
        state.startSelectedVolumeScan()
        state.startFullRescan()

        await waitUntil(timeout: 20) { !state.scanProgress.isScanning }

        // INVARIANT: however many superseding clicks landed mid-flight, the final
        // displayed state must be terminal — never frozen mid-scan (the incident).
        #expect(!state.scanProgress.isScanning)
        #expect(state.fileTree != nil)
        #expect(state.selectedVolume != nil, "the Scan Volume button needs a selected volume to re-enable")
    }

    // MARK: - 2. Superseded preserving-cold

    @Test("Superseding a preserving-cold scan mid-flight with another leaves a coherent final state")
    func supersededPreservingCold() async throws {
        try await withTemporaryAppSupportDir {
            try await self.supersededPreservingColdBody()
        }
    }

    @MainActor
    private func supersededPreservingColdBody() async throws {
        let (path, cleanup) = try createTempTree(manyFilesLayout())
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        state.staleViewAsOf = Date(timeIntervalSinceNow: -3600)

        state.startFullRescan()
        await waitUntil(timeout: 2, pollInterval: .milliseconds(1)) { state.scanProgress.isScanning }

        // Supersede mid-scan with another full rescan, exactly as a second click would.
        state.startFullRescan()

        await waitUntil(timeout: 20) { !state.scanProgress.isScanning }

        #expect(!state.scanProgress.isScanning)
        #expect(state.fileTree != nil)
    }

    // MARK: - 3. Cancel mid-preserving-cold (frozen-bar regression pin)

    @Test("Cancelling a preserving-cold scan keeps the stale view in place and clears isScanning")
    func cancelMidPreservingCold() async throws {
        try await withTemporaryAppSupportDir {
            try await self.cancelMidPreservingColdBody()
        }
    }

    @MainActor
    private func cancelMidPreservingColdBody() async throws {
        let (path, cleanup) = try createTempTree(manyFilesLayout())
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        let savedAt = Date(timeIntervalSinceNow: -3600)
        state.staleViewAsOf = savedAt

        state.startFullRescan()
        await waitUntil(timeout: 2, pollInterval: .milliseconds(1)) { state.scanProgress.isScanning }
        state.cancelScan()

        await waitUntil(timeout: 20) { !state.scanProgress.isScanning }

        #expect(state.scanProgress.isCancelled, "expected the cancel to land before the (real, on-disk) scan finished")
        #expect(state.staleViewAsOf == savedAt, "cancelling must not clear the stale badge")
        #expect(state.fileTree === tree, "cancelling must leave the stale tree in place, unswapped")
    }

    // MARK: - 4. Warm→cold abandonment path

    @Test("A warm patch that resolves to a root-level rescan abandons cleanly into a coherent cold fallback")
    func warmToColdAbandonment() async throws {
        try await withTemporaryAppSupportDir {
            try await self.warmToColdAbandonmentBody()
        }
    }

    @MainActor
    private func warmToColdAbandonmentBody() async throws {
        var layout: [String: UInt64] = ["docs/readme.txt": 100]
        // Padding directories: the planner's threshold is a percentage of the cached
        // tree's directory count (WarmStartTests' `manyRawEventsCollapsingToFewRootsWarms`
        // uses the same trick) — without these, one changed root out of ~2 cached
        // directories reads as 50% churn and correctly falls back to cold on its own,
        // never reaching the mid-patch abandonment branch this test exists to exercise.
        for i in 0..<40 {
            layout["pad\(i)/file.txt"] = 10
        }
        let (rawRoot, cleanup) = try createTempTree(layout)
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        try await settleFSEventsJournal()  // let the fixture's own creation land first

        let savedEventId = FSEventsJournal.currentEventId()
        let tree = await scanFixture(at: root)
        try TreeCache.save(tree: tree, lastEventId: savedEventId)

        // A brand-new TOP-LEVEL directory: `resolveRescanTarget`'s ancestor walk-up finds
        // nothing narrower than the tree root resolves for it (it isn't in the cached
        // tree, and neither is any ancestor of it besides root itself) — so the rescan
        // target collapses to the root, `rescannedRoots.contains(path)` is true, and
        // `commitWarmStart` abandons the patch for a cold fallback (028/040's documented
        // "prefer a full rescan over patching the whole tree through the splice path it
        // wasn't designed to replace wholesale" rule).
        let newDir = URL(fileURLWithPath: root).appendingPathComponent("brandnew")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data(count: 77).write(to: newDir.appendingPathComponent("f.txt"))
        try await settleFSEventsJournal()

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(root, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        state.restoreOnLaunch()

        await waitUntil(timeout: 20) { !state.scanProgress.isScanning && state.staleViewAsOf == nil }

        #expect(!state.scanProgress.isScanning)
        #expect(state.staleViewAsOf == nil)
        guard let finalTree = state.fileTree else {
            Issue.record("expected a tree after the warm→cold fallback settled")
            return
        }
        // Prove the cold fallback actually ran to completion (not just an early abandon
        // with a stale/partial tree left behind): the brand-new directory is reflected.
        #expect(nodeIndex(in: finalTree, pathSuffix: "/brandnew/f.txt") != nil,
            "expected the fallback cold scan to have picked up the new top-level directory")
    }

    // MARK: - 5. Every flow's scanner is cancellable

    @Test("cancelActiveScan actually stops the running scanner — no scan work keeps going in the background")
    func everyFlowScannerIsCancellable() async throws {
        try await withTemporaryAppSupportDir {
            try await self.everyFlowScannerIsCancellableBody()
        }
    }

    @MainActor
    private func everyFlowScannerIsCancellableBody() async throws {
        let (path, cleanup) = try createTempTree(manyFilesLayout())
        defer { cleanup() }

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.selectedVolume = URL(fileURLWithPath: path)

        state.startFullRescan()  // cold, non-preserving — registers its scanner via markStarted
        await waitUntil(timeout: 2, pollInterval: .milliseconds(1)) { state.scanProgress.isScanning }

        state.cancelScan()
        await waitUntil(timeout: 20) { !state.scanProgress.isScanning }

        // Not just momentarily quiet: no scan thread should still be updating counters
        // in the background after cancellation has settled.
        let filesAfterCancel = state.scanProgress.filesScanned
        try await Task.sleep(for: .milliseconds(300))
        #expect(state.scanProgress.filesScanned == filesAfterCancel,
            "no scan work should still be in flight after cancelActiveScan")
    }

    // MARK: - 6. Replay-wait is visible

    @Test("Starting a warm-eligible scan immediately publishes a visible 'checking changes' state, before the journal replay even begins")
    func replayWaitIsVisible() async throws {
        try await withTemporaryAppSupportDir {
            try await self.replayWaitIsVisibleBody()
        }
    }

    @MainActor
    private func replayWaitIsVisibleBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)
        try TreeCache.save(tree: tree, lastEventId: FSEventsJournal.currentEventId())

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.selectedVolume = URL(fileURLWithPath: path)

        state.startSelectedVolumeScan()

        // Immediately after the call returns — before the async journal replay has even
        // started — the sidebar must already show a live, honest "checking" state
        // instead of nothing (the user's "clicked Scan Volume → visibly nothing"
        // complaint).
        #expect(state.scanProgress.isScanning)
        #expect(state.isPreparingScan)
        #expect(state.scanProgress.currentPath.localizedCaseInsensitiveContains("checking"),
            "expected a 'checking what changed' style status, got \"\(state.scanProgress.currentPath)\"")

        await waitUntil(timeout: 20) { !state.scanProgress.isScanning }
        #expect(!state.scanProgress.isScanning)
    }

    // MARK: - 7. A warm patch is cancellable/supersedable mid-flight (plan 042)

    /// The patch phase used to be a single-threaded loop that ran synchronously on the
    /// caller (effectively blocking the UI for however long it took); plan 042 reworked it
    /// into parallel-enumerate/serial-apply. This proves the rework kept (and, per the
    /// 040-flagged nit fixed in 042, actually FIXED) real cancellation: clicking away
    /// mid-patch must stop actual work, not just eventually settle on its own.
    @Test("A warm patch can be cancelled mid-flight — no patch work keeps going in the background afterward")
    func warmPatchIsCancellableMidFlight() async throws {
        try await withTemporaryAppSupportDir {
            try await self.warmPatchIsCancellableMidFlightBody()
        }
    }

    @MainActor
    private func warmPatchIsCancellableMidFlightBody() async throws {
        var layout: [String: UInt64] = [:]
        // Padding: keeps both the root-count AND cost-based (item-fraction) warm-start
        // thresholds comfortably satisfied despite changing 50 real directories below —
        // same trick `warmToColdAbandonmentBody`/`composedWarmStartMatchesColdScan` use.
        for i in 0..<300 {
            layout["pad\(i)/seed.txt"] = 1
        }
        // 50 real changed roots, each starting tiny in the CACHED tree — the warm-start
        // decision judges the changed set by this small cached size (exactly like the
        // reported incident: the decision can't know ahead of time how much new content
        // a root is about to gain on disk), so it still warms even though the mutation
        // below gives Phase A/B real work to do.
        for i in 0..<50 {
            layout["churn\(i)/seed.txt"] = 1
        }
        let (rawRoot, cleanup) = try createTempTree(layout)
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        try await settleFSEventsJournal()

        let savedEventId = FSEventsJournal.currentEventId()
        let tree = await scanFixture(at: root)
        try TreeCache.save(tree: tree, lastEventId: savedEventId)

        // Grow each churn directory substantially — real work for the parallel patch to
        // chew through, even though the warm decision (based on the cache above) sees
        // only a small fraction of the tree as changed.
        for i in 0..<50 {
            let dirURL = URL(fileURLWithPath: root).appendingPathComponent("churn\(i)")
            for f in 0..<100 {
                try Data(count: f + 1).write(to: dirURL.appendingPathComponent("new\(f).dat"))
            }
        }
        try await settleFSEventsJournal()

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(root, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        state.selectedVolume = URL(fileURLWithPath: root)

        state.startSelectedVolumeScan()
        // Wait past the "preparing"/replay-wait sub-state into the actual patch, where
        // `commitWarmStart` has registered its scanner via `markStarted`.
        await waitUntil(timeout: 10, pollInterval: .milliseconds(1)) {
            state.scanProgress.isScanning && !state.isPreparingScan
        }

        state.cancelScan()
        await waitUntil(timeout: 20) { !state.scanProgress.isScanning }

        #expect(!state.scanProgress.isScanning)

        // Not just momentarily quiet: no patch work should still be updating counters in
        // the background after cancellation has settled.
        let filesAfterCancel = state.scanProgress.filesScanned
        try await Task.sleep(for: .milliseconds(300))
        #expect(state.scanProgress.filesScanned == filesAfterCancel,
            "no patch work should still be in flight after cancelActiveScan")

        // The tree must remain usable regardless of how much of the patch got applied.
        #expect(state.fileTree != nil)
        #expect((state.fileTree?.count ?? 0) > 0)
    }
}

} // extension AppSupportEnvSuites

// MARK: - Apply-changes / scan gating symmetry (no App Support I/O — pure state)

@Suite("Scan / Apply-Changes Gating Symmetry Tests")
struct ScanApplyGatingSymmetryTests {
    @MainActor
    @Test("A scan cannot start while applyAccumulatedChanges is running — symmetric with canStartHeavyTask refusing to start apply during a scan")
    func scanBlockedWhileApplyingChanges() {
        let state = AppState()
        state.fileTree = FileTree()
        state.selectedVolume = URL(fileURLWithPath: "/tmp")
        state.isApplyingChanges = true

        let progressBefore = state.scanProgress
        state.startSelectedVolumeScan()

        #expect(state.scanProgress === progressBefore, "starting a scan while applying changes must be a complete no-op")
        #expect(!state.scanProgress.isScanning)
    }
}
