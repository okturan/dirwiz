## Context

Known facts, all measured rather than assumed:

- GitHub CI: 5 failures in the last 25 runs (20%), scattered across history rather than clustered after any one commit. Pattern newest to oldest: `. F F . . . . . . . . F . . F . . . . . F . . . .`
- `bd4061a`, a docs-only commit containing byte-identical code to the failed `162e7f5`, passed. So the same source both fails and passes on CI.
- Locally the failure appears only in full-suite runs, at roughly 50% under load. The same tests pass 5 of 5 filtered.
- Master passes the full suite at loads of 10-13 and fails it at 5-9, so wall-clock load alone does not predict it.
- Assertions seen failing: `ScanSupervisionTests.swift` lines 256, 269, 276, 282, 418, 446, 469, 593, across at least three distinct tests. One `FileNodeGrowthTests.swift:100` timing failure also appeared once at load 8.89 and is separately explainable.
- Two prior instances are already documented in CLAUDE.md, both attributed to FSEvents delivery: `waitForJournalChanges` returning early via the `.poisoned` path when the daemon raises `MustScanSubDirs` after its per-client queue overflows under heavy parallel file creation.

The `MustScanSubDirs` explanation is plausible and partially evidenced, but it has never been confirmed as the cause of every one of these assertions, and some failing lines are not journal waits at all (line 469 asserts hardlink groups survive a patch; line 446 asserts a warm-patch-specific status).

## Goals / Non-Goals

**Goals:**
- Establish the cause with evidence rather than plausibility.
- Leave the suite trustworthy, so a red run means something.
- Preserve every assertion's protective value.

**Non-Goals:**
- Broad test refactoring beyond what the diagnosis requires.
- Revisiting `retire-root-count-cap`'s gating decisions, which landed on evidence and are unrelated.

## Decisions

1. **Diagnose before touching anything.** Three investigations have already begun by assuming a cause. The first section produces evidence and an explicit fork; no fix is written before that fork is resolved.

2. **Instrument the failure rather than infer it.** Capture, at the moment an assertion fails, what the supervision state actually was: whether the journal replay poisoned and with which flag, whether the patch was abandoned and why, and what the published progress status was. Inference from line numbers is what produced three wrong attributions.
   - *Alternative considered*: bisect across commits. Rejected because a 20% rate makes bisection unreliable without an impractical number of runs per step.

3. **A 20% rate sets the verification bar, and it is higher than intuition suggests.** To claim a fix at 95% confidence requires roughly 14 consecutive green full-suite runs, since `0.8^14 ≈ 0.044`. Fewer runs cannot distinguish a fix from luck, and this is precisely the trap that produced the earlier wrong attributions.

4. **If the cause is test infrastructure, robustness must not come from weakened assertions or longer timeouts.** `waitForJournalChanges` already allows 20 seconds and returns in 1.5 via the poison path, so a longer timeout would change nothing. Prefer removing the contention (serialising the suites that generate heavy filesystem churn against each other) over loosening what the tests check.

## Risks / Trade-offs

- **Declaring victory on too few runs** → Decision 3 fixes the required run count in advance, before anyone is invested in a fix.
- **Widening assertions to force green** → These assertions encode bugs that shipped; two are named for the review that caught them. The spec requires each to keep asserting the same guarantee.
- **The cause is a real race and is genuinely hard** → That is the valuable outcome, not the bad one. A supervision race that only appears under contention is exactly the kind of bug that reaches users on slower machines and never reproduces for the developer.

## Migration Plan

No persisted-format change. If the cause is a product race, the fix lands in `AppState`; if it is contention between suites, it lands in test structure.

## Open Questions

- Whether `FileNodeGrowthTests.swift:100`, a timing assertion that failed once at load 8.89, belongs to this investigation or is simply a heavy benchmark that should be gated under `PerformanceSensitiveSuites` like the others.
