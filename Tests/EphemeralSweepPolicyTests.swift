import Foundation
import Testing
@testable import DirWizCore

@Suite("Ephemeral sweep policy")
struct EphemeralSweepPolicyTests {
    private let configuration = EphemeralSweepPolicy.Configuration(
        interval: 900,
        maximumHorizonAge: 1_800
    )

    private func input(
        lastSweepAt: TimeInterval? = 100,
        now: TimeInterval = 200,
        pendingEphemeralRoots: [String] = ["/private/var/folders/user/T"],
        activeGuards: Set<EphemeralSweepPolicy.ActiveGuard> = [],
        horizonAge: TimeInterval? = 100,
        navigationRequested: Bool = false
    ) -> EphemeralSweepPolicy.Input {
        .init(
            lastSweepAt: lastSweepAt,
            now: now,
            pendingEphemeralRoots: pendingEphemeralRoots,
            activeGuards: activeGuards,
            horizonAge: horizonAge,
            navigationRequested: navigationRequested
        )
    }

    @Test("Measured defaults are 15-minute interval and 30-minute horizon")
    func measuredDefaults() {
        let defaults = EphemeralSweepPolicy.Configuration()
        #expect(defaults.interval == 900)
        #expect(defaults.maximumHorizonAge == 1_800)
    }

    @Test(
        "Environment interval accepts finite nonnegative seconds",
        arguments: [
            ("0", 0.0),
            ("0.25", 0.25),
            ("900", 900.0),
            ("1e3", 1_000.0),
            (" 1200 \n", 1_200.0),
        ]
    )
    func validEnvironmentInterval(rawValue: String, expected: TimeInterval) {
        let configured = EphemeralSweepPolicy.Configuration(
            environment: [
                EphemeralSweepPolicy.intervalEnvironmentKey: rawValue
            ]
        )
        #expect(configured.interval == expected)
        #expect(configured.maximumHorizonAge == 1_800)
    }

    @Test(
        "Missing or invalid environment interval falls back to default",
        arguments: [
            nil,
            "",
            "not-a-number",
            "-0.1",
            "nan",
            "inf",
            "-inf",
        ] as [String?]
    )
    func invalidEnvironmentInterval(rawValue: String?) {
        var environment: [String: String] = [:]
        if let rawValue {
            environment[EphemeralSweepPolicy.intervalEnvironmentKey] =
                rawValue
        }
        let configured = EphemeralSweepPolicy.Configuration(
            environment: environment
        )
        #expect(configured.interval == 900)
    }

    @Test("Injected environment keeps the injected horizon bound")
    func environmentKeepsInjectedHorizon() {
        let configured = EphemeralSweepPolicy.Configuration(
            environment: [
                EphemeralSweepPolicy.intervalEnvironmentKey: "0"
            ],
            maximumHorizonAge: 45
        )
        #expect(configured.interval == 0)
        #expect(configured.maximumHorizonAge == 45)
    }

    @Test(
        "Invalid direct configuration values fall back independently",
        arguments: [
            (-1.0, 45.0, 900.0, 45.0),
            (.infinity, 45.0, 900.0, 45.0),
            (45.0, -.infinity, 45.0, 1_800.0),
            (45.0, -1.0, 45.0, 1_800.0),
        ]
    )
    func invalidDirectConfiguration(
        interval: TimeInterval,
        horizon: TimeInterval,
        expectedInterval: TimeInterval,
        expectedHorizon: TimeInterval
    ) {
        let configured = EphemeralSweepPolicy.Configuration(
            interval: interval,
            maximumHorizonAge: horizon
        )
        #expect(configured.interval == expectedInterval)
        #expect(configured.maximumHorizonAge == expectedHorizon)
    }

