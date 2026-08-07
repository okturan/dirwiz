import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Coverage for plan 040: the scan-flow supervision invariant documented on
/// `AppState.startScan` (`AppState+Scan.swift`) - after any scan flow exits by ANY path,
/// either a newer flow has already published its own fresh `ScanProgress`, or the
/// currently-published one is honestly terminal (`isScanning == false`). Wave 7's flows
/// (launch auto-refresh, warm patch, preserving-cold, replay-wait windows) introduced exit
/// paths that could leave the *displayed* `ScanProgress` frozen mid-scan; this suite pins
/// the reproduction of that incident plus the supervisor's other guarantees.
///
/// Nested under `AppSupportEnvSuites` (TestHelpers.swift) and wrapped in
/// `withTemporaryAppSupportDir` throughout: every test here drives `restoreOnLaunch` /
/// `startFullRescan` to completion, and a completed cold scan's deferred bundle sizing
/// always ends with a `TreeCache.save` - both read `DIRWIZ_APP_SUPPORT_DIR`.
extension AppSupportEnvSuites {

@Suite("Scan Supervision Tests")
struct ScanSupervisionTests {

    private static let layout: [String: UInt64] = [
        "docs/readme.txt": 100,
        "docs/notes.md": 200,
        "images/photo.jpg": 500,
    ]

    private static let lastScannedVolumePathKey = "lastScannedVolumePath"

    /// Real filesystem wrapper that pauses one warm-patch Phase A enumeration. The tests
    /// no longer need thousands of files merely to create a pollable timing window.
    private final class GatedFilesystemProvider: @unchecked Sendable, FilesystemProvider {
        private let inner = RealFilesystemProvider()
        private let gatedPath: String
        private let releaseGate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reachedGate = false

        init(gatedPath: String) {
            self.gatedPath = gatedPath
        }

        var didReachGate: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachedGate
        }

        func release() {
            releaseGate.signal()
        }

        func listDirectory(path: String) -> [DirectoryEntry]? {
            inner.listDirectory(path: path)
        }

        func forEachDirectoryEntry(
            path: String,
            _ body: (DirectoryEntry) -> Bool
        ) -> Bool {
            if path == gatedPath {
                lock.lock()
                reachedGate = true
                lock.unlock()
                releaseGate.wait()
            }
            return inner.forEachDirectoryEntry(path: path, body)
        }

        func computeBundleSize(
            path: String,
            isCancelled: () -> Bool
        ) -> (fileSize: UInt64, allocatedSize: UInt64) {
            inner.computeBundleSize(path: path, isCancelled: isCancelled)
        }

        func deviceAndInode(
            forPath path: String
        ) -> (device: Int32, inode: UInt64)? {
            inner.deviceAndInode(forPath: path)
        }

        func volumeStats(forPath path: String) -> StatfsResult? {
            inner.volumeStats(forPath: path)
        }
    }

    private func makeEphemeralDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// Polls `condition` on the main actor until it's true or `timeout` elapses - mirrors
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

    /// Snapshot the evidence requested by scan-supervision-flake task 1.2 at the exact
    /// assertion boundary. This is diagnostic text only; it does not wait for or mutate
    /// any state and therefore cannot turn a red run green.
    @MainActor
    private func supervisionDiagnostics(
        state: AppState,
        root: String,
        preflightJournal: JournalChangeWaitResult
    ) -> String {
        let trace = state.scanSupervisionTrace
        let historyDescription: String
        if let history = WarmStartHistory.load(for: root).last {
            historyDescription = history.wasWarm
                ? "warm"
                : "cold(reason=\(history.reason ?? "nil"))"
        } else {
            historyDescription = "none"
        }
        return [
            "preflight=[\(preflightJournal)]",
            "app_replay=\(trace.journalReplayOutcome)",
            "planner=\(trace.plannerDecision)",
            "abandonment=\(trace.abandonmentReason ?? "nil")",
            "cold_fallback=\(trace.coldFallbackReason ?? "nil")",
            "progress={path=\(String(reflecting: state.scanProgress.currentPath)), scanning=\(state.scanProgress.isScanning), complete=\(state.scanProgress.scanComplete), cancelled=\(state.scanProgress.isCancelled), preparing=\(state.isPreparingScan)}",
            "stale=\(state.staleViewAsOf != nil)",
            "hardlinks={groups=\(state.hardlink.hardlinkGroups.count), running=\(state.hardlink.isHardlinkScanRunning)}",
            "summary=\(state.lastScanSummary ?? "nil")",
            "history=\(historyDescription)",
        ].joined(separator: "; ")
    }

