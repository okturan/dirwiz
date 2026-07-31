## 1. Derive the interval and horizon bound from measurement

- [ ] 1.1 Confirm on an idle machine that `sysctl -n vm.loadavg` is low before taking any timing
- [ ] 1.2 Measure the ephemeral tier's current cadence: sweeps per minute, items per sweep, observed churn interval of the temp root
- [ ] 1.3 Measure journal replay cost at holdback ages of 1, 5, 15 and 30 minutes, recording duration, changed-root count, and whether replay poisons
- [ ] 1.4 Derive the default interval and horizon bound from 1.3 and record the arithmetic in the policy's doc comment
- [ ] 1.5 STOP and report if 1.3 shows the safe holdback is too short for the throttle to win anything
- [ ] 1.6 STOP and report if the useful interval is so long that this is the rejected skip design, and propose skipping outright with the equivalence gate rescoped

## 2. Hold the cache horizon before adding the throttle

- [ ] 2.1 Write the failing test first: throttle sweeps across a long window, persist, relaunch, assert warm start still succeeds
- [ ] 2.2 Implement the horizon bound as a policy input so an aged horizon forces a sweep
- [ ] 2.3 STOP and report if the bound cannot be held such that warm start survives throttled operation
- [ ] 2.4 Cover quit and cancellation with unswept ephemeral changes outstanding

## 3. Policy and scheduling

- [ ] 3.1 Add `EphemeralSweepPolicy` to DirWizCore, pure and clock-injected, beside `WarmStartPlanner`
- [ ] 3.2 Return `.wait(reason:)` with a user-facing reason string for every withheld sweep
- [ ] 3.3 Re-evaluate guards on each tick so a deferral never latches
- [ ] 3.4 Wire the policy into the existing trailing tier without adding splice machinery
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

## 5. Documentation

- [ ] 5.1 Edit CLAUDE.md's existing warm-start section to record the throttle, the interval and horizon bound with their derivation, and that the bound is what stops a throttle causing cold scans