    @Test("No pending roots wins over every sweep trigger")
    func noPendingRootsWaitsFirst() {
        let decision = EphemeralSweepPolicy.decide(
            input(
                lastSweepAt: nil,
                pendingEphemeralRoots: [],
                activeGuards: [.scan],
                horizonAge: nil,
                navigationRequested: true
            ),
            configuration: configuration
        )
        #expect(
            decision == .wait(reason: EphemeralSweepPolicy.noPendingReason)
        )
    }

    @Test(
        "Each typed active guard waits with its user-facing reason",
        arguments: [
            EphemeralSweepPolicy.ActiveGuard.scan,
            .heavyTask,
            .temporalDiff,
        ]
    )
    func activeGuardWaits(guardKind: EphemeralSweepPolicy.ActiveGuard) {
        let decision = EphemeralSweepPolicy.decide(
            input(
                lastSweepAt: nil,
                activeGuards: [guardKind],
                horizonAge: nil,
                navigationRequested: true
            ),
            configuration: configuration
        )
        #expect(decision == .wait(reason: guardKind.waitReason))
        #expect(!guardKind.waitReason.isEmpty)
    }

    @Test("Guard precedence is scan, heavy task, then temporal diff")
    func guardPrecedenceIsDeterministic() {
        #expect(
            EphemeralSweepPolicy.decide(
                input(activeGuards: [.scan, .heavyTask, .temporalDiff]),
                configuration: configuration
            ) == .wait(reason: EphemeralSweepPolicy.ActiveGuard.scan.waitReason)
        )
        #expect(
            EphemeralSweepPolicy.decide(
                input(activeGuards: [.heavyTask, .temporalDiff]),
                configuration: configuration
            )
                == .wait(
                    reason:
                        EphemeralSweepPolicy.ActiveGuard.heavyTask.waitReason
                )
        )
    }

    @Test("Navigation sweeps before horizon and interval checks")
    func navigationForcesSweep() {
        let decision = EphemeralSweepPolicy.decide(
            input(
                lastSweepAt: 199,
                horizonAge: 1,
                navigationRequested: true
            ),
            configuration: configuration
        )
        #expect(decision == .sweep)
    }

    @Test("Unknown horizon forces a sweep")
    func unknownHorizonForcesSweep() {
        let decision = EphemeralSweepPolicy.decide(
            input(lastSweepAt: 199, horizonAge: nil),
            configuration: configuration
        )
        #expect(decision == .sweep)
    }

    @Test(
        "Horizon forces at its inclusive bound but not immediately below",
        arguments: [
            (1_799.999, false),
            (1_800.0, true),
            (1_801.0, true),
        ]
    )
    func horizonBoundary(age: TimeInterval, shouldSweep: Bool) {
        let decision = EphemeralSweepPolicy.decide(
            input(lastSweepAt: 199, horizonAge: age),
            configuration: configuration
        )
        #expect((decision == .sweep) == shouldSweep)
        if !shouldSweep {
            #expect(
                decision
                    == .wait(
                        reason: EphemeralSweepPolicy.intervalWaitReason
                    )
            )
        }
    }

    @Test("Missing last sweep time forces a sweep")
    func missingLastSweepForcesSweep() {
        let decision = EphemeralSweepPolicy.decide(
            input(lastSweepAt: nil),
            configuration: configuration
        )
        #expect(decision == .sweep)
    }

    @Test(
        "Interval sweeps at its inclusive bound but waits immediately below",
        arguments: [
            (999.999, false),
            (1_000.0, true),
            (1_001.0, true),
        ]
    )
    func intervalBoundary(now: TimeInterval, shouldSweep: Bool) {
        let decision = EphemeralSweepPolicy.decide(
            input(lastSweepAt: 100, now: now),
            configuration: configuration
        )
        #expect((decision == .sweep) == shouldSweep)
        if !shouldSweep {
            #expect(
                decision
                    == .wait(
                        reason: EphemeralSweepPolicy.intervalWaitReason
                    )
            )
        }
    }

    @Test("Zero interval sweeps at the next unguarded opportunity")
    func zeroIntervalSweepsImmediately() {
        let zeroInterval = EphemeralSweepPolicy.Configuration(
            interval: 0,
            maximumHorizonAge: 1_800
        )
        #expect(
            EphemeralSweepPolicy.decide(
                input(lastSweepAt: 200, now: 200),
                configuration: zeroInterval
            ) == .sweep
        )
    }

    @Test("An aged held horizon forces a sweep before a relaunch can lose warm replay")
    func agedHorizonForcesSweepAndReleasesAtomicCache() async throws {
        try await withTemporaryAppSupportDir {
            let (root, cleanup) = try createTempTree([
                "interactive/old.txt": 10,
                "ephemeral/old.txt": 20,
            ])
            defer { cleanup() }

            let interactiveRoot = root + "/interactive"
            let ephemeralRoot = root + "/ephemeral"
            let savedEventId: UInt64 = 100
            let completedSweepEventId: UInt64 = 300
            let configuration = EphemeralSweepPolicy.Configuration(
                interval: 15 * 60,
                maximumHorizonAge: 30 * 60
            )

            let bootstrapTree = FileTree()
            await FileScanner().scan(
                path: root,
                progress: ScanProgress(),
                tree: bootstrapTree
            )
            try TreeCache.save(tree: bootstrapTree, lastEventId: savedEventId)

            try Data(count: 30).write(
                to: URL(fileURLWithPath: interactiveRoot + "/new.txt")
            )
            try Data(count: 40).write(
                to: URL(fileURLWithPath: ephemeralRoot + "/new.txt")
            )

            // Several throttled opportunities retain the previous tree + event id as one
            // checkpoint. No partial tree is ever paired with a newer horizon.
            let throttledAges: [TimeInterval] = [
                60,
                5 * 60,
                10 * 60,
                (15 * 60) - 1,
            ]
            for age in throttledAges {
                let decision = EphemeralSweepPolicy.decide(
                    .init(
                        lastSweepAt: 0,
                        now: age,
                        pendingEphemeralRoots: [ephemeralRoot],
                        activeGuards: [],
                        horizonAge: age,
                        navigationRequested: false
                    ),
                    configuration: configuration
                )
                #expect(
                    decision == .wait(
                        reason: EphemeralSweepPolicy.intervalWaitReason
                    )
                )
                #expect(
                    WarmPatchCacheHorizon.eventIdForPersistence(
                        replayedThrough: completedSweepEventId,
                        deferredTargetCount: 1
                    ) == nil
                )
            }

            let atBound = EphemeralSweepPolicy.decide(
                .init(
                    // Keep the interval unelapsed so this assertion specifically
                    // proves that the cache-horizon bound wins.
                    lastSweepAt: (30 * 60) - 1,
                    now: 30 * 60,
                    pendingEphemeralRoots: [ephemeralRoot],
                    activeGuards: [],
                    horizonAge: 30 * 60,
                    navigationRequested: false
                ),
                configuration: configuration
            )
            #expect(atBound == .sweep)

            let heldCache = try #require(TreeCache.load(for: root))
            #expect(heldCache.lastEventId == savedEventId)
            let sweepReport = await FileScanner().rescanSubtrees(
                [interactiveRoot, ephemeralRoot],
                tree: heldCache.tree,
                progress: ScanProgress(),
                options: .trailing
            )
            #expect(sweepReport.unresolvedPaths.isEmpty)
            #expect(!sweepReport.wasCancelled)

            let persistableEventId = try #require(
                WarmPatchCacheHorizon.eventIdForPersistence(
                    replayedThrough: completedSweepEventId,
                    deferredTargetCount: 0
                )
            )
            try TreeCache.save(
                tree: heldCache.tree,
                lastEventId: persistableEventId
            )

            // Relaunch from the released checkpoint. A replay containing every event newer
            // than the stored horizon is empty, so the planner stays warm instead of
            // poisoning/falling back after an unbounded held window.
            let relaunched = try #require(TreeCache.load(for: root))
            #expect(relaunched.lastEventId == completedSweepEventId)
            let syntheticReplay = JournalReplay(
                outcome: .changes([]),
                newEventId: completedSweepEventId
            )
            #expect(
                WarmStartPlanner.decide(
                    cacheAvailable: true,
                    replay: syntheticReplay.outcome,
                    cachedDirectoryCount: 3,
                    cachedTotalItemCount: relaunched.tree.count,
                    estimatedPatchItems: 0
                ) == .warm(targets: [])
            )

            let freshTree = FileTree()
            await FileScanner().scan(
                path: root,
                progress: ScanProgress(),
                tree: freshTree
            )
            assertTreesEquivalent(
                relaunched.tree,
                freshTree,
                "agedHorizonForcesSweepAndReleasesAtomicCache"
            )
        }
    }
}
