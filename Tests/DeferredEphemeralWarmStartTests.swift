import Foundation
import Testing
@testable import DirWizCore
@testable import DirWizUI

extension AppSupportEnvSuites {

@Suite("Deferred Ephemeral Warm-Start Tests")
struct DeferredEphemeralWarmStartTests {
    private static let defaultsSuiteName =
        "DirWizTests.DeferredEphemeralWarmStart"

    /// A tiny deterministic stand-in for the journal contract used by this regression:
    /// replay returns every path whose event id is newer than the cache horizon.
    private struct JournalEvent {
        let id: UInt64
        let path: String
    }

    /// Real-filesystem wrapper that pauses exactly when Phase A enters the injected
    /// ephemeral root. Because the wrapper is not `RealFilesystemProvider` itself,
    /// FileScanner uses this high-level callback and the gate is deterministic.
    private final class GatedFilesystemProvider: @unchecked Sendable, FilesystemProvider {
        private let inner = RealFilesystemProvider()
        private let gatedPath: String
        private let releaseGate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reachedGate = false
        private var released = false

        init(gatedPath: String) {
            self.gatedPath = gatedPath
        }

        var didReachGate: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachedGate
        }

        /// A LATCH, not a one-shot token: the gate stays open once released. Shallow
        /// splicing legitimately enumerates a gated path twice per patch - the one-level
        /// A0 read, then the promoted full staging - and a one-shot semaphore would
        /// strand the second enumeration forever. The observation window this gate
        /// exists for ("trailing tier paused before any mutation") ends at the first
        /// release either way.
        func release() {
            lock.lock()
            let firstRelease = !released
            released = true
            lock.unlock()
            if firstRelease { releaseGate.signal() }
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
                let mustWait = !released
                lock.unlock()
                if mustWait {
                    releaseGate.wait()
                    // Recycle the token: a raced second waiter that also saw
                    // `mustWait` before the release must be freed too.
                    releaseGate.signal()
                }
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

    /// Pauses the second subtree splice after its transactional commit and aggregate
    /// repair, before FileScanner returns to AppState's token guard. That is the precise
    /// race a pre-enumeration filesystem gate cannot exercise.
    private final class SecondPostCommitGate: @unchecked Sendable {
        private let releaseGate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var commitCount = 0
        private var reachedSecondCommit = false

        var didReachSecondCommit: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachedSecondCommit
        }

        func postCommit() {
            lock.lock()
            commitCount += 1
            let shouldWait = commitCount == 2
            if shouldWait {
                reachedSecondCommit = true
            }
            lock.unlock()
            if shouldWait {
                releaseGate.wait()
            }
        }

        func release() {
            releaseGate.signal()
        }
    }

    /// Stops the superseding cold scan at its final atomic cache write. The displayed
    /// tree has already completed by this point. Holding this gate makes it possible to
    /// prove that the old cache is still valid but stale, then prove the replacement is
    /// equivalent after the write, without depending on which task the scheduler resumes.
    private final class ColdCacheSaveGate: @unchecked Sendable {
        private let releaseGate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reachedSave = false
        private var finishedSave = false

        var didReachSave: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachedSave
        }

        var didFinishSave: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finishedSave
        }

        func save(tree: FileTree, lastEventId: UInt64) throws {
            lock.lock()
            reachedSave = true
            lock.unlock()
            releaseGate.wait()
            defer {
                lock.lock()
                finishedSave = true
                lock.unlock()
            }
            try TreeCache.save(tree: tree, lastEventId: lastEventId)
        }

