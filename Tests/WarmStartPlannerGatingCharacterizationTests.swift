import Testing
@testable import DirWizCore

@Suite("Warm-start planner gating characterization")
struct WarmStartPlannerGatingCharacterizationTests {
    private func roots(_ count: Int) -> [String] {
        (0..<count).map { "/volume/changed-\($0)" }
    }

    @Test("Few large roots warm while their combined estimate stays in budget")
    func fewLargeRootsWithinItemBudgetWarm() {
        let changedRoots = roots(3)

        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(changedRoots),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 1_000_000,
            estimatedPatchItems: 240_000
        )

        #expect(decision == .warm(targets: changedRoots))
    }

    @Test("Many tiny roots above the former cap now warm")
    func manyTinyRootsAboveFormerCapWarm() {
        let changedRoots = roots(49)

        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(changedRoots),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 1_000_000,
            estimatedPatchItems: 49
        )

        #expect(decision == .warm(targets: changedRoots))
    }

    @Test("One huge root hits the item-fraction gate")
    func oneHugeRootHitsItemFractionGate() {
        let changedRoots = roots(1)

        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(changedRoots),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 1_000_000,
            estimatedPatchItems: 900_000
        )

        #expect(
            decision
                == .coldFallback(
                    reason: "~90% of files changed since last scan"
                )
        )
    }

    @Test("An empty change set is a zero-target warm start")
    func emptyChangeSetWarms() {
        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes([]),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 1_000_000,
            estimatedPatchItems: 0
        )

        #expect(decision == .warm(targets: []))
    }

    @Test("Item fraction reports before root count when both gates fail")
    func itemFractionReasonWinsCombinedFailure() {
        let changedRoots = roots(49)

        // A custom backstop keeps this a combined failure even after the production
        // default moved: both 49 > 48 and 900,000 > 25% of 1,000,000.
        #expect(
            WarmStartPlanner.decide(
                cacheAvailable: true,
                replay: .changes(changedRoots),
                cachedDirectoryCount: 1_000,
                cachedTotalItemCount: 1_000_000,
                estimatedPatchItems: 900_000,
                maxPatchRoots: 48
            )
                == .coldFallback(
                    reason: "~90% of files changed since last scan"
                )
        )
    }

    @Test("A many-root oversized patch is refused by item fraction")
    func manyRootOversizedPatchUsesItemFractionReason() {
        let changedRoots = roots(84)

        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(changedRoots),
            cachedDirectoryCount: 1_000,
            cachedTotalItemCount: 1_000_000,
            estimatedPatchItems: 300_000
        )

        #expect(
            decision
                == .coldFallback(
                    reason: "~30% of files changed since last scan"
                )
        )
    }

    @Test("The proposal's 300-root 42% protective case stays cold")
    func proposalProtectiveCaseStaysCold() {
        let changedRoots = roots(300)

        let decision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: .changes(changedRoots),
            cachedDirectoryCount: 10_000,
            cachedTotalItemCount: 4_750_000,
            estimatedPatchItems: 2_000_000
        )

        #expect(
            decision
                == .coldFallback(
                    reason: "~42% of files changed since last scan"
                )
        )
    }
}
