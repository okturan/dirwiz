# Throttle the Ephemeral Sweep

## Why

`deferred-ephemeral-roots` (5a35a12) delivered the latency it was specced for and did not
reduce the work. Interactive patch time fell from 2.03 s to 0.635 s on workload 1, but total
throughput across both tiers went the wrong way:

| | items/sec |
| --- | ---: |
| Before, single tier | ~177,000 |
| After, interactive tier | 147,000-164,000 |
| After, trailing tier | 52,000-100,500 |
| After, both tiers combined | **79,000-119,000** |

Total wall clock roughly doubled: workload 2 went from 2.020 s to 4.230 s for comparable work.

The reason is that nothing throttles the trailing tier. It sweeps on EVERY warm patch, and the
per-user Darwin temp root changes every ~10 seconds (measured: 6 mtime changes in 60 s across
12,250 direct children). So DirWiz still re-enumerates ~157,665 temp files continuously. The
cost moved off the critical path without shrinking.

That is a gap in the previous proposal's own reasoning, not in its implementation. It argued
"nobody needs it accurate to the second", which is an argument for doing the work RARELY. It
then specced doing the work LATER, and gated only on interactive-tier latency, so nothing
asked whether total enumeration dropped. It did not.

Deferral was still the correct first step, because it preserved `patched-tree ≡
fresh-cold-scan` while the tiering machinery was proven. That machinery now exists and is
tested. This change spends the guarantee that deferral protected, deliberately and once.

## What Changes

- The ephemeral tier sweeps on a throttled cadence rather than once per patch. Policy lives in
  a pure, clock-injected type (`EphemeralSweepPolicy`) beside `WarmStartPlanner` and
  `LiveRefreshPolicy`, matching how every other scheduling decision in this codebase is made
  testable.
- **The shipped guarantee is amended, not contradicted.** `warm-patch-tiering`'s current
  requirement says the tree equals a fresh cold scan "once the trailing pass completes". That
  becomes "once the throttled sweep runs". The existing requirement is edited in place; two
  requirements that disagree about the same behaviour is worse than a weaker single one.
- Staleness becomes representable rather than implied, reusing `staleViewAsOf` and the
  skipped-directory vocabulary instead of a parallel mechanism.
- Cold scans, the kill switch (`DIRWIZ_NO_EPHEMERAL_DEFER`), and the interactive tier are
  unchanged.

## Impact

- **The cache horizon gets more dangerous, not less, and this is the main risk.** The persisted
  `TreeCache` event id must be held back to the oldest un-swept ephemeral change. Throttling
  widens that window from ~one patch to the full interval, so the next warm start replays a
  correspondingly longer stretch of journal. A long enough interval can push the replay past
  what FSEvents will serve, poison it, and force the cold scan this whole line of work exists
  to avoid. **A throttle that causes cold scans is worse than no throttle.** Bound the
  holdback, and prove the bound.
- Expected win: ephemeral sweeps drop from every patch to roughly one per interval. At a 5
  minute interval against ~10 second churn that is a large reduction in total enumeration, and
  it is the first change in this sequence to reduce work rather than move it.
- Honesty cost: the temp subtree's size is now knowingly stale between sweeps. That is
  acceptable only if it is visible.
- If the analysis concludes the interval wants to be very long, this becomes the "skip" design
  the previous proposal rejected, wearing extra machinery. That is a legitimate finding. Say
  so and propose skipping outright with the gate rescoped honestly, rather than shipping a
  throttle that is a skip in disguise.
- Out of scope: `retire-root-count-cap` (still sequenced after this), `mount-aware-traversal`,
  `searchfs-catalog-scan`.
