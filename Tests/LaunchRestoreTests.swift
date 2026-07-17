import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Coverage for plan 036: launch-time auto-restore of the last scanned volume's cached
/// tree, and the "refresh behind a stale view" rework that lets a background warm patch
/// or cold rescan freshen an already-displayed restored tree without blanking it.
///
/// Nested under `AppSupportEnvSuites` (TestHelpers.swift) and wrapped in
/// `withTemporaryAppSupportDir` throughout: every test here either calls `TreeCache.load`
/// directly or drives a real scan to completion, and a completed scan's deferred bundle
/// sizing always ends with a `TreeCache.save` — both read `DIRWIZ_APP_SUPPORT_DIR`, so
/// leaving it unset would touch the real `~/Library/Application Support/DirWiz` directory.
///
/// Each `@Test` is a plain (non-isolated) `async` function that just forwards into
/// `withTemporaryAppSupportDir`; the actual `AppState`-touching body is a `@MainActor`
/// method instead. `withTemporaryAppSupportDir` is an ordinary global `async` function
/// (not `@MainActor`), so under Swift 6 strict concurrency a MainActor-isolated closure
/// can't be handed to it directly — splitting "isolated body" from "env-var wrapper"
/// sidesteps that without weakening either.
extension AppSupportEnvSuites {

@Suite("Launch Restore Tests")
struct LaunchRestoreTests {

    private static let layout: [String: UInt64] = [
        "docs/readme.txt": 100,
        "docs/notes.md": 200,
        "images/photo.jpg": 500,
    ]

    private static let lastScannedVolumePathKey = "lastScannedVolumePath"

    /// A fresh, isolated `UserDefaults` suite per test, so `lastScannedVolumePath`
    /// round-trips never touch the real `UserDefaults.standard` or leak between tests.
    private func makeEphemeralDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// Polls `condition` on the main actor until it's true or `timeout` elapses — the
    /// public scan entry points (`startSelectedVolumeScan`, `startFullRescan`,
    /// `restoreOnLaunch`'s auto-refresh) all dispatch an internal `Task` and return
    /// immediately, so tests need to wait for that background work to settle.
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

    /// Index of the node whose path ends with `suffix` (e.g. "/docs" or "/docs/notes.md").
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

    // MARK: - restoreOnLaunch gates

    @Test("No lastScannedVolumePath in defaults: restoreOnLaunch is a no-op")
    func noDefaultsKeyIsNoOp() async {
        await withTemporaryAppSupportDir {
            await self.noDefaultsKeyIsNoOpBody()
        }
    }

    @MainActor
    private func noDefaultsKeyIsNoOpBody() async {
        let (defaults, cleanup) = makeEphemeralDefaults()
        defer { cleanup() }

        let state = AppState(defaults: defaults)
        state.restoreOnLaunch()

        #expect(state.fileTree == nil)
        #expect(state.staleViewAsOf == nil)
        #expect(state.selectedVolume == nil)
    }

    @Test("lastScannedVolumePath points at a path that no longer exists: restoreOnLaunch is a no-op")
    func missingPathIsNoOp() async {
        await withTemporaryAppSupportDir {
            await self.missingPathIsNoOpBody()
        }
    }

    @MainActor
    private func missingPathIsNoOpBody() async {
        let (defaults, cleanup) = makeEphemeralDefaults()
        defer { cleanup() }
        defaults.set("/no/such/path/at/all-\(UUID())", forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        state.restoreOnLaunch()

        #expect(state.fileTree == nil)
        #expect(state.staleViewAsOf == nil)
    }

    @Test("A remembered path with no cache on disk: restoreOnLaunch is a no-op")
    func noCacheIsNoOp() async throws {
        try await withTemporaryAppSupportDir {
            try await self.noCacheIsNoOpBody()
        }
    }

    @MainActor
    private func noCacheIsNoOpBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(path, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        state.restoreOnLaunch()

        #expect(state.fileTree == nil)
        #expect(state.staleViewAsOf == nil)
    }

    @Test("DIRWIZ_NO_WARM_START kill switch disables restore even with a valid cache")
    func envKillSwitchDisablesRestore() async throws {
        try await withTemporaryAppSupportDir {
            try await self.envKillSwitchDisablesRestoreBody()
        }
    }

    @MainActor
    private func envKillSwitchDisablesRestoreBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)
        try TreeCache.save(tree: tree, lastEventId: FSEventsJournal.currentEventId())

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(path, forKey: Self.lastScannedVolumePathKey)

