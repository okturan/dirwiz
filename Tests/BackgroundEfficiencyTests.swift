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
