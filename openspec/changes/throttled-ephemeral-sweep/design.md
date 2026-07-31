# Design - Throttle the Ephemeral Sweep

## Context

`deferred-ephemeral-roots` added `EphemeralPaths` (OS-derived classifier, fails open),
`WarmPatchTargetTiers` (interactive/ephemeral partition), `WarmPatchCacheHorizon`, and a
two-tier patch in `AppState+Scan.swift`. The trailing tier runs unconditionally after each
interactive splice. Everything needed to sweep the ephemeral tier already exists; what is
missing is a decision about *when*, which is exactly the shape of `LiveRefreshPolicy`.

## Goals / Non-Goals

**Goals:**
- Reduce total enumeration, not just move it off the critical path.
- No new splice machinery. Policy plus scheduling only.
- Keep the cache horizon correct as its window widens.

**Non-Goals:**
- Changing the interactive tier, `EphemeralPaths` classification, or cold-scan behaviour.
- Making the temp subtree more accurate than it is today. This makes it deliberately less
  fresh, and says so.

## Decisions

1. **Policy in a pure clock-injected type** (`EphemeralSweepPolicy`, DirWizCore), given
   `(lastSweepAt, now, pendingEphemeralRoots, guardsActive, horizonAge)` returning
   `.sweep / .wait(reason:)`. Rationale: `WarmStartPlanner` and `LiveRefreshPolicy` both took
   this shape and both are testable without a filesystem. Ad-hoc checks inside
   `AppState+Scan.swift` are rejected; that file is already dense and this decision needs
   direct tests.
2. **The horizon is an input to the policy, not just an output constraint.** When the held-back
   event id ages past a bound, the policy MUST sweep regardless of interval. This is what stops
   a throttle from silently converting warm starts into cold scans, and it is the reason the
   policy takes `horizonAge` rather than only a timer.
   - *Alternative*: throttle purely on elapsed time and let the horizon fall where it may.
     Rejected: it makes replay length unbounded and the failure is invisible until a user's
     next launch cold-scans for 26 s with no explanation.
3. **Sweep on demand as well as on interval.** Navigating into an ephemeral subtree should
   sweep it, because that is the one moment its freshness has value. This is cheap given the
   tiering already exists and it removes most of the honesty cost.
4. **Default interval chosen from measurement, not taste.** Derive it in task 1 from observed
   churn and replay cost. Record the arithmetic. An interval that survives review with a stated
   reason is the deliverable, not a round number.

## Risks / Trade-offs

- **Widened horizon poisons replay.** Primary risk, mitigated by decision 2 and gated in
  tasks 2.3 and 4.2. If the bound cannot be held, stop.
- **Equivalence weakens.** `patched-tree ≡ fresh-cold-scan` becomes true only after a sweep.
  The equivalence tests must be re-expressed to force a sweep and then assert, so the gate
  still has teeth rather than being deleted.
- **Throttle-as-skip.** If the derived interval is very long, this is the rejected skip design
  with more moving parts. Named in the proposal as a legitimate outcome to report.

## Migration Plan

Single change, no persisted-format change. `EPHEMERAL_SWEEP_INTERVAL` env override for testing;
the existing `DIRWIZ_NO_EPHEMERAL_DEFER=1` kill switch continues to disable tiering entirely.

## Open Questions

- Should `~/Library/Caches` join the ephemeral set? Deliberately left open by
  `deferred-ephemeral-roots` task 1.3 and still unanswered. It is a larger, slower-churning,
  more user-interesting directory, so it may want a different interval rather than the same
  classification.
