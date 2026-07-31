## Why

`ScanSupervisionTests` fails intermittently at roughly 20% (5 of the last 25 GitHub CI runs), and it has now derailed three separate investigations in this repository: it was misread once as a regression from `batched-subtree-splice`, once as a regression from `deferred-ephemeral-roots`, and once as a regression from `retire-root-count-cap`. In the last case it produced a whole spec built on a premise that turned out to be wrong. A failure mode that makes every unrelated change look broken costs more than the bug it hides.

The failure is load-dependent and only appears under full-suite parallel execution; the same tests pass 5 of 5 in isolation. That is usually the signature of a test-infrastructure problem, but these tests cover scan SUPERVISION - warm patches running behind a stale view - so a load-dependent failure could equally be a real race in `AppState` that parallel load merely exposes. Nobody has established which, and that question also gates whether 1.2.0 can ship from current master.

## What Changes

- Determine, with evidence, whether the intermittency is a test-infrastructure artefact or a genuine supervision race. This is the change's purpose; everything else follows from the answer.
- If it is a real race: fix it, because it is a product bug affecting warm patches behind a stale view.
- If it is test infrastructure: make the tests robust without weakening what they assert, since these assertions exist to catch supervision bugs that have shipped before.
- Establish a verification standard adequate to a 20% failure rate, because a handful of green runs cannot distinguish a fix from luck.
- Record the outcome so the next investigation does not re-derive it a fourth time.

## Capabilities

### New Capabilities
- `scan-supervision-under-load`: the guarantees warm-patch supervision must hold when the machine is contended, and how the suite establishes them reliably enough to be trusted.

### Modified Capabilities
<!-- None: no existing baseline spec covers supervision behaviour under contention. -->

## Impact

- Affected code: `Tests/ScanSupervisionTests.swift`, `Tests/TestHelpers.swift` (`waitForJournalChanges`), and potentially `Sources/DirWizUI/Models/AppState+Scan.swift` and `AppState+Analysis.swift` if the cause is a real race.
- **Gates the 1.2.0 release.** The current release is v1.1.1 from 19 July while the repo is at 1.2.0 build 9, 67 commits ahead. Shipping from master is not advisable while a supervision test fails 20% of the time for unknown reasons.
- Unblocks honest attribution for every future change, which is the larger win. Three investigations have already paid for this.
- Risk: "fixing" it by widening assertions or extending timeouts would convert a visible flake into an invisible gap. The assertions were written because these bugs shipped once; two of them are named `ultrareview bug_002` for that reason.
- No persisted-format change and no cache `formatVersion` bump.
