import Testing
import Foundation
@testable import DirWizCore

/// The auto-apply decision. Pure and clock-injected, so every branch is exercised without
/// waiting real seconds — the reason the policy is separate from the coordinator at all.
@Suite("Live Refresh Policy Tests")
struct LiveRefreshPolicyTests {

    private func input(
        pending: Int = 5,
        now: TimeInterval = 1_000,
        lastChange: TimeInterval? = nil,
        lastApplied: TimeInterval? = nil,
        paused: Bool = false,
        scanning: Bool = false,
        canStartHeavy: Bool = true,
        diffActive: Bool = false
    ) -> LiveRefreshPolicy.Input {
        LiveRefreshPolicy.Input(
            pendingCount: pending, now: now, lastChangeAt: lastChange, lastAppliedAt: lastApplied,
            isPaused: paused, isScanning: scanning, canStartHeavyTask: canStartHeavy,
            isTemporalDiffActive: diffActive
        )
    }

    @Test("Nothing pending is idle, never an apply")
    func idleWhenNothingPending() {
        #expect(LiveRefreshPolicy.decide(input(pending: 0)) == .idle)
        // Guards must not turn an empty queue into a deferral — that would show a
        // "deferred" pill with nothing actually waiting.
        #expect(LiveRefreshPolicy.decide(input(pending: 0, paused: true)) == .idle)
        #expect(LiveRefreshPolicy.decide(input(pending: 0, scanning: true)) == .idle)
    }

    // MARK: - Quiescence

    @Test("Changes still arriving wait for silence")
    func quiescenceNotYetReached() {
        let justNow = LiveRefreshPolicy.decide(
            input(now: 1_000, lastChange: 1_000 - (LiveRefreshPolicy.quiescenceSeconds / 2)))
        #expect(justNow == .waitingForQuiescence)
    }

    @Test("Quiescence is satisfied exactly at the boundary")
    func quiescenceBoundary() {
        let atBoundary = LiveRefreshPolicy.decide(
            input(now: 1_000, lastChange: 1_000 - LiveRefreshPolicy.quiescenceSeconds))
        #expect(atBoundary == .apply, "the window is closed at exactly the threshold")

        let justInside = LiveRefreshPolicy.decide(
            input(now: 1_000, lastChange: 1_000 - LiveRefreshPolicy.quiescenceSeconds + 0.01))
        #expect(justInside == .waitingForQuiescence)
    }

    /// A missing timestamp must not block forever — better to apply than to wedge.
    @Test("An unknown last-change time does not stall the loop")
    func missingChangeTimestampApplies() {
        #expect(LiveRefreshPolicy.decide(input(lastChange: nil)) == .apply)
    }

    // MARK: - Minimum interval

    @Test("A recent apply holds off the next one")
    func minimumIntervalEnforced() {
        let tooSoon = LiveRefreshPolicy.decide(
            input(now: 1_000, lastChange: 990,
                  lastApplied: 1_000 - (LiveRefreshPolicy.minimumIntervalSeconds / 2)))
        #expect(tooSoon == .waitingForInterval)

        let longEnough = LiveRefreshPolicy.decide(
            input(now: 1_000, lastChange: 990,
                  lastApplied: 1_000 - LiveRefreshPolicy.minimumIntervalSeconds))
        #expect(longEnough == .apply)
    }

    /// Quiescence is checked before the interval: a burst that is still arriving is
    /// "waiting for quiescence", which is the more accurate thing to tell the user.
    @Test("Quiescence outranks the interval when both would block")
    func quiescenceOutranksInterval() {
        let d = LiveRefreshPolicy.decide(input(now: 1_000, lastChange: 999.5, lastApplied: 999))
        #expect(d == .waitingForQuiescence)
    }

    // MARK: - Storm

    @Test("Crossing the storm threshold stops splicing and recovers below it")
    func stormThresholdCrossingAndRecovery() {
        let over = LiveRefreshPolicy.stormThreshold + 1
        #expect(LiveRefreshPolicy.decide(input(pending: over, lastChange: nil))
                == .storm(pendingCount: over))

        // Exactly at the threshold is still spliceable — the check is strictly greater.
        #expect(LiveRefreshPolicy.decide(input(pending: LiveRefreshPolicy.stormThreshold,
                                               lastChange: nil)) == .apply)
        // And once the set shrinks, normal service resumes with no latch to reset.
        #expect(LiveRefreshPolicy.decide(input(pending: 10, lastChange: nil)) == .apply)
    }

    @Test("The storm threshold matches warm start's own backstop")
    func stormThresholdMatchesWarmStart() {
        // Diverging from warm start's backstop would mean two different answers to
        // "too many changed directories to splice".
        #expect(LiveRefreshPolicy.stormThreshold == 5_000)
    }

    // MARK: - Guards

    @Test("Every guard defers with its own reason")
    func guardsDefer() {
        #expect(LiveRefreshPolicy.decide(input(paused: true)) == .deferred(reason: .paused))
        #expect(LiveRefreshPolicy.decide(input(scanning: true)) == .deferred(reason: .scanning))
        #expect(LiveRefreshPolicy.decide(input(canStartHeavy: false))
                == .deferred(reason: .heavyTaskRunning))
        #expect(LiveRefreshPolicy.decide(input(diffActive: true))
                == .deferred(reason: .temporalDiffActive))
    }

    /// A guard must win over a storm: telling someone to run a full rescan *during* a scan
    /// is nonsense, and mid-scan the pending set is about to be discarded anyway.
    @Test("Guards outrank the storm signal")
    func guardsOutrankStorm() {
        let huge = LiveRefreshPolicy.stormThreshold * 2
        #expect(LiveRefreshPolicy.decide(input(pending: huge, scanning: true))
                == .deferred(reason: .scanning))
        #expect(LiveRefreshPolicy.decide(input(pending: huge, paused: true))
                == .deferred(reason: .paused))
    }

    /// Deferral is not a latch: whatever was pending applies once the guard lifts.
    @Test("Pending changes apply once a guard clears")
    func pendingSurvivesGuardRelease() {
        let blocked = input(pending: 12, lastChange: nil, diffActive: true)
        #expect(LiveRefreshPolicy.decide(blocked) == .deferred(reason: .temporalDiffActive))

        var released = blocked
        released.isTemporalDiffActive = false
        #expect(LiveRefreshPolicy.decide(released) == .apply)
    }
}
