import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Coverage for plan 037: `AppState.applyAccumulatedChanges()`, the "N folders changed ·
/// Refresh" badge's action. It reuses `FileScanner.rescanSubtrees` (028) exactly the way
/// `commitWarmStart` (plan 036) does, so most cases here drive it with synthetically-seeded
/// `fsChanges` for determinism — the splice engine itself is already equivalence-tested by
/// `SubtreeRescanTests`/`WarmStartTests`. One case (`realMonitorChangesAreAppliedAndRebaselined`)
/// drives a real `FSEventsMonitor` end to end to prove the monitor-rebaseline bookkeeping
/// actually clears what the monitor itself tracks, not just `AppState`'s mirrored copy.
///
/// Nested under `AppSupportEnvSuites` (TestHelpers.swift) and wrapped in
/// `withTemporaryAppSupportDir` throughout: every successful apply ends with a
/// `TreeCache.save`, which reads `DIRWIZ_APP_SUPPORT_DIR` — leaving it unset would touch the
/// real `~/Library/Application Support/DirWiz` directory.
extension AppSupportEnvSuites {

@Suite("Applied Changes Tests")
struct AppliedChangesTests {

    private static let layout: [String: UInt64] = [
        "docs/readme.txt": 100,
        "docs/notes.md": 200,
        "images/photo.jpg": 500,
    ]

    private func makeEphemeralDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// Polls `condition` on the main actor until it's true or `timeout` elapses — mirrors
    /// `LaunchRestoreTests`' helper of the same name (duplicated rather than shared, matching
    /// this repo's per-suite convention for these small test-only helpers).
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

    // MARK: - (a) Seeded apply matches a fresh cold scan

    @Test("Seeded fsChanges apply produces a tree equivalent to a fresh cold scan")
    func seededApplyMatchesColdScan() async throws {
        try await withTemporaryAppSupportDir {
            try await self.seededApplyMatchesColdScanBody()
        }
    }

    @MainActor
    private func seededApplyMatchesColdScanBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        state.setTreemapRoot(0, recordHistory: false)

        try Data(count: 999).write(to: URL(fileURLWithPath: path).appendingPathComponent("docs/added.txt"))

        state.fsChanges = [
            DirectoryChangeSummary(
                id: path + "/docs", path: path + "/docs", changeCount: 1, lastChangeDate: Date(),
                hasCreations: true, hasDeletions: false, hasModifications: false
            )
        ]

        await state.applyAccumulatedChanges()

        #expect(!state.isApplyingChanges)
        #expect(state.fsChanges.isEmpty)
        #expect(state.lastScanSummary?.hasPrefix("Refreshed") == true)

        let patchedTree = try #require(state.fileTree)
        let coldTree = await scanFixture(at: path)
        assertTreesEquivalent(patchedTree, coldTree, "seededApplyMatchesColdScan")
    }

    // MARK: - (b) Exploration preserved across apply

    @Test("Selection and treemap root survive an apply, re-resolved by path")
    func explorationPreservedAcrossApply() async throws {
        try await withTemporaryAppSupportDir {
            try await self.explorationPreservedAcrossApplyBody()
        }
    }

