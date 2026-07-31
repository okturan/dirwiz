## Context

`deferred-ephemeral-roots` made the warm patch two-tier: interactive roots splice and publish first, then ephemeral roots sweep on a trailing pass and splice again. `AppState` carries `warmPatchMutatesDisplayedTree` so a superseding scan can detach the displayed tree synchronously before the old scanner commits after cancellation, which would otherwise leave newly renumbered nodes under stale index-keyed UI state.

The failing test exercises the narrow window this machinery exists for: a newer cold scan arrives after the trailing tier has already committed but before its token check runs. The observed result is a tree missing one newly created file from each tier.

Both missing files are NEW. Nothing pre-existing is lost, and the padding directories all survive. That points at an ordering problem around when the tree is snapshotted or detached relative to when the newly enumerated nodes are committed, rather than at a general corruption.

It reproduces only on GitHub's runner. Locally it passes 6 of 6 filtered and was green across 14 full-suite runs at loads 8.2-12.1, so the trigger is a scheduling difference the local machine does not currently produce.

## Goals / Non-Goals

**Goals:**
- Establish whether the tree can genuinely lose newly created files at supersession, and fix it if so.
- Reproduce deterministically, so the fix is verifiable without pushing to CI.
- Return master to green so the 1.2.0 release decision can be made on merit.

**Non-Goals:**
- Revisiting the `ScanSupervisionTests` fix in `8eac839`, which was evidence-based and verified to a precommitted bar.
- Changing the two-tier design itself. If deferral is implicated, that is a finding to report, not a licence to redesign here.

## Decisions

1. **Reproduce deterministically before diagnosing.** The existing `GatedFilesystemProvider` from `8eac839` already provides a way to stop a patch at a chosen point without manufacturing scheduler load. Use it to place the supersession precisely in the window the test names, rather than inferring from CI logs.
   - *Alternative considered*: add retries or push repeatedly and read CI. Rejected: three investigations in this repo have already gone wrong by reasoning from intermittent evidence, and CI round-trips are slow enough to encourage guessing.

2. **Treat "both files are new" as the primary clue.** Pre-existing content survives and only newly created entries vanish, so the investigation starts at the ordering between commit, detach, and token check, not at the splice arithmetic.

3. **Do not weaken `assertTreesEquivalent`.** It was confirmed unchanged by `8eac839`, so the 125-versus-127 discrepancy is real. If the test's own expectations are wrong, the correct outcome is a narrower, still-strict assertion with a written reason, not a looser one.

4. **A test-timing artefact is a legitimate outcome, but it must be proven, not assumed.** The last time an intermittent failure was declared a test problem without capture, the conclusion was one third right.

## Risks / Trade-offs

- **Losing newly created files at supersession is a silent under-reporting bug** → If confirmed, it warrants its own note in CLAUDE.md alongside the firmlink double-count, since both produce quietly wrong totals.
- **Cannot reproduce locally** → Decision 1 makes deterministic reproduction the first task and a STOP if it cannot be achieved, rather than shipping a speculative fix.
- **Fixing the ordering could reintroduce the stale-index problem `warmPatchMutatesDisplayedTree` prevents** → The existing supervision tests must stay green, and the detach guarantee needs its own assertion.

## Migration Plan

No persisted-format change. The fix, if any, is confined to commit and detach ordering in the warm-patch path.

## Open Questions

- Whether the ephemeral and interactive losses share one cause or are two instances of the same ordering bug appearing once per tier. One file from each tier is suggestive of the latter.