        func release() {
            releaseGate.signal()
        }
    }

    private func paddedTwoTierLayout() -> [String: UInt64] {
        var layout: [String: UInt64] = [
            "interactive/old.txt": 10,
            "ephemeral/old.txt": 20,
        ]
        for index in 0..<60 {
            layout[String(format: "pad%02d/seed.txt", index)] = 1
        }
        return layout
    }

    /// Nineteen cached items: the 25% item budget admits four. Each changed root is
    /// estimated at two cached items; after adding one file to each, Phase A stages three
    /// items per tier. The first tier fits, while the cumulative 3 + 3 does not.
    private func cumulativeBudgetLayout() -> [String: UInt64] {
        var layout: [String: UInt64] = [
            "interactive/old.txt": 10,
            "ephemeral/old.txt": 20,
        ]
        for index in 0..<7 {
            layout["pad\(index)/seed.txt"] = 1
        }
        return layout
    }

    private func realDirectoryPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return buffer.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 20,
        pollInterval: Duration = .milliseconds(10),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func syntheticEphemeralPaths(root: String) -> EphemeralPaths {
        EphemeralPaths(
            darwinUserTemporaryDirectory: root + "/ephemeral",
            darwinUserCacheDirectory: root + "/unused-darwin-cache"
        )
    }

    /// Establishes an FSEvents boundary for a freshly-created fixture without relying
    /// on an arbitrary daemon-latency sleep. The marker is gone before the scan, and
    /// both its creation and removal must be replayable before the saved horizon is
    /// captured.
    private func settleFixtureJournal(root: String) async throws {
        let marker = root + "/.dirwiz-fsevents-settle-\(UUID().uuidString)"
        let beforeCreation = FSEventsJournal.currentEventId()
        try Data().write(to: URL(fileURLWithPath: marker))
        try #require(
            await waitForJournalChanges(root: root, since: beforeCreation),
            "FSEvents never journaled the fixture-settle marker creation"
        )

        let beforeRemoval = FSEventsJournal.currentEventId()
        try FileManager.default.removeItem(atPath: marker)
        try #require(
            await waitForJournalChanges(root: root, since: beforeRemoval),
            "FSEvents never journaled the fixture-settle marker removal"
        )
    }

    private func makeEphemeralDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = Self.defaultsSuiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    @Test("A deferred subtree is replayed on the next warm start instead of becoming permanently stale")
    func deferredSubtreeSurvivesTheCacheHorizon() async throws {
        try await withTemporaryAppSupportDir {
            let (root, cleanup) = try createTempTree([
                "interactive/old.txt": 10,
                "ephemeral/old.txt": 20,
            ])
            defer { cleanup() }

            let savedEventId: UInt64 = 100
            let interactiveEventId: UInt64 = 140
            let deferredEventId: UInt64 = 160
            let replayEventId: UInt64 = 200
            let interactiveRoot = root + "/interactive"
            let deferredRoot = root + "/ephemeral"
            let journal = [
                JournalEvent(id: interactiveEventId, path: interactiveRoot),
                JournalEvent(id: deferredEventId, path: deferredRoot),
            ]

            let bootstrapTree = FileTree()
            await FileScanner().scan(
                path: root,
                progress: ScanProgress(),
                tree: bootstrapTree
            )
            try TreeCache.save(tree: bootstrapTree, lastEventId: savedEventId)

            try Data(count: 30).write(
                to: URL(fileURLWithPath: interactiveRoot).appendingPathComponent("new.txt")
            )
            try Data(count: 40).write(
                to: URL(fileURLWithPath: deferredRoot).appendingPathComponent("new.txt")
            )

            // First launch: publish only the interactive tier. This is the dangerous
            // instant at which a naive implementation writes replayEventId even though
            // the deferred subtree still describes savedEventId.
            let firstLaunch = try #require(TreeCache.load(for: root))
            let firstReport = await FileScanner().rescanSubtrees(
                [interactiveRoot],
                tree: firstLaunch.tree,
                progress: ScanProgress()
            )
            #expect(firstReport.unresolvedPaths.isEmpty)

            if let persistableEventId = WarmPatchCacheHorizon.eventIdForPersistence(
                replayedThrough: replayEventId,
                deferredTargetCount: 1
            ) {
                try TreeCache.save(
                    tree: firstLaunch.tree,
                    lastEventId: persistableEventId
                )
            }

            // Simulate quit/cancellation before the deferred pass, then warm start again.
            // The old cache must still replay the whole old->new window. Re-enumerating
            // the already-patched interactive root is harmless and idempotent; losing
            // the deferred root would make its stale totals permanent.
            let secondLaunch = try #require(TreeCache.load(for: root))
            let replayedPaths = journal
                .filter { $0.id > secondLaunch.lastEventId }
                .map(\.path)
            #expect(replayedPaths.contains(deferredRoot))

            let secondReport = await FileScanner().rescanSubtrees(
                replayedPaths,
                tree: secondLaunch.tree,
                progress: ScanProgress()
            )
            #expect(secondReport.unresolvedPaths.isEmpty)

            let freshColdTree = FileTree()
            await FileScanner().scan(
                path: root,
                progress: ScanProgress(),
                tree: freshColdTree
            )
            assertTreesEquivalent(
                secondLaunch.tree,
                freshColdTree,
                "deferredSubtreeSurvivesTheCacheHorizon"
            )
        }
    }

    @Test("Cancellation or quit during deferral leaves the previous atomic cache untouched")
    func interruptedDeferralLeavesPreviousCacheUntouched() async throws {
        try await withTemporaryAppSupportDir {
            let (root, cleanup) = try createTempTree([
                "interactive/old.txt": 10,
                "ephemeral/old.txt": 20,
            ])
            defer { cleanup() }

            let savedEventId: UInt64 = 100
            let bootstrapTree = FileTree()
            await FileScanner().scan(
                path: root,
                progress: ScanProgress(),
                tree: bootstrapTree
            )
            try TreeCache.save(tree: bootstrapTree, lastEventId: savedEventId)

            try Data(count: 30).write(
                to: URL(fileURLWithPath: root + "/interactive/new.txt")
            )
            let partial = try #require(TreeCache.load(for: root))
            _ = await FileScanner().rescanSubtrees(
                [root + "/interactive"],
                tree: partial.tree,
                progress: ScanProgress()
            )

            // A cancellation or process exit here performs no write. The cache file
            // remains the complete old checkpoint, not a mixture of old and new tiers.
            let persistableEventId = WarmPatchCacheHorizon.eventIdForPersistence(
                replayedThrough: 200,
                deferredTargetCount: 1
            )
            #expect(persistableEventId == nil)
            if let persistableEventId {
                try TreeCache.save(
                    tree: partial.tree,
                    lastEventId: persistableEventId
                )
            }

            let afterInterruption = try #require(TreeCache.load(for: root))
            #expect(afterInterruption.lastEventId == savedEventId)
            #expect(
                summarizeTree(afterInterruption.tree)[root + "/interactive/new.txt"] == nil,
                "the old cache tree and its old horizon must survive as one atomic checkpoint"
            )
        }
    }

    @Test("The replay horizon becomes persistable only after every deferred target completes")
    func completedDeferralMayAdvanceHorizon() {
        #expect(WarmPatchCacheHorizon.eventIdForPersistence(
            replayedThrough: 200,
            deferredTargetCount: 2
        ) == nil)
        #expect(WarmPatchCacheHorizon.eventIdForPersistence(
            replayedThrough: 200,
            deferredTargetCount: 1
        ) == nil)
        #expect(WarmPatchCacheHorizon.eventIdForPersistence(
            replayedThrough: 200,
            deferredTargetCount: 0
        ) == 200)
    }

    @Test("Trailing rescan preserves a cancellation that landed between tiers")
    func trailingRescanPreservesCancellation() async throws {
        let (root, cleanup) = try createTempTree([
            "ephemeral/old.txt": 20,
        ])
        defer { cleanup() }

        let tree = FileTree()
        let scanner = FileScanner()
        await scanner.scan(path: root, progress: ScanProgress(), tree: tree)
        let before = summarizeTree(tree)

        try Data(count: 40).write(
            to: URL(fileURLWithPath: root + "/ephemeral/new.txt")
        )

        // Models Cancel landing after tier one returned but before tier two entered.
        scanner.cancel()
        let report = await scanner.rescanSubtrees(
            [root + "/ephemeral"],
            tree: tree,
            progress: ScanProgress(),
            options: .trailing
        )

        #expect(report.wasCancelled)
        #expect(summarizeTree(tree) == before)
        #expect(SubtreeRescanOptions.trailing.priority == .utility)
        #expect(!SubtreeRescanOptions.trailing.resetsCancellation)
    }

    @Test("AppState publishes the interactive splice, invalidates both splices, then reaches cold-scan equivalence")
    func appStatePublishesBothTiersAndReachesEquivalence() async throws {
        try await withTemporaryAppSupportDir {
            try await self.appStatePublishesBothTiersAndReachesEquivalenceBody()
        }
    }

    @MainActor
    private func appStatePublishesBothTiersAndReachesEquivalenceBody() async throws {
        let (rawRoot, cleanup) = try createTempTree(paddedTwoTierLayout())
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let interactiveRoot = root + "/interactive"
        let ephemeralRoot = root + "/ephemeral"
        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }

        try await settleFixtureJournal(root: root)
        let savedEventId = FSEventsJournal.currentEventId()
        let bootstrapTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: bootstrapTree
        )
        try TreeCache.save(
            tree: bootstrapTree,
            lastEventId: savedEventId
        )

        try Data(count: 30).write(
            to: URL(fileURLWithPath: interactiveRoot + "/new.txt")
        )
        try Data(count: 40).write(
            to: URL(fileURLWithPath: ephemeralRoot + "/new.txt")
        )
        #expect(await waitForJournalChanges(
            root: root,
            since: savedEventId
        ))

        let gatedFilesystem = GatedFilesystemProvider(
            gatedPath: ephemeralRoot
        )
        defer { gatedFilesystem.release() }
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root),
            warmPatchScannerFactory: {
                FileScanner(filesystem: gatedFilesystem)
            }
        )
        state.selectedVolume = URL(fileURLWithPath: root)
        state.startSelectedVolumeScan()

        await waitUntil { gatedFilesystem.didReachGate }
        #expect(
            gatedFilesystem.didReachGate,
            "the trailing tier never reached its deterministic gate"
        )

        let interactiveTree = try #require(state.fileTree)
        let interactiveSnapshot = summarizeTree(interactiveTree)
        #expect(interactiveSnapshot[interactiveRoot + "/new.txt"] != nil)
        #expect(interactiveSnapshot[ephemeralRoot + "/new.txt"] == nil)
        #expect(state.scanProgress.isScanning)
        #expect(state.staleViewAsOf != nil)
        #expect(!state.isFSMonitoringActive)
        #expect(state.scanProgress.treeLayoutRevision >= 1)
        let firstLayoutRevision = state.scanProgress.treeLayoutRevision

        // The interactive tree remains usable while the trailing pass is gated. Move
        // both selection and treemap root now, and seed three independent index-keyed
        // overlays. The second canonical invalidation must preserve the paths while
        // clearing every stale index array.
        let expectedSelectedPath = interactiveRoot + "/new.txt"
        let selectedIndex = try #require(
            interactiveTree.nodeIndex(forPath: expectedSelectedPath)
        )
        let expectedTreemapRootPath = interactiveRoot
        let treemapRootIndex = try #require(
            interactiveTree.nodeIndex(forPath: expectedTreemapRootPath)
        )
        state.selectedNodeIndex = selectedIndex
        state.setTreemapRoot(treemapRootIndex)
        state.search.searchResults = [selectedIndex]
        state.recencyFactors = [0.5]
        state.temporalDiff.temporalDiffKinds = [1]
        state.temporalDiff.temporalDiffStrengths = [0.5]

        let cacheDuringDeferral = try #require(TreeCache.load(for: root))
        #expect(cacheDuringDeferral.lastEventId == savedEventId)
        #expect(
            summarizeTree(cacheDuringDeferral.tree)[interactiveRoot + "/new.txt"] == nil,
            "the old atomic cache must remain untouched until trailing completion"
        )

        gatedFilesystem.release()
        await waitUntil { !state.scanProgress.isScanning }
        #expect(!state.scanProgress.isScanning)
        #expect(!state.scanProgress.isCancelled)
        #expect(state.staleViewAsOf == nil)
        #expect(state.isFSMonitoringActive)
        #expect(
            state.scanProgress.treeLayoutRevision > firstLayoutRevision,
            "the trailing splice must force its own layout revision"
        )

        let finalTree = try #require(state.fileTree)
        #expect(summarizeTree(finalTree)[ephemeralRoot + "/new.txt"] != nil)
        #expect(state.selectedNodeIndex.map { finalTree.path(at: $0) }
            == expectedSelectedPath)
        #expect(finalTree.path(at: state.navigation.treemapRootIndex)
            == expectedTreemapRootPath)
        #expect(state.search.searchResults.isEmpty)
        #expect(state.recencyFactors.isEmpty)
        #expect(state.temporalDiff.temporalDiffKinds.isEmpty)
        #expect(state.temporalDiff.temporalDiffStrengths.isEmpty)

        let freshColdTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: freshColdTree
        )
        #expect(
            summarizeTree(freshColdTree)[ephemeralRoot + "/new.txt"] != nil,
            "cold scans must still count the deferred root in full"
        )
        assertTreesEquivalent(
            finalTree,
            freshColdTree,
            "appStatePublishesBothTiersAndReachesEquivalence"
        )

        let finalCache = try #require(TreeCache.load(for: root))
        #expect(finalCache.lastEventId > savedEventId)
        assertTreesEquivalent(
            finalCache.tree,
            freshColdTree,
            "completedTwoTierCache"
        )
        state.stopLiveMonitoring()
    }

    @Test("Cancelling the trailing tier keeps stale state and the old horizon; the next warm start catches up")
    func cancellingTrailingTierPreservesNextWarmStart() async throws {
        try await withTemporaryAppSupportDir {
            try await self.cancellingTrailingTierPreservesNextWarmStartBody()
        }
    }

    @MainActor
    private func cancellingTrailingTierPreservesNextWarmStartBody() async throws {
        let (rawRoot, cleanup) = try createTempTree(paddedTwoTierLayout())
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let interactiveRoot = root + "/interactive"
        let ephemeralRoot = root + "/ephemeral"
        let paths = syntheticEphemeralPaths(root: root)
        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }

        try await settleFixtureJournal(root: root)
        let savedEventId = FSEventsJournal.currentEventId()
        let bootstrapTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: bootstrapTree
        )
        try TreeCache.save(
            tree: bootstrapTree,
            lastEventId: savedEventId
        )

        try Data(count: 30).write(
            to: URL(fileURLWithPath: interactiveRoot + "/new.txt")
        )
        try Data(count: 40).write(
            to: URL(fileURLWithPath: ephemeralRoot + "/new.txt")
        )
        #expect(await waitForJournalChanges(
            root: root,
            since: savedEventId
        ))

        let gatedFilesystem = GatedFilesystemProvider(
            gatedPath: ephemeralRoot
        )
        defer { gatedFilesystem.release() }
        let interruptedState = AppState(
            defaults: defaults,
            ephemeralPaths: paths,
            warmPatchScannerFactory: {
                FileScanner(filesystem: gatedFilesystem)
            }
        )
        interruptedState.selectedVolume = URL(fileURLWithPath: root)
        interruptedState.startSelectedVolumeScan()
        await waitUntil { gatedFilesystem.didReachGate }
        #expect(gatedFilesystem.didReachGate)
        #expect(interruptedState.staleViewAsOf != nil)

        interruptedState.cancelScan()
        gatedFilesystem.release()
        await waitUntil { !interruptedState.scanProgress.isScanning }

        #expect(interruptedState.scanProgress.isCancelled)
        #expect(interruptedState.staleViewAsOf != nil)
        #expect(!interruptedState.isFSMonitoringActive)
        let cacheAfterCancel = try #require(TreeCache.load(for: root))
        #expect(cacheAfterCancel.lastEventId == savedEventId)
        #expect(
            summarizeTree(cacheAfterCancel.tree)[interactiveRoot + "/new.txt"] == nil
        )
        #expect(
            summarizeTree(cacheAfterCancel.tree)[ephemeralRoot + "/new.txt"] == nil
        )

        // A new process would construct a new AppState and load the untouched old
        // checkpoint. Replaying from its old horizon must see both changes again.
        let nextLaunch = AppState(
            defaults: defaults,
            ephemeralPaths: paths
        )
        nextLaunch.selectedVolume = URL(fileURLWithPath: root)
        nextLaunch.startSelectedVolumeScan()
        await waitUntil { !nextLaunch.scanProgress.isScanning }

        #expect(!nextLaunch.scanProgress.isCancelled)
        let caughtUpTree = try #require(nextLaunch.fileTree)
        #expect(
            summarizeTree(caughtUpTree)[ephemeralRoot + "/new.txt"] != nil
        )
        let freshColdTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: freshColdTree
        )
        assertTreesEquivalent(
            caughtUpTree,
            freshColdTree,
            "cancellingTrailingTierPreservesNextWarmStart"
        )
        nextLaunch.stopLiveMonitoring()
    }

    @Test("Cancelling an all-ephemeral patch before its first splice restores hardlink truth")
    func allEphemeralCancellationRestoresHardlinks() async throws {
        try await withTemporaryAppSupportDir {
            try await self.allEphemeralCancellationRestoresHardlinksBody()
        }
    }

    @MainActor
    private func allEphemeralCancellationRestoresHardlinksBody() async throws {
        let (rawRoot, cleanup) = try createTempTree(paddedTwoTierLayout())
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let ephemeralRoot = root + "/ephemeral"
        try FileManager.default.linkItem(
            atPath: ephemeralRoot + "/old.txt",
            toPath: ephemeralRoot + "/linked.txt"
        )
        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }

        try await settleFixtureJournal(root: root)
        let savedEventId = FSEventsJournal.currentEventId()
        let bootstrapTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: bootstrapTree
        )
        try TreeCache.save(
            tree: bootstrapTree,
            lastEventId: savedEventId
        )

        try Data(count: 40).write(
            to: URL(fileURLWithPath: ephemeralRoot + "/new.txt")
        )
        #expect(await waitForJournalChanges(
            root: root,
            since: savedEventId
        ))

        let gatedFilesystem = GatedFilesystemProvider(
            gatedPath: ephemeralRoot
        )
        defer { gatedFilesystem.release() }
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root),
            warmPatchScannerFactory: {
                FileScanner(filesystem: gatedFilesystem)
            }
        )
        state.selectedVolume = URL(fileURLWithPath: root)
        state.startSelectedVolumeScan()
        await waitUntil { gatedFilesystem.didReachGate }
        #expect(
            gatedFilesystem.didReachGate,
            "the all-ephemeral trailing tier never reached its pre-splice gate"
        )

        // Make the terminal path solely responsible for rebuilding hardlinks. Any
        // pre-patch refresh started while restoring the stale cache is token-invalidated
        // here, matching the state reset that exposed this cancellation edge.
        state.hardlinkTask?.cancel()
        state.hardlinkToken &+= 1
        state.hardlinkTask = nil
        state.hardlink.hardlinkGroups = []
        state.hardlink.isHardlinkScanRunning = false

        state.cancelScan()
        gatedFilesystem.release()
        await waitUntil {
            !state.scanProgress.isScanning
                && !state.hardlink.isHardlinkScanRunning
        }

        #expect(state.scanProgress.isCancelled)
        #expect(state.staleViewAsOf != nil)
        #expect(state.hardlink.hardlinkGroups.count == 1)
        let cacheAfterCancel = try #require(TreeCache.load(for: root))
        #expect(cacheAfterCancel.lastEventId == savedEventId)
        #expect(
            summarizeTree(cacheAfterCancel.tree)[ephemeralRoot + "/new.txt"] == nil
        )
    }

    @Test("A zero-change warm start restores hardlink groups cleared by scan reset")
    func zeroChangeWarmStartRestoresHardlinks() async throws {
        try await withTemporaryAppSupportDir {
            try await self.zeroChangeWarmStartRestoresHardlinksBody()
        }
    }

    @MainActor
    private func zeroChangeWarmStartRestoresHardlinksBody() async throws {
        let (rawRoot, cleanup) = try createTempTree([
            "original.bin": 128,
        ])
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        try FileManager.default.linkItem(
            atPath: root + "/original.bin",
            toPath: root + "/linked.bin"
        )

        try await settleFixtureJournal(root: root)
        let bootstrapTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: bootstrapTree
        )
        let savedEventId = FSEventsJournal.currentEventId()
        try TreeCache.save(
            tree: bootstrapTree,
            lastEventId: savedEventId
        )

        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root)
        )
        state.selectedVolume = URL(fileURLWithPath: root)
        state.startSelectedVolumeScan()
        await waitUntil {
            !state.scanProgress.isScanning
                && !state.hardlink.isHardlinkScanRunning
        }

        #expect(!state.scanProgress.isScanning)
        #expect(state.lastScanSummary?.contains("0 folders") == true)
        #expect(state.hardlink.hardlinkGroups.count == 1)
        state.stopLiveMonitoring()
    }

    @Test("Old-layout navigation is rejected from trailing commit until invalidation")
    func navigationCannotCrossTrailingCommit() async throws {
        try await withTemporaryAppSupportDir {
            try await self.navigationCannotCrossTrailingCommitBody()
        }
    }

    @MainActor
    private func navigationCannotCrossTrailingCommitBody() async throws {
        let (rawRoot, cleanup) = try createTempTree(paddedTwoTierLayout())
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let interactiveRoot = root + "/interactive"
        let ephemeralRoot = root + "/ephemeral"
        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }

        let savedEventId: UInt64 = 100
        let replayEventId: UInt64 = 200
        let bootstrapTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: bootstrapTree
        )
        try TreeCache.save(
            tree: bootstrapTree,
            lastEventId: savedEventId
        )

        try Data(count: 30).write(
            to: URL(fileURLWithPath: interactiveRoot + "/new.txt")
        )
        try Data(count: 40).write(
            to: URL(fileURLWithPath: ephemeralRoot + "/new.txt")
        )

        let phaseAGate = GatedFilesystemProvider(gatedPath: ephemeralRoot)
        defer { phaseAGate.release() }
        let postCommitGate = SecondPostCommitGate()
        defer { postCommitGate.release() }
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root),
            warmPatchScannerFactory: {
                FileScanner(
                    filesystem: phaseAGate,
                    subtreeRescanPostCommitHook: {
                        postCommitGate.postCommit()
                    }
                )
            },
            warmStartJournalReplay: { _, _ in
                JournalReplay(
                    outcome: .changes([interactiveRoot, ephemeralRoot]),
                    newEventId: replayEventId
                )
            }
        )
        state.selectedVolume = URL(fileURLWithPath: root)
        state.startSelectedVolumeScan()
        await waitUntil { phaseAGate.didReachGate }
        #expect(
            phaseAGate.didReachGate,
            "the trailing tier never reached its pre-commit Phase A gate"
        )

        let interactiveTree = try #require(state.fileTree)
        let expectedSelectedPath = interactiveRoot + "/new.txt"
        let expectedSelectedIndex = try #require(
            interactiveTree.nodeIndex(forPath: expectedSelectedPath)
        )
        let expectedTreemapRootPath = interactiveRoot
        let expectedTreemapRootIndex = try #require(
            interactiveTree.nodeIndex(forPath: expectedTreemapRootPath)
        )
        let rejectedOldSelectionIndex = try #require(
            interactiveTree.nodeIndex(forPath: root + "/pad59/seed.txt")
        )
        let rejectedOldTreemapIndex = try #require(
            interactiveTree.nodeIndex(forPath: root + "/pad59")
        )
        state.selectedNodeIndex = expectedSelectedIndex
        state.setTreemapRoot(expectedTreemapRootIndex)

        phaseAGate.release()
        await waitUntil { postCommitGate.didReachSecondCommit }
        #expect(postCommitGate.didReachSecondCommit)
        #expect(
            state.isWarmPatchCommitInProgress,
            "AppState must close index interaction before FileScanner commits"
        )

        // These indices came from the old layout. The tree has already committed its
        // compaction, but the canonical invalidator is deliberately held back by the
        // post-commit gate. Accepting either interaction here would capture whichever
        // unrelated nodes now occupy those numeric slots.
        state.selectedNodeIndex = rejectedOldSelectionIndex
        state.setTreemapRoot(rejectedOldTreemapIndex)
        #expect(state.selectedNodeIndex == expectedSelectedIndex)
        #expect(state.navigation.treemapRootIndex == expectedTreemapRootIndex)

        postCommitGate.release()
        await waitUntil {
            !state.scanProgress.isScanning
                && !state.hardlink.isHardlinkScanRunning
        }
        #expect(!state.isWarmPatchCommitInProgress)

        let finalTree = try #require(state.fileTree)
        #expect(
            state.selectedNodeIndex.map { finalTree.path(at: $0) }
                == expectedSelectedPath
        )
        #expect(
            finalTree.path(at: state.navigation.treemapRootIndex)
                == expectedTreemapRootPath
        )
        let storedSession = try #require(
            state.sessionStore.load(forVolume: root)
        )
        #expect(storedSession.selectedPath == expectedSelectedPath)
        #expect(storedSession.treemapRootPath == expectedTreemapRootPath)
        state.stopLiveMonitoring()
    }

    @Test("A newer cold scan detaches a trailing tier that already committed before its token check")
    func newerColdScanSupersedesTrailingTier() async throws {
        try await withTemporaryAppSupportDir {
            try await self.newerColdScanSupersedesTrailingTierBody()
        }
    }

    @MainActor
    private func newerColdScanSupersedesTrailingTierBody() async throws {
        let (rawRoot, cleanup) = try createTempTree(paddedTwoTierLayout())
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let interactiveRoot = root + "/interactive"
        let ephemeralRoot = root + "/ephemeral"
        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }

        let savedEventId: UInt64 = 100
        let replayEventId: UInt64 = 200
        let bootstrapTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: bootstrapTree
        )
        #expect(bootstrapTree.count == 125)
        try TreeCache.save(
            tree: bootstrapTree,
            lastEventId: savedEventId
        )

        try Data(count: 30).write(
            to: URL(fileURLWithPath: interactiveRoot + "/new.txt")
        )
        try Data(count: 40).write(
            to: URL(fileURLWithPath: ephemeralRoot + "/new.txt")
        )

        let phaseAGate = GatedFilesystemProvider(gatedPath: ephemeralRoot)
        defer { phaseAGate.release() }
        let postCommitGate = SecondPostCommitGate()
        defer { postCommitGate.release() }
        let cacheSaveGate = ColdCacheSaveGate()
        defer { cacheSaveGate.release() }
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root),
            warmPatchScannerFactory: {
                FileScanner(
                    filesystem: phaseAGate,
                    subtreeRescanPostCommitHook: {
                        postCommitGate.postCommit()
                    }
                )
            },
            warmStartJournalReplay: { _, _ in
                JournalReplay(
                    outcome: .changes([interactiveRoot, ephemeralRoot]),
                    newEventId: replayEventId
                )
            },
            coldCacheSave: { tree, eventId in
                try cacheSaveGate.save(tree: tree, lastEventId: eventId)
            }
        )
        state.selectedVolume = URL(fileURLWithPath: root)
        state.startSelectedVolumeScan()

        await waitUntil { phaseAGate.didReachGate }
        #expect(
            phaseAGate.didReachGate,
            "the trailing tier never reached its deterministic Phase-A gate"
        )
        phaseAGate.release()
        await waitUntil { postCommitGate.didReachSecondCommit }
        #expect(
            postCommitGate.didReachSecondCommit,
            "the trailing splice never reached its post-commit/pre-token gate"
        )
        let committedWarmTree = try #require(state.fileTree)

        // The old trailing scanner has already renumbered committedWarmTree. The new
        // flow must synchronously detach it before the old task can return to AppState.
        let warmProgress = state.scanProgress
        state.startFullRescan()
        #expect(
            state.scanProgress !== warmProgress,
            "supersession must synchronously publish a new progress instance"
        )
        #expect(
            state.fileTree !== committedWarmTree,
            "a post-commit supersession must not keep displaying the mutated old tree"
        )
        postCommitGate.release()
        await waitUntil(timeout: 30) { cacheSaveGate.didReachSave }
        #expect(
            cacheSaveGate.didReachSave,
            "the superseding cold scan never reached its cache-persistence boundary"
        )

        #expect(!state.scanProgress.isCancelled)
        #expect(state.staleViewAsOf == nil)
        #expect(state.lastScanSummary?.hasPrefix("Scanned ") == true)
        let finalTree = try #require(state.fileTree)
        let freshColdTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: freshColdTree
        )
        #expect(freshColdTree.count == 127)
        assertTreesEquivalent(
            finalTree,
            freshColdTree,
            "newerColdScanSupersedesTrailingTier"
        )

        // The CI failure sampled here: bundle sizing had ended, but its Task had not yet
        // executed the following cache save. The 125-node object was the untouched
        // bootstrap cache, not the 127-node tree AppState displayed. Only the two files
        // created after that cache horizon can be absent from it.
        let cacheBeforeColdSave = try #require(TreeCache.load(for: root))
        let cachedPaths = Set(summarizeTree(cacheBeforeColdSave.tree).keys)
        let coldPaths = Set(summarizeTree(freshColdTree).keys)
        #expect(cacheBeforeColdSave.lastEventId == savedEventId)
        #expect(cacheBeforeColdSave.tree.count == 125)
        #expect(coldPaths.subtracting(cachedPaths) == [
            interactiveRoot + "/new.txt",
            ephemeralRoot + "/new.txt",
        ])
        #expect(cachedPaths.subtracting(coldPaths).isEmpty)

        cacheSaveGate.release()
        await waitUntil { cacheSaveGate.didFinishSave }
        #expect(
            cacheSaveGate.didFinishSave,
            "the superseding cold cache write did not finish"
        )
        let finalCache = try #require(TreeCache.load(for: root))
        assertTreesEquivalent(
            finalCache.tree,
            freshColdTree,
            "supersedingColdCache"
        )
        state.stopLiveMonitoring()
    }

    @Test("Interactive and trailing tiers share one staged-item budget")
    func tiersShareOneStagedItemBudget() async throws {
        try await withTemporaryAppSupportDir {
            try await self.tiersShareOneStagedItemBudgetBody()
        }
    }

    @MainActor
    private func tiersShareOneStagedItemBudgetBody() async throws {
        let (rawRoot, cleanup) = try createTempTree(cumulativeBudgetLayout())
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        let interactiveRoot = root + "/interactive"
        let ephemeralRoot = root + "/ephemeral"
        let (defaults, defaultsCleanup) = makeEphemeralDefaults()
        defer { defaultsCleanup() }

        try await settleFixtureJournal(root: root)
        let savedEventId = FSEventsJournal.currentEventId()
        let bootstrapTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: bootstrapTree
        )
        #expect(bootstrapTree.count == 19)
        try TreeCache.save(
            tree: bootstrapTree,
            lastEventId: savedEventId
        )

        try Data(count: 30).write(
            to: URL(fileURLWithPath: interactiveRoot + "/new.txt")
        )
        try Data(count: 40).write(
            to: URL(fileURLWithPath: ephemeralRoot + "/new.txt")
        )
        #expect(await waitForJournalChanges(
            root: root,
            since: savedEventId
        ))

        let gatedFilesystem = GatedFilesystemProvider(gatedPath: ephemeralRoot)
        defer { gatedFilesystem.release() }
        let state = AppState(
            defaults: defaults,
            ephemeralPaths: syntheticEphemeralPaths(root: root),
            warmPatchScannerFactory: {
                FileScanner(filesystem: gatedFilesystem)
            }
        )
        state.selectedVolume = URL(fileURLWithPath: root)
        state.startSelectedVolumeScan()

        await waitUntil { gatedFilesystem.didReachGate }
        #expect(
            gatedFilesystem.didReachGate,
            "the planner must admit the cached four-item estimate and reach tier two"
        )
        let interactiveTree = try #require(state.fileTree)
        #expect(interactiveTree.nodeIndex(forPath: interactiveRoot + "/new.txt") != nil)
        #expect(interactiveTree.nodeIndex(forPath: ephemeralRoot + "/new.txt") == nil)

        gatedFilesystem.release()
        await waitUntil(timeout: 30) {
            state.scanProgress.scanComplete
                && !state.scanProgress.isScanning
                && !state.isBundleSizingRunning
        }

        #expect(
            state.lastScanSummary?
                .contains("~32% of files changed since last scan") == true
        )
        #expect(state.lastScanSummary?.contains("changed locations") != true)
        let historyReason = WarmStartHistory.load(for: root).last?.reason
        #expect(historyReason == "~32% of files changed since last scan")

        let finalTree = try #require(state.fileTree)
        let freshColdTree = FileTree()
        await FileScanner().scan(
            path: root,
            progress: ScanProgress(),
            tree: freshColdTree
        )
        assertTreesEquivalent(
            finalTree,
            freshColdTree,
            "cumulativeBudgetColdFallback"
        )
        state.stopLiveMonitoring()
    }
}

} // extension AppSupportEnvSuites
