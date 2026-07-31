> **BLOCKED (2026-07-31) - do not implement in this order.**
>
> Section 1 is complete and its findings stand: see `measurement.md`. The horizon
> risk this change was designed around does not bind (replay never poisoned through
> a 30-minute holdback, costing 0.15 s there). A different gate blocks it instead.
>
> `WarmStartPlanner.decide` checks `maxPatchRoots` (48) BEFORE its item budget, and
> collapsed roots exceed that at every useful interval: 84 at 1 minute, 99 at 5, and
> 131 at the derived 15-minute default. Every scheduled sweep would therefore cold-
> fall back, which is the outcome this change is required never to cause.
>
> `retire-root-count-cap` must land FIRST. That resequencing corrects an error in
> this proposal and in `deferred-ephemeral-roots`, both of which listed the cap work
> as coming afterwards. The 6/19/7 root counts that justified deprioritising the cap
> were measured on live patches at a ~10-second cadence; throttling to 15 minutes
> accumulates 131.
>
> Sections 2 and 3 are unchecked here because that code is NOT on master. A prototype
> exists on branch `wip/throttled-ephemeral-sweep`, where the full suite is red: the
> root-level-rescan abandonment test fails and master passes the same suite 3/3 at
> higher load, so it is a real regression rather than the documented FSEvents flake.
> Reuse it as reference, not as a base, and re-derive the interval after the cap
> changes, since the cap is what bounds the usable holdback.

## 1. Derive the interval and horizon bound from measurement

- [x] 1.1 Confirm on an idle machine that `sysctl -n vm.loadavg` is low before taking any timing
- [x] 1.2 Measure the ephemeral tier's current cadence: sweeps per minute, items per sweep, observed churn interval of the temp root
- [x] 1.3 Measure journal replay cost at holdback ages of 1, 5, 15 and 30 minutes, recording duration, changed-root count, and whether replay poisons
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

### Total-work result - STOP (2026-07-31)

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

## 5. Documentation

- [ ] 5.1 Edit CLAUDE.md's existing warm-start section to record the throttle, the interval and horizon bound with their derivation, and that the bound is what stops a throttle causing cold scans