    /// A large-ish real fixture, big enough that a real on-disk scan is still running a
    /// few milliseconds in - same trick `LaunchRestoreTests.cancellingColdRefreshBehindStaleKeepsStaleViewBody`
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
    /// are the same string - same helper as `WarmStartTests`, duplicated per this repo's
    /// per-suite convention.
    private func realDirectoryPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The FSEvents daemon journals asynchronously; give it a moment to catch up before
    /// treating "now" as a clean boundary - same helper as `WarmStartTests`.
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
        // Rescan" - both landing before the auto-refresh's (or the first click's) own
        // replay-wait has resolved. Calling both synchronously back-to-back, with no
        // `await` in between, guarantees this: `startScan` only ever suspends inside a
        // `Task` it launches and returns immediately, so nothing here has had a chance
        // to progress before the next call lands.
        state.startSelectedVolumeScan()
        state.startFullRescan()

        await waitUntil(timeout: 20) { !state.scanProgress.isScanning }

        // INVARIANT: however many superseding clicks landed mid-flight, the final
        // displayed state must be terminal - never frozen mid-scan (the incident).
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

    @Test("A warm patch that resolves to a root-level addition stays warm")
    func warmToColdAbandonment() async throws {
        try await withTemporaryAppSupportDir {
            try await self.warmToColdAbandonmentBody()
        }
    }

    @MainActor
    private func warmToColdAbandonmentBody() async throws {
        var layout: [String: UInt64] = ["docs/readme.txt": 100]
        // Padding keeps a single added root well under the item-fraction gate so the
        // selective root-level reconcile is what actually runs.
        for i in 0..<150 {
            layout["pad\(i)/file.txt"] = 10
        }
        let (rawRoot, cleanup) = try createTempTree(layout)
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)

        let savedEventId = FSEventsJournal.currentEventId()
        let tree = await scanFixture(at: root)
        try TreeCache.save(tree: tree, lastEventId: savedEventId)

        // A brand-new TOP-LEVEL directory used to collapse to a root-level deep rescan
        // and force cold fallback. Selective-child-rescan level-diffs the root and only
        // enumerates the addition - so the patch stays warm.
        let newDir = URL(fileURLWithPath: root).appendingPathComponent("brandnew")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try Data(count: 77).write(to: newDir.appendingPathComponent("f.txt"))

