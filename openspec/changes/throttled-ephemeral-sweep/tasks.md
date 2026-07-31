# Tasks - Throttle the Ephemeral Sweep

## 1. Derive the interval before implementing it

- [ ] 1.1 Measure the ephemeral tier's real cadence today: sweeps per minute, items per sweep,
      and the observed churn interval of the per-user Darwin temp root. The prior diagnostic
      saw ~157,665 items and roughly 10 s churn; confirm on the current machine.
- [ ] 1.2 Measure how journal replay cost grows with holdback age. Replay a journal held back
      1, 5, 15 and 30 minutes and record replay duration, changed-root count, and whether it
      poisons. This is the curve that decides both the interval and the horizon bound, so it
      must be measured rather than assumed.
- [ ] 1.3 Derive and record the default interval and the horizon bound from 1.1 and 1.2, with
      the arithmetic written into the policy's doc comment.
- [ ] 1.4 DECISION POINT: if 1.2 shows the safe holdback is short enough that the throttle wins
      little, STOP and report. If it shows the useful interval is very long, say so and propose
      skipping the ephemeral tier outright with the equivalence gate rescoped honestly. Both are
      legitimate findings and better than shipping a throttle that is a skip in disguise.
- [ ] 1.5 Measure on an idle machine. Check `sysctl -n vm.loadavg` first; load has invalidated
      two rounds of numbers in this repo already.

## 2. The horizon, first, because widening its window is the new risk

- [ ] 2.1 Failing test first: throttle sweeps across a long window, persist, relaunch, and
      assert the warm start still succeeds rather than falling back cold on an over-long replay.
- [ ] 2.2 Implement the horizon bound as a policy INPUT, so an aged horizon forces a sweep
      regardless of interval. Not as a post-hoc clamp.
- [ ] 2.3 STOP CONDITION: if the bound cannot be held such that warm start survives throttled
      operation, stop and report. A throttle that causes cold scans defeats the entire purpose
      of the warm-start line of work.
- [ ] 2.4 Cover interruption: quit or cancellation with unswept ephemeral changes outstanding.

## 3. Policy and scheduling

- [ ] 3.1 `EphemeralSweepPolicy` in DirWizCore, pure and clock-injected, beside
      `WarmStartPlanner` and `LiveRefreshPolicy`. Inputs `(lastSweepAt, now,
      pendingEphemeralRoots, guardsActive, horizonAge)`, returning `.sweep` or
      `.wait(reason:)`. The reason string is user-facing, following the warm-start
      observability discipline that no deferral is silent.
- [ ] 3.2 Wire it into the existing trailing tier. No new splice machinery: the tiering,
      compaction and invalidation from `deferred-ephemeral-roots` are unchanged.
- [ ] 3.3 Sweep-on-navigation into a stale ephemeral subtree.
- [ ] 3.4 Represent staleness via `staleViewAsOf` and the skipped-directory vocabulary, not a
      parallel mechanism.
- [ ] 3.5 `EPHEMERAL_SWEEP_INTERVAL` override for tests; `DIRWIZ_NO_EPHEMERAL_DEFER=1` keeps
      disabling tiering entirely.

## 4. Verify

- [ ] 4.1 THE GATE, and it is total work rather than latency: report combined items/sec across
      both tiers, ephemeral sweeps per minute, and total items enumerated per minute, before
      and after. Latency is already won by the previous change and must not regress, but the
      thing to prove here is that total enumeration actually drops. Report numbers; set no
      absolute target. `batched-subtree-splice`'s `<1s` gate demanded 2x to 3.6x the scanner's
      measured throughput and cost a full implementation cycle.
- [ ] 4.2 Warm start survives throttled operation end to end: relaunch after a throttled
      session and confirm it stays warm, with the replay duration reported.
- [ ] 4.3 Equivalence still has teeth: re-express the `patched-tree ≡ fresh-cold-scan` tests to
      force a sweep and then assert, rather than deleting or loosening them.
- [ ] 4.4 Cold-scan totals byte-identical to before this change.
- [ ] 4.5 Full suite plus `CI=true` parity. If `ScanSupervisionTests` fails, stash and confirm
      master fails identically before attributing it: known load-induced FSEvents flake,
      documented in CLAUDE.md.

## 5. Documentation

- [ ] 5.1 CLAUDE.md, edited into the existing warm-start section rather than appended: the
      ephemeral tier is throttled, the interval and horizon bound and where they came from, and
      that the horizon bound is what keeps a throttle from causing cold scans. That last point
      is the one a future change is most likely to break silently.
