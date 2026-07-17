import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Coverage for plan 038: per-volume session persistence (selection, treemap root,
/// expansion) restored across launches.
///
/// `SessionStateStoreTests` (Step 1) covers the store in isolation — round-trip, per-volume
/// isolation, corrupt data, cap enforcement — against a plain isolated `UserDefaults`
/// suite, no `DIRWIZ_APP_SUPPORT_DIR` involved.
///
/// `SessionStateRestoreTests` (Step 2) drives `AppState.restoreOnLaunch()` end to end —
/// same `TreeCache`/`AppSupportEnvSuites` pattern as `LaunchRestoreTests` (plan 036), since
/// `TreeCache.load`/`save` read `DIRWIZ_APP_SUPPORT_DIR`.
@MainActor
@Suite("SessionStateStore Tests")
struct SessionStateStoreTests {

    /// Runs `body` against a fresh, isolated `UserDefaults` suite, tearing it down
    /// afterward regardless of how `body` exits.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    // MARK: - Round-trip

    @Test("Round-trips a snapshot for a volume")
    func roundTrips() {
        withDefaults { defaults in
            let store = SessionStateStore(defaults: defaults)
            let snapshot = SessionSnapshot(
                expandedPaths: ["/Volumes/Test/a", "/Volumes/Test/a/b"],
                selectedPath: "/Volumes/Test/a/b/c",
                treemapRootPath: "/Volumes/Test/a"
            )
            store.save(snapshot, forVolume: "/Volumes/Test")

            let loaded = store.load(forVolume: "/Volumes/Test")
            #expect(loaded?.selectedPath == "/Volumes/Test/a/b/c")
            #expect(loaded?.treemapRootPath == "/Volumes/Test/a")
            #expect(loaded?.expandedPaths == ["/Volumes/Test/a", "/Volumes/Test/a/b"])
        }
    }

    @Test("Missing volume returns nil")
    func missingReturnsNil() {
        withDefaults { defaults in
            let store = SessionStateStore(defaults: defaults)
            #expect(store.load(forVolume: "/Volumes/Nope") == nil)
        }
    }

    @Test("save persists — a new store on the same suite reads it back")
    func persistsAcrossInstances() {
        withDefaults { defaults in
            let store1 = SessionStateStore(defaults: defaults)
            store1.save(
                SessionSnapshot(expandedPaths: ["/Volumes/Test/a"], selectedPath: "/Volumes/Test/a/x", treemapRootPath: "/Volumes/Test/a"),
                forVolume: "/Volumes/Test"
            )

            let store2 = SessionStateStore(defaults: defaults)
            #expect(store2.load(forVolume: "/Volumes/Test")?.selectedPath == "/Volumes/Test/a/x")
        }
    }

    // MARK: - Per-volume isolation

    @Test("Two volumes don't cross")
    func perVolumeIsolation() {
        withDefaults { defaults in
            let store = SessionStateStore(defaults: defaults)
            store.save(
                SessionSnapshot(expandedPaths: ["/Volumes/One/a"], selectedPath: "/Volumes/One/a/x", treemapRootPath: "/Volumes/One/a"),
                forVolume: "/Volumes/One"
            )
            store.save(
                SessionSnapshot(expandedPaths: ["/Volumes/Two/b"], selectedPath: "/Volumes/Two/b/y", treemapRootPath: "/Volumes/Two/b"),
                forVolume: "/Volumes/Two"
            )

            let one = store.load(forVolume: "/Volumes/One")
            let two = store.load(forVolume: "/Volumes/Two")
            #expect(one?.selectedPath == "/Volumes/One/a/x")
            #expect(one?.expandedPaths == ["/Volumes/One/a"])
            #expect(two?.selectedPath == "/Volumes/Two/b/y")
            #expect(two?.expandedPaths == ["/Volumes/Two/b"])
        }
    }

    // MARK: - Corrupt storage

    @Test("Non-Data value under the storage key returns nil rather than crashing")
    func corruptStorageWrongTypeReturnsNil() {
        withDefaults { defaults in
            defaults.set("not json data at all", forKey: SessionStateStore.storageKey(forVolume: "/Volumes/Test"))
            let store = SessionStateStore(defaults: defaults)
            #expect(store.load(forVolume: "/Volumes/Test") == nil)
        }
    }

    @Test("Malformed JSON under the storage key returns nil rather than crashing")
    func corruptStorageMalformedJSONReturnsNil() {
        withDefaults { defaults in
            let garbage = Data("{not valid json".utf8)
            defaults.set(garbage, forKey: SessionStateStore.storageKey(forVolume: "/Volumes/Test"))
            let store = SessionStateStore(defaults: defaults)
            #expect(store.load(forVolume: "/Volumes/Test") == nil)
        }
    }

    @Test("JSON missing required fields returns nil rather than crashing")
    func corruptStorageMissingFieldsReturnsNil() {
        withDefaults { defaults in
            // `expandedPaths` is non-optional — omitting it should fail to decode.
            let raw = Data(#"{"selectedPath": "/a/b"}"#.utf8)
            defaults.set(raw, forKey: SessionStateStore.storageKey(forVolume: "/Volumes/Test"))
            let store = SessionStateStore(defaults: defaults)
            #expect(store.load(forVolume: "/Volumes/Test") == nil)
        }
    }

    // MARK: - Cap enforcement

    @Test("expandedPaths beyond the cap is truncated on save")
    func capEnforced() throws {
        try withDefaults { defaults in
            let store = SessionStateStore(defaults: defaults)
            let manyPaths = (0..<3000).map { "/Volumes/Test/dir\(String(format: "%04d", $0))" }
            store.save(
                SessionSnapshot(expandedPaths: manyPaths, selectedPath: nil, treemapRootPath: nil),
                forVolume: "/Volumes/Test"
            )

            let loaded = try #require(store.load(forVolume: "/Volumes/Test"))
            #expect(loaded.expandedPaths.count == SessionStateStore.maxExpandedPaths)
        }
    }

    @Test("expandedPaths at or under the cap is untouched")
    func underCapUntouched() throws {
        try withDefaults { defaults in
            let store = SessionStateStore(defaults: defaults)
            let paths = (0..<10).map { "/Volumes/Test/dir\($0)" }
            store.save(
                SessionSnapshot(expandedPaths: paths, selectedPath: nil, treemapRootPath: nil),
                forVolume: "/Volumes/Test"
            )

            let loaded = try #require(store.load(forVolume: "/Volumes/Test"))
            #expect(loaded.expandedPaths.count == 10)
            #expect(loaded.expandedPaths == paths.sorted())
        }
    }
}

/// State-level restore tests (plan 038 Step 2): drives `AppState.restoreOnLaunch()`
/// end to end against a `TreeCache`-backed volume with a saved `SessionSnapshot`, and
/// checks the `TreeTableView.remapExpansion` path used to seed expansion. Nested under
/// `AppSupportEnvSuites` (see `LaunchRestoreTests`'s doc comment) since `TreeCache.load`/
/// `save` read `DIRWIZ_APP_SUPPORT_DIR`.
extension AppSupportEnvSuites {

@Suite("Session State Restore Tests")
struct SessionStateRestoreTests {

    private static let layout: [String: UInt64] = [
        "docs/sub/deep.txt": 50,
        "docs/other.txt": 30,
        "images/photo.jpg": 500,
    ]

    private static let lastScannedVolumePathKey = "lastScannedVolumePath"

    private func makeEphemeralDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

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

    // MARK: - Successful restore resolves through resolveOrAncestor

    @Test("restoreOnLaunch resolves a saved session's selection/root exactly, and TreeTableView.remapExpansion resolves its expansion set")
    func restoreResolvesSessionThroughAncestorResolution() async throws {
        try await withTemporaryAppSupportDir {
            try await self.restoreResolvesSessionThroughAncestorResolutionBody()
        }
    }

    @MainActor
    private func restoreResolvesSessionThroughAncestorResolutionBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)
        try TreeCache.save(tree: tree, lastEventId: FSEventsJournal.currentEventId())

        guard let docsIndex = nodeIndex(in: tree, pathSuffix: "/docs"),
              let subIndex = nodeIndex(in: tree, pathSuffix: "/docs/sub"),
              let deepIndex = nodeIndex(in: tree, pathSuffix: "/docs/sub/deep.txt") else {
            Issue.record("Expected docs, docs/sub, and docs/sub/deep.txt in the scanned tree")
            return
        }
        let docsPath = tree.path(at: docsIndex)
        let subPath = tree.path(at: subIndex)
        let deepPath = tree.path(at: deepIndex)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(path, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        state.sessionStore.save(
            SessionSnapshot(expandedPaths: [docsPath, subPath], selectedPath: deepPath, treemapRootPath: docsPath),
            forVolume: path
        )

        state.restoreOnLaunch()

        // Selection/root resolve synchronously inside restoreOnLaunch, before the
        // background auto-refresh even starts.
        #expect(state.selectedNodeIndex == deepIndex)
        #expect(state.navigation.treemapRootIndex == docsIndex)

        let session = try #require(state.sessionStore.load(forVolume: path))
        let remapped = TreeTableView.remapExpansion(paths: Set(session.expandedPaths), tree: tree)
        #expect(remapped == Set([docsIndex, subIndex]))

        // Let the background auto-refresh settle so no task outlives this test's
        // temporary DIRWIZ_APP_SUPPORT_DIR (torn down when withTemporaryAppSupportDir returns).
        await waitUntil { state.staleViewAsOf == nil && !state.scanProgress.isScanning }
    }

    // MARK: - Stale paths degrade gracefully

    @Test("A session with paths deleted since last launch degrades selection/root to the nearest surviving ancestor, and drops them silently from expansion")
    func staleSessionPathsDegradeGracefully() async throws {
        try await withTemporaryAppSupportDir {
            try await self.staleSessionPathsDegradeGracefullyBody()
        }
    }

    @MainActor
    private func staleSessionPathsDegradeGracefullyBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)
        try TreeCache.save(tree: tree, lastEventId: FSEventsJournal.currentEventId())

        guard let docsIndex = nodeIndex(in: tree, pathSuffix: "/docs"),
              let subIndex = nodeIndex(in: tree, pathSuffix: "/docs/sub") else {
            Issue.record("Expected docs and docs/sub in the scanned tree")
            return
        }
        let docsPath = tree.path(at: docsIndex)
        let subPath = tree.path(at: subIndex)
        // Neither of these existed in the fixture layout — simulates a folder/file
        // deleted between the session being saved and this launch.
        let goneFilePath = subPath + "/gone-file.txt"
        let goneDirPath = subPath + "/gone-dir"

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        defaults.set(path, forKey: Self.lastScannedVolumePathKey)

        let state = AppState(defaults: defaults)
        state.sessionStore.save(
            SessionSnapshot(expandedPaths: [docsPath, goneDirPath], selectedPath: goneFilePath, treemapRootPath: goneDirPath),
            forVolume: path
        )

        state.restoreOnLaunch()

        // Selection/root degrade to the nearest surviving ancestor ("docs/sub").
        #expect(state.selectedNodeIndex == subIndex)
        #expect(state.navigation.treemapRootIndex == subIndex)

        let session = try #require(state.sessionStore.load(forVolume: path))
        // Expansion has no ancestor fallback (unlike selection/root): the surviving
        // "docs" stays, the deleted "docs/sub/gone-dir" simply drops out.
        let remapped = TreeTableView.remapExpansion(paths: Set(session.expandedPaths), tree: tree)
        #expect(remapped == Set([docsIndex]))

        await waitUntil { state.staleViewAsOf == nil && !state.scanProgress.isScanning }
    }
}

} // extension AppSupportEnvSuites
