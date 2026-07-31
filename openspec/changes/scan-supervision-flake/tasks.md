## 1. Diagnose before changing anything

- [ ] 1.1 Reproduce under full-suite load and confirm the same tests pass filtered, establishing that contention is required
- [ ] 1.2 Instrument the failure path to capture supervision state at the moment an assertion fails: journal replay outcome and poison flag, patch abandonment and reason, published progress status
- [ ] 1.3 Collect at least ten captured failures and group them by captured cause rather than by line number
- [ ] 1.4 Determine whether every failing assertion shares one cause or whether several distinct problems are being conflated
- [ ] 1.5 Check whether `FileNodeGrowthTests.swift:100` belongs here or is simply an ungated timing benchmark that should sit under `PerformanceSensitiveSuites`

## 2. The fork

- [ ] 2.1 Decide from the 1.3 evidence whether the cause is test infrastructure or a genuine supervision race, and record the reasoning
- [ ] 2.2 If it is a real race, STOP and report before fixing; a product race in warm-patch supervision is a larger finding than a flaky test and deserves its own review
- [ ] 2.3 If it is test infrastructure, confirm the mechanism specifically rather than assuming the documented `MustScanSubDirs` explanation covers all of it, since some failing assertions are not journal waits

## 3. Fix, according to the fork

- [ ] 3.1 If a product race: fix it in `AppState` and add a test that fails reliably without it
- [ ] 3.2 If contention: remove the contention, preferring to serialise the suites generating heavy filesystem churn over loosening assertions
- [ ] 3.3 Do NOT extend `waitForJournalChanges`'s timeout; it already allows 20 seconds and returns in about 1.5 via the poison path, so a longer timeout changes nothing
- [ ] 3.4 Do NOT widen any assertion; each must keep asserting the same guarantee, since two are named for the review that caught the bugs they protect against

## 4. Verify to a standard the failure rate justifies

- [ ] 4.1 Run the full suite 14 consecutive times with zero failures, since a 20% rate gives `0.8^14 ≈ 0.044`, and fewer runs cannot distinguish a fix from luck
- [ ] 4.2 Run under deliberate contention, not only on a quiet machine, since contention is the trigger
- [ ] 4.3 Confirm GitHub CI green across at least five consecutive pushes
- [ ] 4.4 Confirm the protective value survives: temporarily reintroduce a supervision violation and assert the tests still catch it

## 5. Documentation

- [ ] 5.1 Replace CLAUDE.md's current flake note with the established cause, since that note attributes it to `MustScanSubDirs` and that has never been confirmed for every affected assertion
- [ ] 5.2 Record that this cost three misattributed investigations, so a future one does not re-derive it
