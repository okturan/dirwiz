import Testing
import Foundation
@testable import DirWizCore

// MARK: - Planner (pure logic, no FSEvents involved)

@Suite("WarmStartPlanner Tests")
struct WarmStartPlannerTests {

    @Test("No cache available falls back to cold")
    func noCacheFallsBackToCold() {
        let decision = WarmStartPlanner.decide(cacheAvailable: false, replay: nil, changedCount: nil)
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
    }

    @Test("Missing replay result falls back to cold")
    func missingReplayFallsBackToCold() {
        let decision = WarmStartPlanner.decide(cacheAvailable: true, replay: nil, changedCount: nil)
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
    }

    @Test("Poisoned replay falls back to cold, carrying the reason")
    func poisonedFallsBackToCold() {
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .poisoned("MustScanSubDirs"),
            changedCount: nil
        )
        #expect(decision == .coldFallback(reason: "MustScanSubDirs"))
    }

    @Test("Changed directory count over the cap falls back to cold")
    func tooManyChangesFallsBackToCold() {
        let manyPaths = (0..<10).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(manyPaths),
            changedCount: manyPaths.count,
            maxChangedDirs: 5
        )
        guard case .coldFallback(let reason) = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
        #expect(reason.contains("10"), "reason should mention the offending count: \(reason)")
    }

    @Test("Zero actual changes still warms, with an empty target list")
    func zeroChangesWarmsWithEmptyTargets() {
        let decision = WarmStartPlanner.decide(cacheAvailable: true, replay: .changes([]), changedCount: 0)
        #expect(decision == .warm(targets: []))
    }

    @Test("Normal case warms with the changed directories as targets")
    func normalCaseWarms() {
        let targets = ["/root/docs", "/root/src"]
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(targets),
            changedCount: targets.count
        )
        #expect(decision == .warm(targets: targets))
    }

    @Test("Changed count at exactly the cap still warms")
    func changesAtCapStillWarms() {
        let paths = (0..<5).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(paths),
            changedCount: paths.count,
            maxChangedDirs: 5
        )
        #expect(decision == .warm(targets: paths))
    }
}

// MARK: - FSEventsJournal (real FSEvents, temp-dir fixtures)

/// FSEvents reports the fully resolved on-disk path for every changed directory,
/// trailing slash included. `FileManager.default.temporaryDirectory` (what
/// `createTempTree` builds fixtures under) lives under `/var`, which is itself a
/// symlink to `/private/var` — one of the handful of legacy aliases that Foundation's
/// own `resolvingSymlinksInPath` deliberately leaves untouched. Real scan roots
/// ("/", "/Volumes/Name") never hit this alias; only `/tmp`-based test fixtures do.
/// Resolve through raw `realpath(3)` so the root we scan/watch and the root FSEvents
/// reports changes under are the same string — otherwise every reported path silently
/// fails the tree's root-prefix check.
private func realDirectoryPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buffer) != nil else { return path }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// FSEvents paths for directories always carry a trailing slash.
private func stripTrailingSlash(_ path: String) -> String {
    guard path.count > 1, path.hasSuffix("/") else { return path }
    return String(path.dropLast())
}

/// The FSEvents daemon journals filesystem operations asynchronously — there's a real,
/// if small, dispatch lag between an operation happening and it landing in the journal.
/// In production this is a non-issue (there's always wall-clock time between "cache
/// saved" and "replay requested"), but a test that mutates and immediately replays can
/// race the daemon and see a stale/incomplete picture. Give it a moment to catch up
/// before treating "now" as a clean boundary.
private func settleFSEventsJournal() async throws {
    try await Task.sleep(for: .milliseconds(500))
}

@Suite("FSEventsJournal Tests")
struct FSEventsJournalTests {

    @Test("Spike scenario: mutations with no live stream running are replayed on request")
    func replayPicksUpChangesAcrossProcessLifetime() async throws {
        let (rawRoot, cleanup) = try createTempTree(["docs/readme.txt": 100])
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        try await settleFSEventsJournal()  // let the fixture's own creation land first

        // Captured before any mutation — mirrors what a cold scan or a prior warm
        // start would have saved alongside the cached tree.
        let savedId = FSEventsJournal.currentEventId()

        // Mutate with nothing watching — simulates a process restart where no
        // FSEventsMonitor was live in between.
        try Data(count: 50).write(to: URL(fileURLWithPath: root).appendingPathComponent("docs/added.txt"))
        try FileManager.default.createDirectory(atPath: root + "/newdir", withIntermediateDirectories: true)
        try await settleFSEventsJournal()

        let replay = await FSEventsJournal.replay(root: root, since: savedId, timeout: 10)

        #expect(replay.newEventId > savedId)
        guard case .changes(let rawPaths) = replay.outcome else {
            Issue.record("expected .changes, got \(replay.outcome)")
            return
        }
        let paths = rawPaths.map(stripTrailingSlash)
        #expect(paths.contains(root + "/docs"), "docs/ should be reported changed; got \(paths)")
        // A brand-new, still-empty top-level directory has nothing "inside" it yet — FSEvents
        // attributes its creation to the parent whose listing gained an entry (root), not to
        // the new directory itself. Either way the change is visible via replay.
        #expect(paths.contains(root), "the new directory's parent should be reported changed; got \(paths)")
    }