    @MainActor
    private func explorationPreservedAcrossApplyBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)

        guard let notesIndex = nodeIndex(in: tree, pathSuffix: "/docs/notes.md"),
              let docsIndex = nodeIndex(in: tree, pathSuffix: "/docs") else {
            Issue.record("Expected docs/notes.md and docs in the scanned tree")
            return
        }
        let notesPath = tree.path(at: notesIndex)
        let docsPath = tree.path(at: docsIndex)
        state.selectedNodeIndex = notesIndex
        state.setTreemapRoot(docsIndex, recordHistory: false)

        // Add a sibling file under docs — notes.md itself is untouched and must survive.
        try Data(count: 250).write(to: URL(fileURLWithPath: path).appendingPathComponent("docs/added.txt"))

        state.fsChanges = [
            DirectoryChangeSummary(
                id: docsPath, path: docsPath, changeCount: 1, lastChangeDate: Date(),
                hasCreations: true, hasDeletions: false, hasModifications: false
            )
        ]

        await state.applyAccumulatedChanges()

        let newTree = try #require(state.fileTree)
        let restoredSelection = try #require(state.selectedNodeIndex, "Selection should be restored on the patched tree")
        #expect(newTree.path(at: restoredSelection) == notesPath)
        #expect(newTree.path(at: state.navigation.treemapRootIndex) == docsPath)
    }

    // MARK: - (c) Bookkeeping: cleared accumulator, rebaselined monitor, summary set

    @Test("A successful apply clears fsChanges, rebaselines the monitor, and sets the summary")
    func bookkeepingCompleteAfterApply() async throws {
        try await withTemporaryAppSupportDir {
            try await self.bookkeepingCompleteAfterApplyBody()
        }
    }

    @MainActor
    private func bookkeepingCompleteAfterApplyBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        state.setTreemapRoot(0, recordHistory: false)

        // A monitor doesn't have to be running for the accumulator itself to be seeded —
        // exercised here as `nil` to prove the guard on `fsEventsMonitor` is optional-safe.
        #expect(state.fsEventsMonitor == nil)

        let docsPath = path + "/docs"
        try Data(count: 42).write(to: URL(fileURLWithPath: path).appendingPathComponent("docs/added.txt"))
        state.fsChanges = [
            DirectoryChangeSummary(
                id: docsPath, path: docsPath, changeCount: 3, lastChangeDate: Date(),
                hasCreations: true, hasDeletions: false, hasModifications: true
            )
        ]

        await state.applyAccumulatedChanges()

        #expect(state.fsChanges.isEmpty, "accumulator must be cleared after a successful apply")
        #expect(state.lastScanSummary?.hasPrefix("Refreshed 1 folders from last scan in") == true,
            "summary should report the one refreshed folder, got \(state.lastScanSummary ?? "nil")")
        #expect(!state.isApplyingChanges)
    }

    // MARK: - (d) Unresolved path falls back to a full refresh

    @Test("An unresolved changed path falls back to a full refresh instead of a half-applied patch")
    func unresolvedPathFallsBackToFullRefresh() async throws {
        try await withTemporaryAppSupportDir {
            try await self.unresolvedPathFallsBackToFullRefreshBody()
        }
    }

    @MainActor
    private func unresolvedPathFallsBackToFullRefreshBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        state.setTreemapRoot(0, recordHistory: false)

        // A path outside the tree's root can never resolve — `rescanSubtrees` reports it
        // unresolved, which `applyAccumulatedChanges` treats as untrustworthy.
        let outsidePath = "/nonexistent-outside-root-\(UUID().uuidString)"
        state.fsChanges = [
            DirectoryChangeSummary(
                id: outsidePath, path: outsidePath, changeCount: 1, lastChangeDate: Date(),
                hasCreations: false, hasDeletions: false, hasModifications: true
            )
        ]

        await state.applyAccumulatedChanges()

        #expect(!state.isApplyingChanges, "the flag must not stay stuck true through the fallback")

        // The fallback (`startFullRescan()`) dispatches its own background Task; wait for
        // it to settle rather than assuming synchronous completion.
        await waitUntil { state.scanProgress.scanComplete }

        #expect(!state.scanProgress.isScanning)
        #expect(
            state.lastScanSummary?.hasPrefix("Scanned") == true,
            "the fallback is a cold scan, not a warm patch — summary should read accordingly, got \(state.lastScanSummary ?? "nil")"
        )
    }

    // MARK: - (e) Empty changes is a no-op

    @Test("Applying with no accumulated changes is a no-op")
    func emptyChangesIsNoOp() async throws {
        try await withTemporaryAppSupportDir {
            try await self.emptyChangesIsNoOpBody()
        }
    }

    @MainActor
    private func emptyChangesIsNoOpBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        state.fsChanges = []

        await state.applyAccumulatedChanges()

        #expect(state.fileTree === tree, "a no-op apply must not touch the displayed tree")
        #expect(!state.isApplyingChanges)
        #expect(state.lastScanSummary == nil)
    }

    // MARK: - Guarded by the heavy-task exclusivity matrix

    @Test("applyAccumulatedChanges no-ops while another heavy task is running")
    func noOpsWhileAnotherHeavyTaskRuns() async throws {
        try await withTemporaryAppSupportDir {
            try await self.noOpsWhileAnotherHeavyTaskRunsBody()
        }
    }

    @MainActor
    private func noOpsWhileAnotherHeavyTaskRunsBody() async throws {
        let (path, cleanup) = try createTempTree(Self.layout)
        defer { cleanup() }
        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        state.isSpaceAnalysisRunning = true

        state.fsChanges = [
            DirectoryChangeSummary(
                id: path + "/docs", path: path + "/docs", changeCount: 1, lastChangeDate: Date(),
                hasCreations: true, hasDeletions: false, hasModifications: false
            )
        ]

        await state.applyAccumulatedChanges()

        #expect(!state.fsChanges.isEmpty, "should not have touched the accumulator without ever starting")
        #expect(!state.isApplyingChanges)
    }
}

} // extension AppSupportEnvSuites