        let injectedReplay = JournalReplay(
            outcome: .changes([newDir.path]),
            newEventId: FSEventsJournal.currentEventId()
        )
        let journalWait = JournalChangeWaitResult(
            outcome: .changes([newDir.path]),
            attempts: 0,
            elapsedMilliseconds: 0
        )

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(root, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(
            defaults: defaults,
            warmStartJournalReplay: { _, _ in injectedReplay }
        )
        state.restoreOnLaunch()

        await waitUntil(timeout: 20) { !state.scanProgress.isScanning && state.staleViewAsOf == nil }

        #expect(
            !state.scanProgress.isScanning,
            "\(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )
        #expect(
            state.staleViewAsOf == nil,
            "\(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )
        guard let finalTree = state.fileTree else {
            Issue.record("expected a tree after the warm root-level patch settled")
            return
        }
        #expect(
            nodeIndex(in: finalTree, pathSuffix: "/brandnew/f.txt") != nil,
            "expected the warm root-level level-diff to install the new directory; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )
        #expect(
            state.lastScanSummary?.contains("Refreshed") == true,
            "root-level selective reconcile must stay warm; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )
        #expect(
            WarmStartHistory.load(for: root).last?.wasWarm == true,
            "WarmStartHistory must record warm for a root-level selective addition"
        )
    }

    @Test("A poisoned journal falls back cold with the exact recorded reason")
    func poisonedJournalFallsBackCoherently() async throws {
        try await withTemporaryAppSupportDir {
            try await self.poisonedJournalFallsBackCoherentlyBody()
        }
    }

    @MainActor
    private func poisonedJournalFallsBackCoherentlyBody() async throws {
        let (rawRoot, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let tree = await scanFixture(at: root)
        try TreeCache.save(
            tree: tree,
            lastEventId: FSEventsJournal.currentEventId()
        )

        let poisonedReplay = JournalReplay(
            outcome: .poisoned("MustScanSubDirs"),
            newEventId: FSEventsJournal.currentEventId()
        )
        let journalEvidence = JournalChangeWaitResult(
            outcome: .poisoned("MustScanSubDirs"),
            attempts: 0,
            elapsedMilliseconds: 0
        )
        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(
            defaults: defaults,
            warmStartJournalReplay: { _, _ in poisonedReplay }
        )
        state.selectedVolume = URL(fileURLWithPath: root)
        state.startSelectedVolumeScan()

        await waitUntil(timeout: 20) {
            state.scanProgress.scanComplete && !state.isBundleSizingRunning
        }

        let diagnostics = supervisionDiagnostics(
            state: state,
            root: root,
            preflightJournal: journalEvidence
        )
        #expect(state.fileTree != nil, "\(diagnostics)")
        #expect(
            state.lastScanSummary?.contains("change journal unavailable") == true,
            "\(diagnostics)"
        )
        let history = try #require(WarmStartHistory.load(for: root).last)
        #expect(!history.wasWarm, "\(diagnostics)")
        #expect(history.reason == "change journal unavailable", "\(diagnostics)")
        #expect(
            state.scanSupervisionTrace.journalReplayOutcome
                == "poisoned: MustScanSubDirs",
            "\(diagnostics)"
        )
    }

    @Test("A cache that fails to load surfaces why, distinct from no cache ever existing")
    func rejectedCacheSurfacesReason() async throws {
        try await withTemporaryAppSupportDir {
            try await self.rejectedCacheSurfacesReasonBody()
        }
    }

    @MainActor
    private func rejectedCacheSurfacesReasonBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)
        try TreeCache.save(tree: tree, lastEventId: FSEventsJournal.currentEventId())

        // Truncate the saved cache - same structural-corruption shape
        // `TreeCacheTests.truncatedFileFailsClosed` pins at the `TreeCache` level; here
        // the same fixture is driven through the full `AppState` scan flow to prove the
        // reason reaches `lastScanSummary`, not just `TreeCache.loadResult` in isolation.
        let url = TreeCache.cacheURL(for: path)
        var data = try Data(contentsOf: url)
        #expect(data.count > 100, "Fixture cache should be large enough to chop 100 bytes")
        data.removeLast(100)
        try data.write(to: url)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.selectedVolume = URL(fileURLWithPath: path)

        state.startSelectedVolumeScan()
        await waitUntil(timeout: 20) { state.scanProgress.scanComplete }

        #expect(!state.scanProgress.isScanning)
        #expect(
            state.lastScanSummary?.contains("cache file was incomplete") == true,
            "expected the rejected-cache reason in the summary, got \(state.lastScanSummary ?? "nil")"
        )
    }

    @Test("A volume with no cache at all reads as a first scan, not a rejected one")
    func noCacheAtAllReadsAsFirstScan() async throws {
        try await withTemporaryAppSupportDir {
            try await self.noCacheAtAllReadsAsFirstScanBody()
        }
    }

    @MainActor
    private func noCacheAtAllReadsAsFirstScanBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.selectedVolume = URL(fileURLWithPath: path)

        state.startSelectedVolumeScan()
        await waitUntil(timeout: 20) { state.scanProgress.scanComplete }

        #expect(!state.scanProgress.isScanning)
        #expect(state.lastScanSummary?.hasPrefix("Scanned") == true)
        // `ScanSummaryComposer.coldWithReason`'s literal separator - its absence proves
        // no reason was attached, i.e. this reads as a first scan, not a rejected cache.
        #expect(
            state.lastScanSummary?.contains(" - full scan: ") != true,
            "a first-ever scan must not read as a rejected-cache explanation, got \(state.lastScanSummary ?? "nil")"
        )
    }

    @Test("ultrareview bug_002: a warm patch behind a stale view never shows a misleading 'No Hardlinks Found' - populated groups stay populated (or visibly recomputing) the whole time")
    func warmPatchNeverShowsFalseEmptyHardlinks() async throws {
        try await withTemporaryAppSupportDir {
            try await self.warmPatchNeverShowsFalseEmptyHardlinksBody()
        }
    }

    /// `commitWarmStart` used to call the shared `resetForNewScan()` unconditionally,
    /// even in the preserving-stale-view branch - synchronously clearing
    /// `hardlink.hardlinkGroups` and `isHardlinkScanRunning` while the stale tree stayed
    /// fully on screen. `HardlinkView`'s empty state reads "No files on this volume
    /// share an inode" - a definitive claim - for however long the subsequent
    /// `await scanner.rescanSubtrees(...)` takes. The fix calls `refreshHardlinkGroups()`
    /// again immediately (same synchronous scope, no `await` in between), which flips
    /// `isHardlinkScanRunning` true before any observer - including this test's polling
    /// loop - can get scheduled, so the bad `(empty && !running)` combination is not
    /// just rare but structurally unreachable. This test polls continuously through the
    /// whole patch window and fails immediately if that combination is ever observed,
    /// rather than sampling once and hoping to get lucky/unlucky.
    @MainActor
    private func warmPatchNeverShowsFalseEmptyHardlinksBody() async throws {
        var layout: [String: UInt64] = [:]
        // Padding keeps the cached estimate warm-eligible. Two new files per churn root
        // keep the exact staged count under the existing 25% guard; a filesystem gate,
        // not thousands of files or scheduler luck, creates the observation window.
        for i in 0..<300 {
            layout["pad\(i)/seed.txt"] = 1
        }
        for i in 0..<40 {
            layout["churn\(i)/seed.txt"] = 1
        }
        let (rawRoot, cleanup) = try createTempTree(layout)
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)

        // A hardlinked pair so hardlinkGroups is non-empty after the first scan -
        // otherwise "stays empty" and "wrongly cleared" are indistinguishable.
        let original = URL(fileURLWithPath: root).appendingPathComponent("pad0/original.txt")
        try Data(repeating: 0xAB, count: 256).write(to: original)
        let link = URL(fileURLWithPath: root).appendingPathComponent("pad0/hardlink.txt")
        try FileManager.default.linkItem(at: original, to: link)

        let savedEventId = FSEventsJournal.currentEventId()
        let tree = await scanFixture(at: root)
        #expect(tree.linkCountsCaptured)
        try TreeCache.save(tree: tree, lastEventId: savedEventId)

        let changedRoots = (0..<40).map { root + "/churn\($0)" }
        for i in 0..<40 {
            let dirURL = URL(fileURLWithPath: root).appendingPathComponent("churn\(i)")
            for f in 0..<2 {
                try Data(count: f + 1).write(to: dirURL.appendingPathComponent("new\(f).dat"))
            }
        }
        let injectedReplay = JournalReplay(
            outcome: .changes(changedRoots),
            newEventId: FSEventsJournal.currentEventId()
        )
        let journalWait = JournalChangeWaitResult(
            outcome: .changes(changedRoots),
            attempts: 0,
            elapsedMilliseconds: 0
        )

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(root, forKey: Self.lastScannedVolumePathKey)

        let phaseAGate = GatedFilesystemProvider(gatedPath: changedRoots[0])
        defer { phaseAGate.release() }
        let state = AppState(
            defaults: defaults,
            warmPatchScannerFactory: {
                FileScanner(filesystem: phaseAGate)
            },
            warmStartJournalReplay: { _, _ in injectedReplay }
        )
        state.restoreOnLaunch()

        // restoreOnLaunch's own post-restore refreshHardlinkGroups() call needs a beat
        // to complete before the (fast, in-memory) hardlink group is actually populated.
        await waitUntil(timeout: 5) { !state.hardlink.hardlinkGroups.isEmpty }
        #expect(
            state.hardlink.hardlinkGroups.count == 1,
            "fixture must have exactly the one seeded hardlink group before the patch begins; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )

        await waitUntil(timeout: 10, pollInterval: .milliseconds(1)) {
            phaseAGate.didReachGate
        }
        #expect(phaseAGate.didReachGate, "warm patch never reached the deterministic Phase A gate")

        // Confirm this is actually exercising a WARM patch, not a cold fallback that
        // would make the rest of this test pass for the wrong reason.
        #expect(state.scanProgress.currentPath.contains("last scan")
            || state.scanProgress.currentPath.contains("changed folders"),
            "expected a warm-patch-specific status; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))")

        #expect(
            !(state.hardlink.hardlinkGroups.isEmpty && !state.hardlink.isHardlinkScanRunning),
            "hardlinkGroups read (empty && not running) right at patch entry - the exact bug_002 window; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )

        // Keep watching through the remainder of the (real, churn-sized) patch - belt
        // and suspenders alongside the entry-point checkpoint above.
        var observedFalseEmpty = false
        phaseAGate.release()
        while state.scanProgress.isScanning {
            if state.hardlink.hardlinkGroups.isEmpty && !state.hardlink.isHardlinkScanRunning {
                observedFalseEmpty = true
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(!observedFalseEmpty,
            "hardlinkGroups must never read (empty && not running) while a warm patch is in flight behind a stale view; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))")
        #expect(!state.scanProgress.isScanning)
        await waitUntil(timeout: 5) { !state.hardlink.isHardlinkScanRunning }
        #expect(
            state.hardlink.hardlinkGroups.count == 1,
            "the group must still be present after the patch settles; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )
    }

    // MARK: - 5. Every flow's scanner is cancellable

    @Test("cancelActiveScan actually stops the running scanner - no scan work keeps going in the background")
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

        state.startFullRescan()  // cold, non-preserving - registers its scanner via markStarted
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

        // Immediately after the call returns - before the async journal replay has even
        // started - the sidebar must already show a live, honest "checking" state
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
    @Test("A warm patch can be cancelled mid-flight - no patch work keeps going in the background afterward")
    func warmPatchIsCancellableMidFlight() async throws {
        try await withTemporaryAppSupportDir {
            try await self.warmPatchIsCancellableMidFlightBody()
        }
    }

    @MainActor
    private func warmPatchIsCancellableMidFlightBody() async throws {
        var layout: [String: UInt64] = [:]
        // Padding keeps the directory- and item-fraction warm-start thresholds
        // comfortably satisfied despite changing 40 real directories below - same trick
        // `warmToColdAbandonmentBody`/`composedWarmStartMatchesColdScan` use.
        for i in 0..<300 {
            layout["pad\(i)/seed.txt"] = 1
        }
        // Forty real changed roots, far below the 512-root pathological backstop. The
        // deterministic filesystem gate below supplies the cancellable window, so this
        // fixture can remain below the staged-item guard instead of manufacturing load.
        for i in 0..<40 {
            layout["churn\(i)/seed.txt"] = 1
        }
        let (rawRoot, cleanup) = try createTempTree(layout)
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)

        let savedEventId = FSEventsJournal.currentEventId()
        let tree = await scanFixture(at: root)
        try TreeCache.save(tree: tree, lastEventId: savedEventId)

        let changedRoots = (0..<40).map { root + "/churn\($0)" }
        for i in 0..<40 {
            let dirURL = URL(fileURLWithPath: root).appendingPathComponent("churn\(i)")
            for f in 0..<2 {
                try Data(count: f + 1).write(to: dirURL.appendingPathComponent("new\(f).dat"))
            }
        }
        let injectedReplay = JournalReplay(
            outcome: .changes(changedRoots),
            newEventId: FSEventsJournal.currentEventId()
        )
        let journalWait = JournalChangeWaitResult(
            outcome: .changes(changedRoots),
            attempts: 0,
            elapsedMilliseconds: 0
        )

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(root, forKey: Self.lastScannedVolumePathKey)

        let phaseAGate = GatedFilesystemProvider(gatedPath: changedRoots[0])
        defer { phaseAGate.release() }
        let state = AppState(
            defaults: defaults,
            warmPatchScannerFactory: {
                FileScanner(filesystem: phaseAGate)
            },
            warmStartJournalReplay: { _, _ in injectedReplay }
        )
        state.selectedVolume = URL(fileURLWithPath: root)

        state.startSelectedVolumeScan()
        await waitUntil(timeout: 10, pollInterval: .milliseconds(1)) {
            phaseAGate.didReachGate
        }
        #expect(phaseAGate.didReachGate, "warm patch never reached the deterministic Phase A gate")

        // Confirm this is actually exercising a WARM patch, not a cold fallback that
        // would make the rest of this test pass for the wrong reason (a real risk: any
        // planner gate could silently push this fixture to cold, and every assertion
        // below is generic enough to pass either way). `commitWarmStart` sets this text
        // synchronously right after registering
        // its scanner, before any Phase A work begins; cold's `beginColdScan` never does.
        #expect(state.scanProgress.currentPath.contains("last scan")
            || state.scanProgress.currentPath.contains("changed folders"),
            "expected a warm-patch-specific status; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))")

        state.cancelScan()
        phaseAGate.release()
        await waitUntil(timeout: 20) { !state.scanProgress.isScanning }

        #expect(!state.scanProgress.isScanning)
        #expect(
            state.scanProgress.isCancelled,
            "a user cancellation must remain cancellation, never turn into a cold fallback; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )
        #expect(
            WarmStartHistory.load(for: root).isEmpty,
            "cancelling a warm patch must not record a cold-fallback decision; \(supervisionDiagnostics(state: state, root: root, preflightJournal: journalWait))"
        )

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

// MARK: - Apply-changes / scan gating symmetry (no App Support I/O - pure state)

@Suite("Scan / Apply-Changes Gating Symmetry Tests")
struct ScanApplyGatingSymmetryTests {
    @MainActor
    @Test("A scan cannot start while applyAccumulatedChanges is running - symmetric with canStartHeavyTask refusing to start apply during a scan")
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
