> **STOPPED AFTER DEPENDENCY RESOLUTION (2026-07-31).**
>
> `retire-root-count-cap` landed on master as `9431689`. The old 15-minute default is
> superseded by the post-cap production-path remeasurement in `measurement.md`.
>
> Root count no longer blocks the sweep. The item gate now exposes the real bound:
> 10-, 15-, and 30-minute holdbacks fell back cold at approximately 79%, 76%, and
> 82% of cached items. Five minutes was non-repeatable (one warm sample, one 79%
> cold fallback). Four one-minute samples stayed warm at 7.0-11.4%, but a direct
> three-sample 30-second run produced two warm patches and one 79% cold fallback.
>
> FSEvents path collapse is non-monotonic under ambient churn, so four green
> one-minute samples do not establish a safe one-minute horizon. Task 1.5 fires:
> there is no repeatedly patchable measured boundary at or above 30 seconds. Any
> shorter boundary remains unmeasured, while retaining one guard-delayed retry would
> require a default below 15 seconds. That is too close to the existing 10-second
> cadence to justify the scheduling machinery, especially when a successful combined
> warm patch takes approximately 3.75-4.38 seconds.
> No default interval or forced-sweep horizon is approved.
>
> Sections 2 and 3 remain unchecked and MUST NOT resume under this scheduling-only
> design. A follow-up must first separate already-applied interactive roots from the
> held ephemeral horizon, or provide an equivalent proof that a sweep cannot replay
> a high-level non-ephemeral root into the item gate. The red
> `wip/throttled-ephemeral-sweep` branch remains reference only, not a base.

## 1. Derive the interval and horizon bound from measurement

- [x] 1.1 Confirm on an idle machine that `sysctl -n vm.loadavg` is low before taking any timing
- [x] 1.2 Measure the ephemeral tier's current cadence: sweeps per minute, items per sweep, observed churn interval of the temp root
- [x] 1.3 Measure the production replay and planner at holdback ages of 1, 5, 15 and
      30 minutes, recording duration, changed-root count, item fraction, decision,
      and whether replay poisons
- [x] 1.4 Derive the default interval and horizon bound from 1.3 and record the arithmetic in the policy's doc comment
- [x] 1.5 STOP and report if 1.3 shows the safe holdback is too short for the throttle to win anything
- [x] 1.6 STOP and report if the useful interval is so long that this is the rejected skip design, and propose skipping outright with the equivalence gate rescoped

## 2. Hold the cache horizon before adding the throttle

- [ ] 2.1 Write the failing test first: throttle sweeps across a long window, persist, relaunch, assert warm start still succeeds
- [ ] 2.2 Implement the horizon bound as a policy input so an aged horizon forces a sweep
- [ ] 2.3 STOP and report if the bound cannot be held such that warm start survives throttled operation
- [ ] 2.4 Cover quit and cancellation with unswept ephemeral changes outstanding

## 3. Policy and scheduling

- [ ] 3.1 Add `EphemeralSweepPolicy` to DirWizCore, pure and clock-injected, beside `WarmStartPlanner`
- [ ] 3.2 Return `.wait(reason:)` with a user-facing reason string for every withheld sweep
- [ ] 3.3 Re-evaluate guards on each tick so a deferral never latches
- [ ] 3.4 Wire the policy into the existing trailing tier and the always-on live patch without adding splice machinery
- [ ] 3.5 Sweep on navigation into a stale ephemeral subtree
- [ ] 3.6 Represent staleness via `staleViewAsOf` and the skipped-directory vocabulary
- [ ] 3.7 Add the `DIRWIZ_EPHEMERAL_SWEEP_INTERVAL` test override and keep `DIRWIZ_NO_EPHEMERAL_DEFER` working

## 4. Verify

- [ ] 4.1 Report combined items/sec across both tiers, sweeps per minute, and items enumerated per minute, before and after
- [ ] 4.2 Confirm interactive-tier latency does not regress from the 0.635 s baseline
- [ ] 4.3 Confirm warm start survives an end-to-end throttled session, reporting replay duration
- [ ] 4.4 Re-express the `patched-tree ≡ fresh-cold-scan` tests to force a sweep and then assert, rather than loosening them
- [ ] 4.5 Confirm cold-scan totals are byte-identical to before this change
- [ ] 4.6 Run the full suite plus a `CI=true` parity run, stashing to confirm any `ScanSupervisionTests` failure also occurs on master

### Historical pre-cap total-work result - STOP (2026-07-31)

The journal horizon itself is safe: the Release replay stayed fast and unpoisoned through
30 minutes, the bound is a policy input, and the synthetic persist/relaunch gate remained
warm. Neither 1.5 nor 2.3 fired.

The end-to-end production path fails the total-work gate before timing is meaningful.
`performEphemeralSweep` must replay the held checkpoint before advancing its event id, and
routes that complete target set through `WarmStartPlanner.decide`. The planner's unchanged,
always-on `maxPatchRoots` gate is 48. The real holdback measurements produced 84 collapsed
roots after 1 minute, 99 after 5 minutes, and 131 at the derived 15-minute default. Every
useful measured interval through 15 minutes therefore turns the scheduled sweep into a
full cold scan rather than reducing total enumeration.

That is a verification STOP at 4.1 (and would invalidate 4.3), not a cache-horizon failure.
Bypassing or raising `maxPatchRoots` here would partially implement
`retire-root-count-cap` out of sequence and violate this change's "scheduling decision
only" scope. The 30-minute sample collapsed to 18 roots, but using the horizon limit as
the normal interval leaves no retry margin and rests on one non-monotonic ambient sample;
it is not adequate evidence for a production default.

Keep sections 1-3 as preparatory work, stack `retire-root-count-cap` next, then return and
rerun 4.1-4.6 before accepting or shipping either change. No product commit from this
change is safe on its own.

### Post-cap interval re-derivation - STOP (2026-07-31)

The landed planner was remeasured from fresh cold caches on `/`, never from the red
prototype branch. Journal replay remained fast and unpoisoned throughout, but the
item fraction—not root count—became the binding constraint:

| Holdback | Samples | Outcome |
| --- | ---: | --- |
| 30 seconds | 3 | two warm at 8.2-10.5%; one cold at approximately 79% |
| 1 minute | 4 | all warm; 7.0-11.4% of cached items |
| 5 minutes | 2 | one warm at 8.7%; one cold at approximately 79% |
| 10 minutes | 1 | cold at approximately 79% |
| 15 minutes | 1 | cold at approximately 76% |
| 30 minutes | 1 | cold at approximately 82% |

There is no repeatedly patchable measured boundary at or above 30 seconds. The
apparently green one-minute curve did not replicate when the boundary was narrowed:
one direct 30-second sample produced a seven-root change set representing approximately
79% of the cache and correctly chose cold.

The original one-retry derivation would now require a horizon below 30 seconds and a
default below 15 seconds. That provides no measured safety margin and is too close to
the current 10-second cadence to win enough work to justify the throttle. Task 1.5
therefore fires and no production policy is approved. Task 1.6 does not fire: this
did not become the rejected skip design; it failed at the opposite end of the curve.

## 5. Documentation

- [ ] 5.1 Edit CLAUDE.md's existing warm-start section to record the throttle, the interval and horizon bound with their derivation, and that the bound is what stops a throttle causing cold scans
