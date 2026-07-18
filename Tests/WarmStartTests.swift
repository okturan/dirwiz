import Testing
import Foundation
@testable import DirWizCore

// MARK: - Planner (pure logic, no FSEvents involved)

@Suite("WarmStartPlanner Tests")
struct WarmStartPlannerTests {

    @Test("No cache available falls back to cold")
    func noCacheFallsBackToCold() {
        let decision = WarmStartPlanner.decide(cacheAvailable: false, replay: nil, cachedDirectoryCount: nil)
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
    }

    @Test("Missing replay result falls back to cold")
    func missingReplayFallsBackToCold() {
        let decision = WarmStartPlanner.decide(cacheAvailable: true, replay: nil, cachedDirectoryCount: nil)
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
    }

    @Test("Poisoned replay falls back to cold, worded for a human rather than the raw FSEvents flag")
    func poisonedFallsBackToCold() {
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .poisoned("MustScanSubDirs"),
            cachedDirectoryCount: nil
        )
        #expect(decision == .coldFallback(reason: "change journal unavailable"))
    }

    @Test("A replay timeout is worded distinctly from other poison reasons")
    func timeoutPoisonWordedDistinctly() {
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .poisoned("timed out waiting for HistoryDone"),
            cachedDirectoryCount: nil
        )
        #expect(decision == .coldFallback(reason: "change journal timed out"))
    }

    @Test("Changed roots over the fraction of cached directories fall back to cold, reason names the percentage")
    func tooManyChangesFallsBackToCold() {
        let manyPaths = (0..<10).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(manyPaths),
            cachedDirectoryCount: 20,
            maxChangedFraction: 0.20
        )
        guard case .coldFallback(let reason) = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
        #expect(reason.contains("10"), "reason should mention the changed root count: \(reason)")
        #expect(reason.contains("50"), "reason should mention the percentage (10/20 = 50%): \(reason)")
    }

    @Test("Zero actual changes still warms, with an empty target list")
    func zeroChangesWarmsWithEmptyTargets() {
        let decision = WarmStartPlanner.decide(cacheAvailable: true, replay: .changes([]), cachedDirectoryCount: 500)
        #expect(decision == .warm(targets: []))
    }

    @Test("Normal case warms with the changed directories as targets")
    func normalCaseWarms() {
        let targets = ["/root/docs", "/root/src"]
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(targets),
            cachedDirectoryCount: 100
        )
        #expect(decision == .warm(targets: targets))
    }

    @Test("Roots at exactly the threshold boundary still warm")
    func rootsAtThresholdBoundaryStillWarm() {
        // 100 cached dirs, 20% fraction → threshold 20; exactly 20 disjoint roots.
        let paths = (0..<20).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(paths),
            cachedDirectoryCount: 100,
            maxChangedFraction: 0.20
        )
        #expect(decision == .warm(targets: paths))
    }

    @Test("One root past the threshold boundary falls back to cold")
    func oneRootPastThresholdBoundaryFallsBackToCold() {
        // Same setup as the boundary test, one more root tips it over.
        let paths = (0..<21).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(paths),
            cachedDirectoryCount: 100,
            maxChangedFraction: 0.20
        )
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
    }

    @Test("Unknown directory count still warms under the defensive backstop")
    func nilDirectoryCountWarmsUnderBackstop() {
        let paths = (0..<100).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(paths),
            cachedDirectoryCount: nil
        )
        #expect(decision == .warm(targets: paths))
    }

    @Test("Unknown directory count falls back to cold once the defensive backstop is exceeded")
    func nilDirectoryCountFallsBackOverBackstop() {
        let paths = (0..<5_001).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(paths),
            cachedDirectoryCount: nil
        )
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
    }

    @Test("1000+ raw events collapsing to 3 real folders still warms — the bug this fixes")
    func manyRawEventsCollapsingToFewRootsWarms() {
        // Deep churn under three real folders produces a raw FSEvents path per touched
        // file, but they all nest under the same 3 outermost roots — the planner must
        // judge the collapsed count against the threshold, not the raw one.
        var rawPaths: [String] = []
        for folder in ["/root/a", "/root/b", "/root/c"] {
            rawPaths.append(folder)
            for i in 0..<333 {
                rawPaths.append("\(folder)/sub\(i)")
            }
        }
        #expect(rawPaths.count > 1_000)

        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(rawPaths),
            cachedDirectoryCount: 1_000
        )
        #expect(decision == .warm(targets: ["/root/a", "/root/b", "/root/c"]))
    }

    // MARK: - Cost-based rule (plan 042: judge by estimated WORK, not root count alone)

    @Test("Few roots but a huge share of cached items falls back to cold — the incident shape")
    func fewRootsHugeItemFractionFallsBackToCold() {
        // Exactly the reported incident: a handful of collapsed roots easily clears the
        // root-count threshold (3 of 1,000 dirs), but those roots are a subtree of
        // 100k+ files — three quarters of everything the cache knows about.
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(["/root/a", "/root/b", "/root/c"]),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 200_000,
            estimatedPatchItems: 150_000
        )
        guard case .coldFallback(let reason) = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
        #expect(reason.contains("75"), "reason should mention the item-change percentage: \(reason)")
    }

    @Test("Small scattered item fraction still warms even with the cost-based rule active")
    func smallItemFractionStillWarms() {
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(["/root/a", "/root/b"]),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 200_000,
            estimatedPatchItems: 1_000
        )
        #expect(decision == .warm(targets: ["/root/a", "/root/b"]))
    }

    @Test("Item fraction exactly at the 25% boundary still warms")
    func itemFractionAtBoundaryStillWarms() {
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(["/root/a"]),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 100_000,
            estimatedPatchItems: 25_000
        )
        #expect(decision == .warm(targets: ["/root/a"]))
    }

    @Test("Item fraction just over the 25% boundary falls back to cold")
    func itemFractionJustOverBoundaryFallsBackToCold() {
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(["/root/a"]),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 100_000,
            estimatedPatchItems: 25_001
        )
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback, got \(decision)")
            return
        }
    }

    @Test("Cost-based rule is inert when the caller doesn't supply the new parameters")
    func costBasedRuleInertWithoutNewParameters() {
        // Same inputs as `tooManyChangesFallsBackToCold` above, proving the default
        // (nil, nil) leaves the pre-042 root-count-only behavior byte-for-byte unchanged.
        let manyPaths = (0..<10).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(manyPaths),
            cachedDirectoryCount: 20,
            maxChangedFraction: 0.20
        )
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback (root-count rule alone), got \(decision)")
            return
        }
    }

    @Test("A passing item fraction still defers to the root-count rule as a secondary cap")
    func itemFractionPassingStillSubjectToRootCountCap() {
        // 500 tiny changed roots (1 item apiece) sail under the 25% item threshold but
        // blow through the 20% root-count cap — the cost-based rule isn't a replacement,
        // it's an ADDITIONAL gate.
        let manyTinyRoots = (0..<500).map { "/root/dir\($0)" }
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(manyTinyRoots),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 1_000_000,
            estimatedPatchItems: 500
        )
        guard case .coldFallback = decision else {
            Issue.record("expected coldFallback from the root-count cap despite a tiny item fraction, got \(decision)")
            return
        }
    }
}

