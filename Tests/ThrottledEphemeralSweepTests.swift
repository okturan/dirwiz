import Foundation
import Testing
@testable import DirWizCore
@testable import DirWizUI

extension AppSupportEnvSuites {

@Suite("Throttled Ephemeral Sweep Scheduler")
struct ThrottledEphemeralSweepTests {
    private final class ScannerFactoryProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var invocationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func makeScanner() -> FileScanner {
            lock.lock()
            count += 1
            lock.unlock()
            return FileScanner()
        }
    }

    private var longIntervalConfiguration:
        EphemeralSweepPolicy.Configuration {
        .init(interval: 60 * 60, maximumHorizonAge: 2 * 60 * 60)
    }

    private func syntheticEphemeralPaths(root: String) -> EphemeralPaths {
        EphemeralPaths(
            darwinUserTemporaryDirectory: root + "/ephemeral",
            darwinUserCacheDirectory: root + "/unused-darwin-cache"
        )
    }

    private func change(_ path: String) -> DirectoryChangeSummary {
        DirectoryChangeSummary(
            id: path,
            path: path,
            changeCount: 1,
            lastChangeDate: Date(),
            hasCreations: true,
            hasDeletions: false,
            hasModifications: false
        )
    }

    private func makeDefaults() -> (
        defaults: UserDefaults,
        cleanup: () -> Void
    ) {
        let suiteName =
            "DirWizTests.ThrottledEphemeralSweep.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            defaults,
            {
                defaults.removePersistentDomain(forName: suiteName)
            }
        )
    }

    private func realDirectoryPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return buffer.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
    }

    private func settleFixtureJournal(root: String) async throws {
        let marker = root + "/.dirwiz-fsevents-settle-\(UUID().uuidString)"
        let beforeCreation = FSEventsJournal.currentEventId()
        try Data().write(to: URL(fileURLWithPath: marker))
        try #require(
            await waitForJournalChanges(root: root, since: beforeCreation),
            "FSEvents never journaled the fixture marker creation"
        )

        let beforeRemoval = FSEventsJournal.currentEventId()
        try FileManager.default.removeItem(atPath: marker)
        try #require(
            await waitForJournalChanges(root: root, since: beforeRemoval),
            "FSEvents never journaled the fixture marker removal"
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 30,
        pollInterval: Duration = .milliseconds(20),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func paddedLayout() -> [String: UInt64] {
        var layout: [String: UInt64] = [
            "interactive/old.txt": 10,
            "ephemeral/nested/old.txt": 20,
        ]
        for index in 0..<80 {
            layout[String(format: "padding/%03d/seed.txt", index)] = 1
        }
        return layout
    }

    @Test(
        "Temp-only live changes retain the old tree and cache without enumeration"
    )
    func tempOnlyLiveChangesHoldAtomicCheckpoint() async throws {
        try await withTemporaryAppSupportDir {
            try await self.tempOnlyLiveChangesHoldAtomicCheckpointBody()
        }
    }

    @MainActor
    private func tempOnlyLiveChangesHoldAtomicCheckpointBody() async throws {
        let (rawRoot, cleanup) = try createTempTree([
            "interactive/old.txt": 10,
            "ephemeral/old.txt": 20,
        ])
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let ephemeralRoot = root + "/ephemeral"
        let newEphemeralFile = ephemeralRoot + "/new.txt"

        let tree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: tree
        )
        let savedEventId: UInt64 = 777
        try TreeCache.save(tree: tree, lastEventId: savedEventId)

        let (defaults, defaultsCleanup) = makeDefaults()
        defer { defaultsCleanup() }
        let scannerProbe = ScannerFactoryProbe()
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root),
            ephemeralSweepConfiguration: longIntervalConfiguration,
            ephemeralSweepClock: { 200 },
            warmPatchScannerFactory: { scannerProbe.makeScanner() }
        )
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: root)
        state.recordPersistedCacheCheckpoint(
            eventId: savedEventId,
            savedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        try Data(count: 30).write(
            to: URL(fileURLWithPath: newEphemeralFile)
        )
        state.fsChanges = [change(ephemeralRoot)]

        await state.applyAccumulatedChanges()

        #expect(state.fsChanges.isEmpty)
        #expect(state.pendingEphemeralRoots == [ephemeralRoot])
        #expect(state.ephemeralSweepHorizonEventId == savedEventId)
        #expect(state.persistedCacheEventId == savedEventId)
        #expect(scannerProbe.invocationCount == 0)
        #expect(summarizeTree(tree)[newEphemeralFile] == nil)
        #expect(
            state.ephemeralSweepDecision
                == .wait(reason: EphemeralSweepPolicy.intervalWaitReason)
        )

        let heldCache = try #require(TreeCache.load(for: root))
        #expect(heldCache.lastEventId == savedEventId)
        #expect(summarizeTree(heldCache.tree)[newEphemeralFile] == nil)
    }

    @Test(
        "Mixed live changes splice the interactive tier and hold the ephemeral horizon"
    )
    func mixedLiveChangesSplitSchedulingTiers() async throws {
        try await withTemporaryAppSupportDir {
            try await self.mixedLiveChangesSplitSchedulingTiersBody()
        }
    }

    @MainActor
    private func mixedLiveChangesSplitSchedulingTiersBody() async throws {
        let (rawRoot, cleanup) = try createTempTree([
            "interactive/old.txt": 10,
            "ephemeral/old.txt": 20,
        ])
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let interactiveRoot = root + "/interactive"
        let ephemeralRoot = root + "/ephemeral"
        let newInteractiveFile = interactiveRoot + "/new.txt"
        let newEphemeralFile = ephemeralRoot + "/new.txt"

        let tree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: tree
        )
        let savedEventId: UInt64 = 888
        try TreeCache.save(tree: tree, lastEventId: savedEventId)

        let (defaults, defaultsCleanup) = makeDefaults()
        defer { defaultsCleanup() }
        let scannerProbe = ScannerFactoryProbe()
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root),
            ephemeralSweepConfiguration: longIntervalConfiguration,
            ephemeralSweepClock: { 200 },
            warmPatchScannerFactory: { scannerProbe.makeScanner() }
        )
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: root)
        state.recordPersistedCacheCheckpoint(
            eventId: savedEventId,
            savedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        try Data(count: 30).write(
            to: URL(fileURLWithPath: newInteractiveFile)
        )
        try Data(count: 40).write(
            to: URL(fileURLWithPath: newEphemeralFile)
        )
        state.fsChanges = [
            change(interactiveRoot),
            change(ephemeralRoot),
        ]

        await state.applyAccumulatedChanges()

        let displayed = summarizeTree(tree)
        #expect(displayed[newInteractiveFile] != nil)
        #expect(displayed[newEphemeralFile] == nil)
        #expect(state.pendingEphemeralRoots == [ephemeralRoot])
        #expect(state.ephemeralSweepHorizonEventId == savedEventId)
        #expect(state.persistedCacheEventId == savedEventId)
        #expect(scannerProbe.invocationCount == 0)
        #expect(state.staleViewAsOf != nil)

        let heldCache = try #require(TreeCache.load(for: root))
        #expect(heldCache.lastEventId == savedEventId)
        #expect(summarizeTree(heldCache.tree)[newInteractiveFile] == nil)
        #expect(summarizeTree(heldCache.tree)[newEphemeralFile] == nil)
    }

    @Test(
        "Navigation into an overlapping stale ephemeral root forces a long-interval sweep"
    )
    func navigationForcesSweepAndColdEquivalence() async throws {
        try await withTemporaryAppSupportDir {
            try await self.navigationForcesSweepAndColdEquivalenceBody()
        }
    }

    @MainActor
    private func navigationForcesSweepAndColdEquivalenceBody() async throws {
        let (rawRoot, cleanup) = try createTempTree(paddedLayout())
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let ephemeralRoot = root + "/ephemeral"
        let nestedRoot = ephemeralRoot + "/nested"
        let newEphemeralFile = nestedRoot + "/new.txt"

        try await settleFixtureJournal(root: root)
        let tree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: tree
        )
        let savedEventId = FSEventsJournal.currentEventId()
        try TreeCache.save(tree: tree, lastEventId: savedEventId)

        let (defaults, defaultsCleanup) = makeDefaults()
        defer { defaultsCleanup() }
        let scannerProbe = ScannerFactoryProbe()
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root),
            ephemeralSweepConfiguration: longIntervalConfiguration,
            ephemeralSweepClock: {
                Date().timeIntervalSinceReferenceDate
            },
            warmPatchScannerFactory: { scannerProbe.makeScanner() }
        )
        state.fileTree = tree
        state.selectedVolume = URL(fileURLWithPath: root)
        state.recordPersistedCacheCheckpoint(
            eventId: savedEventId,
            savedAt: Date()
        )

        try Data(count: 40).write(
            to: URL(fileURLWithPath: newEphemeralFile)
        )
        try #require(
            await waitForJournalChanges(root: root, since: savedEventId),
            "FSEvents never journaled the ephemeral mutation"
        )
        state.fsChanges = [change(nestedRoot)]
        await state.applyAccumulatedChanges()

        #expect(state.pendingEphemeralRoots == [nestedRoot])
        #expect(
            state.ephemeralSweepDecision
                == .wait(reason: EphemeralSweepPolicy.intervalWaitReason)
        )
        #expect(summarizeTree(tree)[newEphemeralFile] == nil)

        let ephemeralIndex = try #require(
            tree.nodeIndex(forPath: ephemeralRoot)
        )
        state.setTreemapRoot(ephemeralIndex)

        await waitUntil {
            state.pendingEphemeralRoots.isEmpty
                && !state.isEphemeralSweepRunning
        }

        #expect(state.pendingEphemeralRoots.isEmpty)
        #expect(!state.isEphemeralSweepRunning)
        #expect(scannerProbe.invocationCount == 1)
        #expect(state.lastScanSummary == "Updated temporary folders")
        #expect(state.staleViewAsOf == nil)
        #expect(state.ephemeralSweepHorizonEventId == nil)

        let finalTree = try #require(state.fileTree)
        #expect(summarizeTree(finalTree)[newEphemeralFile] != nil)
        let freshColdTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: freshColdTree
        )
        assertTreesEquivalent(
            finalTree,
            freshColdTree,
            "navigationForcedEphemeralSweep"
        )

        let finalCache = try #require(TreeCache.load(for: root))
        #expect(finalCache.lastEventId > savedEventId)
        assertTreesEquivalent(
            finalCache.tree,
            freshColdTree,
            "navigationForcedEphemeralSweepCache"
        )
    }

    @Test("Quiet stale status follows guard re-evaluation without counting skips")
    @MainActor
    func quietStatusAndGuardReevaluation() {
        let (defaults, defaultsCleanup) = makeDefaults()
        defer { defaultsCleanup() }
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: EphemeralPaths(
                darwinUserTemporaryDirectory: "/private/tmp/ephemeral",
                darwinUserCacheDirectory: "/private/tmp/unused-cache"
            ),
            ephemeralSweepConfiguration: longIntervalConfiguration,
            ephemeralSweepClock: { 200 }
        )
        state.recordPersistedCacheCheckpoint(
            eventId: 123,
            savedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        state.scanProgress.skippedDirectories = 4
        state.scanProgress.skippedDirectoryPaths = ["/already-skipped"]
        state.registerPendingEphemeralRoots([
            "/private/tmp/ephemeral/nested"
        ])

        #expect(
            state.ephemeralSweepDecision
                == .wait(reason: EphemeralSweepPolicy.intervalWaitReason)
        )
        #expect(
            state.ephemeralStaleStatusText
                == "Temporary folders are shown from the last sweep. "
                    + EphemeralSweepPolicy.intervalWaitReason
        )

        state.temporalDiff.isTemporalDiffEnabled = true
        state.refreshEphemeralSweepDecision()
        #expect(
            state.ephemeralSweepDecision
                == .wait(
                    reason:
                        EphemeralSweepPolicy.ActiveGuard.temporalDiff
                            .waitReason
                )
        )

        state.temporalDiff.isTemporalDiffEnabled = false
        state.scanProgress.isScanning = true
        state.refreshEphemeralSweepDecision()
        #expect(
            state.ephemeralSweepDecision
                == .wait(
                    reason: EphemeralSweepPolicy.ActiveGuard.scan.waitReason
                )
        )

        state.scanProgress.isScanning = false
        state.isSpaceAnalysisRunning = true
        state.refreshEphemeralSweepDecision()
        #expect(
            state.ephemeralSweepDecision
                == .wait(
                    reason:
                        EphemeralSweepPolicy.ActiveGuard.heavyTask.waitReason
                )
        )

        state.isSpaceAnalysisRunning = false
        state.refreshEphemeralSweepDecision()
        #expect(
            state.ephemeralSweepDecision
                == .wait(reason: EphemeralSweepPolicy.intervalWaitReason)
        )
        #expect(state.scanProgress.skippedDirectories == 4)
        #expect(
            state.scanProgress.skippedDirectoryPaths == ["/already-skipped"]
        )
    }
}

} // extension AppSupportEnvSuites
