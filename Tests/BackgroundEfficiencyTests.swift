import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Background-mode CPU discipline, pinned after a live sample showed DirWiz burning
/// ~78% CPU while idle in the background: the FSEvents queue canonicalized paths per
/// event, and every living-view splice re-decoded the unchanged temporal baseline.
@Suite("Background Efficiency Tests")
struct BackgroundEfficiencyTests {

    @Test("The monitor ignores its own store and derives parents natively")
    func monitorIgnoresOwnStoreCheaply() {
        let monitor = FSEventsMonitor(watchPath: "/")
        let ownWrite = DirWizOwnedPaths.applicationSupportRoot() + "/TreeCache/x.dwtc"
        #expect(!monitor.processChanges([
            FSChange(path: ownWrite, flags: 0, timestamp: Date())
        ]), "self-owned persistence writes must stay invisible to the living view")
        #expect(monitor.processChanges([
            FSChange(path: "/Users/somebody/file.txt", flags: 0, timestamp: Date())
        ]), "ordinary paths must still be accepted")

        #expect(FSEventsMonitor.parentDirectory(of: "/a/b/c.txt") == "/a/b")
        #expect(FSEventsMonitor.parentDirectory(of: "/top.txt") == "/")
    }

    /// Derived work behind the living view is throttled, but never at the cost of
    /// showing the user stale data they are actually looking at.
    @Test("Derived live work is throttled unless it is needed now")
    func derivedWorkThrottle() {
        let now: CFAbsoluteTime = 1_000_000

        // First run always proceeds - nothing has been computed yet.
        #expect(LiveDerivedWorkPolicy.shouldRun(
            lastRunAt: nil, now: now,
            minimumInterval: LiveDerivedWorkPolicy.cacheSaveMinimumInterval))

        // A splice seconds later must not redo it.
        #expect(!LiveDerivedWorkPolicy.shouldRun(
            lastRunAt: now - 10, now: now,
            minimumInterval: LiveDerivedWorkPolicy.cacheSaveMinimumInterval))

        // Being on screen always wins over the interval.
        #expect(LiveDerivedWorkPolicy.shouldRun(
            lastRunAt: now - 10, now: now,
            minimumInterval: LiveDerivedWorkPolicy.hardlinkRefreshMinimumInterval,
            isNeededNow: true))

        // The interval does elapse.
        #expect(LiveDerivedWorkPolicy.shouldRun(
            lastRunAt: now - LiveDerivedWorkPolicy.cacheSaveMinimumInterval, now: now,
            minimumInterval: LiveDerivedWorkPolicy.cacheSaveMinimumInterval))
    }

    /// The throttle must not resurrect bug_002: deferring the walk keeps the existing
    /// path-keyed groups on screen rather than clearing them into a false "none".
    @Test("A throttled hardlink refresh keeps groups and reruns when the tab opens")
    @MainActor
    func throttledHardlinkRefreshKeepsGroups() async throws {
        let (root, cleanup) = try createTempTree(["a.txt": 10, "b.txt": 20])
        defer { cleanup() }
        let scanner = FileScanner()
        let tree = FileTree()
        await scanner.scan(path: root, progress: ScanProgress(), tree: tree)

        let suiteName = "dirwiz.test.hlthrottle"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        state.fileTree = tree

        let existing = [HardlinkGroup(inode: 7, device: 1, fileSize: 10, paths: [root + "/a.txt"])]
        state.hardlink.hardlinkGroups = existing
        state.lastHardlinkRefreshAt = CFAbsoluteTimeGetCurrent()
        state.activeTab = .treeView

        state.refreshHardlinkGroups(throttled: true)
        #expect(state.hardlink.hardlinkGroups.count == 1,
                "a throttled refresh must not clear the visible groups")
        #expect(state.hardlinkGroupsNeedRefresh,
                "the deferral must be recorded so opening the tab recomputes")

        // Opening the tab is 'needed now' and must recompute.
        state.activeTab = .hardlinks
        #expect(!state.hardlinkGroupsNeedRefresh,
                "opening the Hardlinks tab must clear the deferral and rerun the walk")
    }
}

extension AppSupportEnvSuites {
    @Suite("Temporal Baseline Reload Tests")
    struct TemporalBaselineReloadTests {

        @MainActor
        private func waitUntil(
            timeout: TimeInterval = 10,
            _ condition: @MainActor () -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        @Test("An unchanged checkpoint is never re-decoded by stat refreshes")
        func unchangedBaselineIsNotRedecoded() async throws {
            try await withTemporaryAppSupportDir {
                try await self.unchangedBaselineBody()
            }
        }

        @MainActor
        private func unchangedBaselineBody() async throws {
                let (root, cleanup) = try createTempTree(["a.txt": 10])
                defer { cleanup() }
                let scanner = FileScanner()
                let tree = FileTree()
                await scanner.scan(path: root, progress: ScanProgress(), tree: tree)

                let suiteName = "dirwiz.test.bgeff"
                let defaults = UserDefaults(suiteName: suiteName)!
                defaults.removePersistentDomain(forName: suiteName)
                defer { defaults.removePersistentDomain(forName: suiteName) }
                let state = AppState(defaults: defaults)
                state.fileTree = tree

                let store = SnapshotStore(
                    rootPath: tree.path(at: 0),
                    storageIdentity: tree.persistenceIdentity
                )
                let first = TemporalSnapshot(
                    meta: TemporalSnapshotMeta(
                        id: UUID(), createdAt: Date(),
                        rootPath: tree.path(at: 0), totalBytes: 10, dirCount: 1
                    ),
                    byPath: ["": 10]
                )
                try store.createCheckpoint(from: first)

                state.loadSnapshotIfAvailable()
                await waitUntil { state.temporalSnapshotDecodeCount == 1 }
                #expect(state.temporalDiff.temporalSnapshot?.meta.id == first.meta.id)

                // The skip path still refreshes index-derived state; use that as the
                // deterministic completion signal, then pin that no decode happened.
                state.temporalDiff.availableCheckpoints = []
                state.loadSnapshotIfAvailable()
                await waitUntil { !state.temporalDiff.availableCheckpoints.isEmpty }
                #expect(state.temporalSnapshotDecodeCount == 1,
                        "a splice-driven refresh must not re-decode an unchanged baseline")

                let second = TemporalSnapshot(
                    meta: TemporalSnapshotMeta(
                        id: UUID(), createdAt: Date().addingTimeInterval(60),
                        rootPath: tree.path(at: 0), totalBytes: 20, dirCount: 1
                    ),
                    byPath: ["": 20]
                )
                try store.createCheckpoint(from: second)
                state.loadSnapshotIfAvailable()
                await waitUntil { state.temporalSnapshotDecodeCount == 2 }
                #expect(state.temporalDiff.temporalSnapshot?.meta.id == second.meta.id,
                        "a genuinely new checkpoint must load")
        }
    }
}