    @Test("Zero-change replay still completes via HistoryDone")
    func zeroChangeReplayCompletes() async throws {
        let (rawRoot, cleanup) = try createTempTree(["docs/readme.txt": 100])
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        try await settleFSEventsJournal()  // let the fixture's own creation land first

        let savedId = FSEventsJournal.currentEventId()
        let replay = await FSEventsJournal.replay(root: root, since: savedId, timeout: 10)

        #expect(replay.newEventId >= savedId)
        #expect(replay.outcome == .changes([]))
    }

    @Test("An unrealistically small timeout poisons the replay")
    func timeoutPoisonsReplay() async throws {
        let (rawRoot, cleanup) = try createTempTree(["docs/readme.txt": 100])
        defer { cleanup() }
        let root = realDirectoryPath(rawRoot)
        try await settleFSEventsJournal()

        let savedId = FSEventsJournal.currentEventId()
        let replay = await FSEventsJournal.replay(root: root, since: savedId, timeout: 0.001)

        guard case .poisoned = replay.outcome else {
            Issue.record("expected .poisoned from an effectively-zero timeout, got \(replay.outcome)")
            return
        }
    }
}

// MARK: - Composed pipeline (the feature's proof)

// `.serialized`: this suite flips the process-global DIRWIZ_APP_SUPPORT_DIR env var via
// `withTemporaryAppSupportDir` (same discipline as `TreeCacheTests`).
@Suite("WarmStart Composed Pipeline Tests", .serialized)
struct WarmStartComposedPipelineTests {

    /// Drives the real warm-start pipeline end to end — cold scan, cache save,
    /// on-disk mutation (including a changed bundle, 028's one unit-untested branch),
    /// journal replay, planner decision, subtree rescan — and asserts the result is
    /// indistinguishable from a fresh cold scan of the same mutated fixture. This is
    /// the only place the composed pipeline is exercised as a whole rather than in parts.
    @Test("Warm start reproduces a fresh cold scan after mixed on-disk changes")
    func composedWarmStartMatchesColdScan() async throws {
        try await withTemporaryAppSupportDir {
            let (rawRoot, cleanup) = try createTempTree([
                "docs/readme.txt": 100,
                "docs/notes.md": 200,
                "images/photo.jpg": 300,
                "MyApp.app/Contents/Resources/data.bin": 500,
            ])
            defer { cleanup() }
            // See `realDirectoryPath` above: keeps the scanned root and the root FSEvents
            // reports changes under identical, avoiding a spurious /var-vs-/private/var split.
            let root = realDirectoryPath(rawRoot)
            try await settleFSEventsJournal()  // let the fixture's own creation land first

            // Step 1: cold scan, capturing the event id BEFORE the scan starts — same
            // convention the real cold-scan cache write-back uses.
            let savedEventId = FSEventsJournal.currentEventId()
            let coldScanner = FileScanner()
            let progress = ScanProgress()
            let bootstrapTree = FileTree()
            await coldScanner.scan(path: root, progress: progress, tree: bootstrapTree)
            try TreeCache.save(tree: bootstrapTree, lastEventId: savedEventId)

            // Step 2: mutate the fixture — a plain addition, a brand-new nested dir
            // (exercises the ancestor-resolution rule), and a grown file *inside* the
            // bundle (exercises rescanSubtrees' bundle-target branch: recompute size via
            // computeBundleSize, no enumeration — 028's only branch without a dedicated
            // unit test).
            try Data(count: 150).write(to: URL(fileURLWithPath: root).appendingPathComponent("docs/added.log"))
            let newSub = URL(fileURLWithPath: root).appendingPathComponent("docs/newsub")
            try FileManager.default.createDirectory(at: newSub, withIntermediateDirectories: true)
            try Data(count: 42).write(to: newSub.appendingPathComponent("deep.txt"))
            try Data(count: 5_000).write(
                to: URL(fileURLWithPath: root).appendingPathComponent("MyApp.app/Contents/Resources/data.bin")
            )
            try await settleFSEventsJournal()

            // Step 3: replay the journal + decide, exactly as the UI orchestration would.
            let replay = await FSEventsJournal.replay(root: root, since: savedEventId, timeout: 10)
            let changedCount: Int?
            switch replay.outcome {
            case .changes(let paths): changedCount = paths.count
            case .poisoned: changedCount = nil
            }
            let decision = WarmStartPlanner.decide(
                cacheAvailable: true,
                replay: replay.outcome,
                changedCount: changedCount
            )
            guard case .warm(let targets) = decision else {
                Issue.record("expected a warm decision for a small, non-poisoned change set, got \(decision)")
                return
            }

            // Step 4: load the cached tree fresh (as the real warm path does) and patch it.
            guard let payload = TreeCache.load(for: root) else {
                Issue.record("expected the cache saved in step 1 to load back")
                return
            }
            let warmScanner = FileScanner()
            let rescanReport = await warmScanner.rescanSubtrees(targets, tree: payload.tree, progress: progress)
            #expect(rescanReport.unresolvedPaths.isEmpty, "all changed paths should resolve under the tree's root")

            // Step 5: cold-scan the same (now-mutated) fixture with the same scanner
            // configuration for an apples-to-apples comparison.
            let comparisonScanner = FileScanner()
            let comparisonTree = FileTree()
            await comparisonScanner.scan(path: root, progress: ScanProgress(), tree: comparisonTree)

            assertTreesEquivalent(payload.tree, comparisonTree, "composedWarmStartMatchesColdScan")
        }
    }
}
