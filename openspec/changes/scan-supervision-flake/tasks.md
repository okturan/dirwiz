## 1. Diagnose before changing anything

- [x] 1.1 Reproduce under full-suite load and confirm the same tests pass filtered, establishing that contention is required
- [x] 1.2 Instrument the failure path to capture supervision state at the moment an assertion fails: journal replay outcome and poison flag, patch abandonment and reason, published progress status
- [x] 1.3 Collect at least ten captured failures and group them by captured cause rather than by line number
- [x] 1.4 Determine whether every failing assertion shares one cause or whether several distinct problems are being conflated
- [x] 1.5 Check whether `FileNodeGrowthTests.swift:100` belongs here or is simply an ungated timing benchmark that should sit under `PerformanceSensitiveSuites`

Task 1.1 disproved its proposed discriminator on this machine. On byte-identical `bd4061a`, a
`CI=true` full-suite run at `vm.loadavg={ 4.96 3.96 3.60 }` failed at
`ScanSupervisionTests.swift:469`. Six filtered runs of the same test were also intermittent: three
passed and three failed at line 469. Full-suite contention may change the rate or expose other
assertions, but it is not required for this manifestation. The 25-run GitHub history likewise has
five failures scattered across identical source, so a same-source green is not contrary evidence.

Task 1.2 adds observation-only `ScanSupervisionTrace` breadcrumbs at the app's actual replay,
planner, abandonment, and cold-handoff boundaries. The three affected tests now attach those
breadcrumbs plus preflight replay outcome, exact progress flags/text, hardlink group/running state,
summary, and warm-start history to their existing assertions. Assertion conditions and all timeout
values are unchanged.

Tasks 1.3–1.4 captured 15 failures in 24 filtered hardlink-supervision runs, then five more
instrumented full-suite runs. The filtered failures all had a clean 40-path preflight and app
replay, warm admission, mid-patch abandonment (`~597% of files changed since last scan`), coherent
cold fallback, and `hardlinks={groups=0, running=true}` when terminal scan progress was sampled.
The protected false-empty UI state is `groups=0 && running=false`; none of these captures entered
it. The matching cancellation test passed 20/20 filtered.

The five full-suite runs proved that several causes were conflated:

- Four preflight journal waits poisoned with `MustScanSubDirs`. In three of those, the app's later
  replay was clean and the warm plan proceeded, so the helper assertion was independently false-red.
- The terminal hardlink assertion raced the visible detached recomputation described above.
- In one run the app replay itself also poisoned. The app coherently recorded
  `change journal unavailable` and fell back cold, but the test continued after its non-fatal
  preflight `#expect` and applied warm-only assertions to subsequent cold/full-rescan state.

Task 1.5 is separate: `FileNodeGrowthTests.swift:100` measures an absolute wall-clock ratio in a
top-level `.serialized` suite. It has no FSEvents, AppState, or scan-supervision dependency and
belongs under `PerformanceSensitiveSuites`; its one loaded-run failure is not part of this flake.

## 2. The fork

- [x] 2.1 Decide from the 1.3 evidence whether the cause is test infrastructure or a genuine supervision race, and record the reasoning
- [x] 2.2 If it is a real race, STOP and report before fixing; a product race in warm-patch supervision is a larger finding than a flaky test and deserves its own review
- [x] 2.3 If it is test infrastructure, confirm the mechanism specifically rather than assuming the documented `MustScanSubDirs` explanation covers all of it, since some failing assertions are not journal waits

### Fork decision: test infrastructure, not a product race

No capture shows a supervision guarantee violation. A real stale warm view was never observed with
empty hardlink groups and no recomputation; app-level journal poison always took the documented cold
fallback with a recorded reason. The failures come from ambient FSEvents queue poison, a fixture
that outgrows warm eligibility after staging, and tests that continue or sample before their own
required async postcondition. Task 2.2 is complete as not applicable: the STOP branch did not fire.

## 3. Fix, according to the fork

- [x] 3.1 If a product race: fix it in `AppState` and add a test that fails reliably without it
- [x] 3.2 If contention: remove the contention, preferring to serialise the suites generating heavy filesystem churn over loosening assertions
- [x] 3.3 Do NOT extend `waitForJournalChanges`'s timeout; it already allows 20 seconds and returns in about 1.5 via the poison path, so a longer timeout changes nothing
- [x] 3.4 Do NOT widen any assertion; each must keep asserting the same guarantee, since two are named for the review that caught the bugs they protect against

Task 3.1 is not applicable because the fork found no product race. For task 3.2, supervision tests
now inject their journal outcome, stage 160 items below the unchanged 170-item guard, and use a
filesystem gate for deterministic warm-patch timing instead of creating 4,000 files. A dedicated
injected-`MustScanSubDirs` test pins the coherent cold fallback and recorded reason. The unrelated
wall-clock `FileNodeGrowthTests` suite now lives under `PerformanceSensitiveSuites`. The two
ultrareview assertion predicates are byte-for-byte unchanged; the final group-count check now waits
for the already-visible hardlink recomputation to finish. `waitForJournalChanges` remains at 20 s.

## 4. Verify to a standard the failure rate justifies

- [x] 4.1 Run the full suite 14 consecutive times with zero failures, since a 20% rate gives `0.8^14 ≈ 0.044`, and fewer runs cannot distinguish a fix from luck
- [x] 4.2 Run under deliberate contention, not only on a quiet machine, since contention is the trigger
- [x] 4.3 Confirm GitHub CI green across at least five consecutive pushes
  Satisfied 2026-08-01: five consecutive green pushes on master - 8a4be41, 7e81549, a6c97a3, 046dd0b, 7100f9a.
- [x] 4.4 Confirm the protective value survives: temporarily reintroduce a supervision violation and assert the tests still catch it

Task 4.3 is blocked on `warm-patch-supersession-equivalence` landing. The first post-fix push was
red only because that separate test read the previous atomic cache before the superseding cold
scan's asynchronous cache write finished; the scan-supervision assertions themselves stayed green.

Fourteen consecutive `CI=true swift test --skip-build --quiet` runs passed 703/703 tests in 101
suites. A separate full-suite run passed 703/703 while a finite `/tmp` worker created and explicitly
unlinked 30,000 files; starting load was `{ 6.85 5.92 5.38 }`. For task 4.4, temporarily removing
the preserving-warm `refreshHardlinkGroups()` call made the unchanged ultrareview test fail with
`stale=true`, a live warm patch, and `hardlinks={groups=0, running=false}`. Restoring the line made
the same test green. Task 4.3 remains external until commits are pushed through five CI runs.

## 5. Documentation

- [x] 5.1 Replace CLAUDE.md's current flake note with the established cause, since that note attributes it to `MustScanSubDirs` and that has never been confirmed for every affected assertion
- [x] 5.2 Record that this cost three misattributed investigations, so a future one does not re-derive it