// MARK: - Real-monitor integration (real FSEvents, temp-dir fixture)

/// FSEvents reports the fully resolved on-disk path for every changed directory. Temp
/// directories live under `/var`, itself a symlink to `/private/var` — resolve through
/// `realpath(3)` first so the root we scan/watch and the root FSEvents reports changes
/// under are the same string. Mirrors `WarmStartTests.realDirectoryPath` (duplicated per
/// this repo's per-suite convention for small test-only helpers).
private func realDirectoryPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else { return path }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// FSEvents journals filesystem operations asynchronously — give it a moment to catch up
/// before treating "now" as a clean boundary. Mirrors `WarmStartTests.settleFSEventsJournal`.
private func settleFSEventsJournal() async throws {
    try await Task.sleep(for: .milliseconds(500))
}

extension AppSupportEnvSuites {

@Suite("Applied Changes Real Monitor Tests")
struct AppliedChangesRealMonitorTests {

    private func makeEphemeralDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 10,
        pollInterval: Duration = .milliseconds(50),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func scanFixture(at path: String) async -> FileTree {
        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)
        return tree
    }

    /// The one real-`FSEventsMonitor` integration case: proves `applyAccumulatedChanges`'s
    /// "monitor rebaseline" bookkeeping clears what the monitor itself accumulates
    /// (`FSEventsMonitor.clearChanges()`), not just `AppState.fsChanges`'s mirrored copy.
    @Test("Real FSEventsMonitor changes get applied and the monitor is rebaselined")
    func realMonitorChangesAreAppliedAndRebaselined() async throws {
        try await withTemporaryAppSupportDir {
            try await self.realMonitorChangesAreAppliedAndRebaselinedBody()
        }
    }

    @MainActor
    private func realMonitorChangesAreAppliedAndRebaselinedBody() async throws {
        let (rawPath, cleanup) = try createTempTree(["docs/readme.txt": 100])
        defer { cleanup() }
        let path = realDirectoryPath(rawPath)
        try await settleFSEventsJournal()  // let the fixture's own creation land first

        let tree = await scanFixture(at: path)

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(defaults: defaults)
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: path)
        state.setTreemapRoot(0, recordHistory: false)

        state.toggleFSMonitoring()
        #expect(state.isFSMonitoringActive)

        try Data(count: 500).write(to: URL(fileURLWithPath: path).appendingPathComponent("docs/added.txt"))

        // FSEventsMonitor batches with a 3-second latency window; give it comfortable room.
        await waitUntil(timeout: 10) { !state.fsChanges.isEmpty }
        #expect(!state.fsChanges.isEmpty, "the monitor should have reported the on-disk change by now")

        await state.applyAccumulatedChanges()

        #expect(state.fsChanges.isEmpty)
        #expect(state.fsEventsMonitor?.currentChanges().isEmpty == true,
            "the monitor's own accumulator must be rebaselined, not just AppState's mirrored copy")

        let patchedTree = try #require(state.fileTree)
        let coldTree = await scanFixture(at: path)
        assertTreesEquivalent(patchedTree, coldTree, "realMonitorChangesAreAppliedAndRebaselined")

        state.toggleFSMonitoring()
    }
}

} // extension AppSupportEnvSuites