// MARK: - estimatedPatchItemCount (plan 042: the cost-based rule's numerator)

@Suite("WarmStartPlanner estimatedPatchItemCount Tests")
struct WarmStartPlannerEstimatedPatchItemCountTests {

    @Test("Sums cached subtree sizes for resolvable roots and a small constant for unresolved ones")
    func sumsSubtreesAndHandlesUnresolvedRoots() {
        let tree = FileTree()
        tree.setRootPath("/root")
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "root")

        var dirA = FileNode()
        dirA.isDirectory = true
        var dirB = FileNode()
        dirB.isDirectory = true
        let firstChild = tree.addChildren([(node: dirA, name: "a"), (node: dirB, name: "b")], parentIndex: 0)
        let aIndex = firstChild

        let f1 = FileNode()
        let f2 = FileNode()
        let f3 = FileNode()
        tree.addChildren([(node: f1, name: "f1"), (node: f2, name: "f2"), (node: f3, name: "f3")], parentIndex: aIndex)

        // "a": itself + 3 files = 4. "b": itself = 1. "doesnotexist": unresolved constant.
        let count = WarmStartPlanner.estimatedPatchItemCount(
            forChangedPaths: ["/root/a", "/root/b", "/root/doesnotexist"],
            cachedTree: tree
        )
        #expect(count == 4 + 1 + 32, "unresolved root should contribute the small fallback constant (32)")
    }

    @Test("Nested changed paths collapse to their outermost root before summing")
    func collapsesNestedPathsBeforeSumming() {
        let tree = FileTree()
        tree.setRootPath("/root")
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "root")

        var dirA = FileNode()
        dirA.isDirectory = true
        let aIndex = tree.addChildren([(node: dirA, name: "a")], parentIndex: 0)
        let f1 = FileNode()
        tree.addChildren([(node: f1, name: "f1")], parentIndex: aIndex)

        // "/root/a/f1" is nested inside "/root/a" — only the outer root should be counted.
        let count = WarmStartPlanner.estimatedPatchItemCount(
            forChangedPaths: ["/root/a", "/root/a/f1"],
            cachedTree: tree
        )
        #expect(count == 2, "a + f1, counted once")
    }

    @Test("Empty changed-paths list contributes zero")
    func emptyChangedPathsContributesZero() {
        let tree = FileTree()
        tree.setRootPath("/root")
        var root = FileNode()
        root.isDirectory = true
        tree.addNode(root, name: "root")

        let count = WarmStartPlanner.estimatedPatchItemCount(forChangedPaths: [], cachedTree: tree)
        #expect(count == 0)
    }
}