        setenv("DIRWIZ_NO_WARM_START", "1", 1)
        defer { unsetenv("DIRWIZ_NO_WARM_START") }

        let state = AppState(defaults: defaults)
        state.restoreOnLaunch()

        #expect(state.fileTree == nil)
        #expect(state.staleViewAsOf == nil)
    }

    // MARK: - Successful restore + auto-refresh sequence

    @Test("Fresh launch with a prior scan: tree restored from cache and badge set immediately, then auto-refresh completes and clears staleness")
    func restoreThenAutoRefreshCompletes() async throws {
        try await withTemporaryAppSupportDir {
            try await self.restoreThenAutoRefreshCompletesBody()
        }
    }

    @MainActor
    private func restoreThenAutoRefreshCompletesBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)
        try TreeCache.save(tree: tree, lastEventId: FSEventsJournal.currentEventId())
        let scannedCount = tree.count

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(path, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        state.restoreOnLaunch()

        // Immediately after restoreOnLaunch: tree visible from cache, badge active,
        // volume selected — all before any enumeration has happened.
        #expect(state.fileTree != nil)
        #expect(state.fileTree?.count == scannedCount)
        #expect(state.staleViewAsOf != nil)
        #expect(state.staleBadgeText?.hasPrefix("Showing last scan") == true)
        #expect(state.selectedVolume?.path == path)

        // The auto-refresh runs in the background; wait for it to settle.
        await waitUntil { state.staleViewAsOf == nil && !state.scanProgress.isScanning }

        #expect(state.staleViewAsOf == nil, "staleViewAsOf should clear once the auto-refresh completes")
        #expect(state.staleBadgeText == nil)
        #expect(state.fileTree != nil)
        #expect(defaults.string(forKey: Self.lastScannedVolumePathKey) == path)
    }

    @Test("restoreOnLaunch is a no-op if a tree is already displayed (guards a duplicate call)")
    func restoreOnLaunchNoOpsWhenTreeAlreadyDisplayed() async throws {
        try await withTemporaryAppSupportDir {
            try await self.restoreOnLaunchNoOpsWhenTreeAlreadyDisplayedBody()
        }
    }

    @MainActor
    private func restoreOnLaunchNoOpsWhenTreeAlreadyDisplayedBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)
        try TreeCache.save(tree: tree, lastEventId: FSEventsJournal.currentEventId())

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(path, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        let sentinelTree = FileTree()
        state.fileTree = sentinelTree

        state.restoreOnLaunch()

        #expect(state.fileTree === sentinelTree)
        #expect(state.staleViewAsOf == nil)
    }

    // MARK: - Cold-refresh-behind-stale preserves selection/root

    @Test("A forced cold refresh behind a stale view preserves selection and treemap root, and clears staleViewAsOf on completion")
    func coldRefreshBehindStalePreservesExploration() async throws {
        try await withTemporaryAppSupportDir {
            try await self.coldRefreshBehindStalePreservesExplorationBody()
        }
    }

    @MainActor
    private func coldRefreshBehindStalePreservesExplorationBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }

        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        state.staleViewAsOf = Date(timeIntervalSinceNow: -3600)

        guard let notesIndex = nodeIndex(in: tree, pathSuffix: "/docs/notes.md"),
              let docsIndex = nodeIndex(in: tree, pathSuffix: "/docs") else {
            Issue.record("Expected docs/notes.md and docs in the scanned tree")
            return
        }
        let notesPath = tree.path(at: notesIndex)
        let docsPath = tree.path(at: docsIndex)
        state.selectedNodeIndex = notesIndex
        state.setTreemapRoot(docsIndex, recordHistory: false)

        // Mutate the fixture on disk before the (forced-cold) refresh runs.
        try Data(count: 999).write(to: URL(fileURLWithPath: path).appendingPathComponent("docs/added.txt"))

        state.startFullRescan()

        // While the background cold scan runs, the stale view must remain untouched
        // and browsable — same tree object, same selection, badge still up.
        #expect(state.staleViewAsOf != nil)
        #expect(state.fileTree === tree)
        #expect(state.selectedNodeIndex == notesIndex)

        // `!isScanning` alone is ambiguous here — it's equally true before the background
        // Task has even started as it is once the scan completes — so wait on
        // `staleViewAsOf` clearing instead, which only happens once the real completion
        // swap runs.
        await waitUntil { state.staleViewAsOf == nil }

        #expect(!state.scanProgress.isScanning)
        guard let newTree = state.fileTree else {
            Issue.record("Expected a swapped-in fileTree after the cold refresh")
            return
        }
        #expect(newTree !== tree, "fileTree should have been swapped to the newly scanned tree")

        let restoredSelection = try #require(state.selectedNodeIndex, "Selection should be restored on the new tree")
        #expect(newTree.path(at: restoredSelection) == notesPath)
        #expect(newTree.path(at: state.navigation.treemapRootIndex) == docsPath)
        #expect(defaults.string(forKey: Self.lastScannedVolumePathKey) == path)
    }

    @Test("Cancelling a cold refresh behind a stale view keeps the stale tree, selection, and badge exactly as they were")
    func cancellingColdRefreshBehindStaleKeepsStaleView() async throws {
        try await withTemporaryAppSupportDir {
            try await self.cancellingColdRefreshBehindStaleKeepsStaleViewBody()
        }
    }

    @MainActor
    private func cancellingColdRefreshBehindStaleKeepsStaleViewBody() async throws {
        // Several thousand real files/directories slow the (real, on-disk) rescan enough
        // that cancelling as soon as `isScanning` flips true has a comfortable window to
        // land mid-flight rather than after the scan has already finished. `cancel()`
        // called any earlier would be a no-op — `scan()` resets its own cancel flag at
        // its start (see FileScannerTests' `cancelledScanNoCrash`) — so this polls for
        // the flip instead of guessing a fixed delay.
        var layout: [String: UInt64] = [:]
        for dir in 0..<150 {
            for file in 0..<40 {
                layout["dir\(dir)/file\(file).dat"] = UInt64(file + 1)
            }
        }
        let (path, cleanup) = try createTempTree(layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }

        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        let savedAt = Date(timeIntervalSinceNow: -3600)
        state.staleViewAsOf = savedAt

        let snapshot = tree.nodesSnapshot()
        guard let fileIndex = snapshot.indices.first(where: { !snapshot[$0].isDirectory }).map({ UInt32($0) }) else {
            Issue.record("Expected at least one file in the scanned tree")
            return
        }
        state.selectedNodeIndex = fileIndex

        state.startFullRescan()
        await waitUntil(timeout: 2, pollInterval: .milliseconds(1)) { state.scanProgress.isScanning }
        state.cancelScan()

        await waitUntil { !state.scanProgress.isScanning }

        #expect(state.scanProgress.isCancelled, "Expected the cancel to land before the (real, on-disk) scan finished")
        #expect(state.staleViewAsOf == savedAt, "Cancelling should keep the original stale badge, not clear it")
        #expect(state.fileTree === tree, "Cancelling should leave the stale tree in place, unswapped")
        #expect(state.selectedNodeIndex == fileIndex, "Cancelling should not disturb the stale view's selection")
        #expect(state.staleBadgeText?.contains("refresh cancelled") == true)
    }
}

} // extension AppSupportEnvSuites
