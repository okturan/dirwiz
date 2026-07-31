## Context

`deferred-ephemeral-roots` shipped `EphemeralPaths` (OS-derived via `confstr`, fails open), `WarmPatchTargetTiers`, `WarmPatchCacheHorizon`, and a two-tier warm patch. The trailing tier runs unconditionally after every interactive splice. The always-on live-refresh path is a second patch entry point and currently rescans all targets monolithically at a 10-second minimum cadence; measurement confirmed that leaving it unchanged would preserve the dominant recurring temp enumeration and allow its cache write to advance past unswept ephemeral state. All the splice, compaction and invalidation machinery needed here already exists and is tested; what is missing is a decision about *when* to sweep at both entry points, which is the same shape as `LiveRefreshPolicy` and `WarmStartPlanner`.

Measured context: the per-user Darwin temp root holds ~157,665 items across 12,250 direct children and its own mtime changed 6 times in 60 seconds of ordinary idle activity. Phase A enumerates at roughly cold-scan throughput, so this cost cannot be optimised away by better patching, only by doing it less often.

## Goals / Non-Goals

**Goals:**
- Reduce total enumeration, not merely relocate it off the critical path.
- Keep the cache horizon correct as its window widens.
- No new splice machinery; policy and scheduling only.

**Non-Goals:**
- Changing the interactive tier, `EphemeralPaths` classification, or cold-scan behaviour.
- Making the ephemeral subtree fresher. This makes it deliberately less fresh and says so.
- Faster Phase A enumeration, which belongs to `mount-aware-traversal` and `searchfs-catalog-scan`.

## Decisions

1. **Policy in a pure clock-injected type.** `EphemeralSweepPolicy` in DirWizCore taking `(lastSweepAt, now, pendingEphemeralRoots, guardsActive, horizonAge)` and returning `.sweep` or `.wait(reason:)`. *Alternative considered*: inline checks in `AppState+Scan.swift`. Rejected because that file is already dense and this decision needs tests that do not touch a filesystem, which is precisely why `WarmStartPlanner` and `LiveRefreshPolicy` took this shape.

2. **The horizon is a policy INPUT, not a post-hoc clamp.** When the held-back event id ages past its bound, the policy returns `.sweep` regardless of the interval. *Alternative considered*: throttle purely on elapsed time and clamp the persisted id afterwards. Rejected because it leaves replay length unbounded and the failure is invisible until a user's next launch cold-scans for 26 s with no explanation, which is exactly the silent-fallback class `warm-start-observability` exists to prevent.

3. **Interval derived from measurement, not chosen.** Task 1 measures replay cost against holdback age (1, 5, 15, 30 minutes) and the interval falls out of that curve alongside the horizon bound. *Alternative considered*: pick a round number like 5 minutes and tune later. Rejected because the deciding constraint is replay poisoning, which is not guessable from churn rate alone.

4. **Sweep on navigation as well as on interval.** Entering a stale ephemeral subtree sweeps it. This is cheap given the tiering exists and removes most of the honesty cost, since the staleness is only user-visible at the moment it gets resolved.

5. **Amend the shipped requirement in place.** `warm-patch-tiering`'s equivalence requirement is edited rather than supplemented. Two requirements disagreeing about the same behaviour is worse than one honestly weaker requirement.

## Risks / Trade-offs

- **Widened horizon poisons journal replay, converting warm starts into cold scans** → Decision 2 makes the horizon force a sweep; task 2 writes the failing test first and carries a STOP if the bound cannot be held. A throttle that causes cold scans is worse than no throttle.
- **Equivalence weakens from "after the trailing pass" to "after a sweep"** → The equivalence tests are re-expressed to force a sweep and then assert, so the gate keeps its teeth instead of being loosened.
- **Throttle-as-skip** → If the derived interval is very long, this is the skip design the previous proposal rejected, wearing extra machinery. Task 1.4 makes that a reportable finding rather than something to ship quietly.
- **Stale sizes shown as current** → Decision 4 plus explicit staleness representation; between sweeps the temp subtree's size is knowingly old, which is acceptable only because it is visible.

## Migration Plan

Single change, no persisted-format change and therefore no cache `formatVersion` bump. `DIRWIZ_EPHEMERAL_SWEEP_INTERVAL` overrides the interval for tests; the existing `DIRWIZ_NO_EPHEMERAL_DEFER=1` continues to disable tiering entirely and is the rollback path.

## Open Questions

- Should `~/Library/Caches` join the ephemeral set? Left open by `deferred-ephemeral-roots` task 1.3 and still unanswered. It is larger, slower-churning and more user-interesting, so it may warrant a different interval rather than the same classification.