// MARK: - PathCollapse (shared outermost-root collapsing, plan 035)

@Suite("PathCollapse Tests")
struct PathCollapseTests {

    @Test("A nested path collapses into its outermost ancestor")
    func nestedCollapsesToOutermost() {
        let result = PathCollapse.outermostRoots(["/root/a", "/root/a/b", "/root/a/b/c"])
        #expect(result == ["/root/a"])
    }

    @Test("Disjoint paths all survive")
    func disjointPathsStay() {
        let result = PathCollapse.outermostRoots(["/root/a", "/root/b", "/root/c"])
        #expect(result == ["/root/a", "/root/b", "/root/c"])
    }

    @Test("Exact duplicates collapse to a single entry")
    func duplicatesCollapse() {
        let result = PathCollapse.outermostRoots(["/root/a", "/root/a", "/root/a"])
        #expect(result == ["/root/a"])
    }

    @Test("The surviving set doesn't depend on whether a parent or its child appears first")
    func orderIndependent() {
        let childBeforeParent = PathCollapse.outermostRoots(["/root/a/b", "/root/a", "/root/c"])
        let parentBeforeChild = PathCollapse.outermostRoots(["/root/a", "/root/a/b", "/root/c"])
        #expect(Set(childBeforeParent) == Set(["/root/a", "/root/c"]))
        #expect(Set(childBeforeParent) == Set(parentBeforeChild))
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

// Nested under `AppSupportEnvSuites` (TestHelpers.swift): this suite flips the
// process-global DIRWIZ_APP_SUPPORT_DIR env var via `withTemporaryAppSupportDir` (same
// discipline as `TreeCacheTests`), and the parent's `.serialized` (which propagates
// recursively) is what keeps that mutation from interleaving with the other env-mutating
// suites.
extension AppSupportEnvSuites {

@Suite("WarmStart Composed Pipeline Tests")
struct WarmStartComposedPipelineTests {

    /// Drives the real warm-start pipeline end to end — cold scan, cache save,
    /// on-disk mutation (including a changed bundle, 028's one unit-untested branch),
    /// journal replay, planner decision, subtree rescan — and asserts the result is
    /// indistinguishable from a fresh cold scan of the same mutated fixture. This is
    /// the only place the composed pipeline is exercised as a whole rather than in parts.
    @Test("Warm start reproduces a fresh cold scan after mixed on-disk changes")
    func composedWarmStartMatchesColdScan() async throws {
        try await withTemporaryAppSupportDir {
            var layout: [String: UInt64] = [
                "docs/readme.txt": 100,
                "docs/notes.md": 200,
                "images/photo.jpg": 300,
                "MyApp.app/Contents/Resources/data.bin": 500,
            ]
            // Padding directories: the planner's threshold is a *percentage* of the cached
            // tree's directory count, so the denominator needs to look like a real tree.
            // Without this, the fixture has only 4 directories total, and the two areas
            // this test mutates below (docs + the bundle) collapse to 2 changed roots —
            // 50% "churn" that correctly (if misleadingly, for a test) falls back to cold.
            // ~30 cheap, untouched directories bring the denominator to ~34, so the same
            // 2 changed roots read as ~6% and the warm path — including the bundle-recompute
            // branch this test exists to cover — actually gets exercised.
            for i in 0..<30 {
                layout[String(format: "pad%02d/file.txt", i)] = 10
            }
            let (rawRoot, cleanup) = try createTempTree(layout)
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
            // `cachedDirectoryCount` comes from `bootstrapTree` — the same tree just saved
            // to cache in step 1 — since the real caller computes it from the loaded
            // cache's tree before deciding (AppState+Scan.swift's `directoryCount(in:)`).
            let replay = await FSEventsJournal.replay(root: root, since: savedEventId, timeout: 10)
            let cachedDirectoryCount = bootstrapTree.nodesSnapshot().reduce(0) { $0 + ($1.isDirectory ? 1 : 0) }
            let decision = WarmStartPlanner.decide(
                cacheAvailable: true,
                replay: replay.outcome,
                cachedDirectoryCount: cachedDirectoryCount
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

} // extension AppSupportEnvSuites
