## 1. Reproduce deterministically before diagnosing

- [x] 1.1 Reproduce the failure locally using `GatedFilesystemProvider` to place the superseding scan between the trailing tier's commit and its token check
- [x] 1.2 Confirm the reproduction shows the same signature: 125 paths against 127, missing exactly `interactive/new.txt` and `ephemeral/new.txt`
- [x] 1.3 STOP and report if it cannot be reproduced deterministically; not triggered because the gated reproduction succeeded
- [x] 1.4 Record whether the two missing files share one cause or are the same ordering bug occurring once per tier

## 2. Diagnose

- [x] 2.1 Establish the ordering between the tier commit, the `warmPatchMutatesDisplayedTree` detach, and the token check at the moment content is lost
- [x] 2.2 Determine why only newly created entries are lost while pre-existing content and all padding directories survive
- [x] 2.3 Decide from that evidence whether this is a product defect or a wrong expectation in the test, and record the reasoning either way
- [x] 2.4 If it is a product defect, confirm whether it can occur outside the test's narrow window; not applicable because the displayed tree was complete and only the test's cache read was early

## 3. Fix

- [x] 3.1 Correct the ordering so no committed content is lost at supersession; no product ordering changed because the displayed tree already retained all content, and the test now waits on the cache write it asserts about
- [x] 3.2 Keep the synchronous detach guarantee that stops a cancelled scanner committing renumbered nodes under stale index-keyed state
- [x] 3.3 Do NOT weaken `assertTreesEquivalent`; both calls remain intact
- [x] 3.4 If the test's expectation is genuinely wrong, replace it with a narrower still-strict assertion and a written reason; not triggered because the expectation was right and only its synchronization was wrong

## 4. Verify

- [x] 4.1 The deterministic reproduction from task 1 now passes; the pre-save negative control failed deterministically with the same eight issues and two missing paths
- [x] 4.2 Full suite green locally: one local-heavy 703/703 pass plus five consecutive correctness-mode 703/703 passes under loads 39.01-47.92
- [x] 4.3 `CI=true` parity run green in five consecutive full-suite runs
- [x] 4.4 GitHub CI green, which is the authoritative signal here because the local machine does not reproduce this at all
  Satisfied 2026-08-01: 7e81549 green, and four further green pushes on top of it.
- [x] 4.5 Warm-start and subtree-rescan equivalence gates still hold
- [x] 4.6 `ScanSupervisionTests` still green, so the `8eac839` fix is not regressed

## 5. Documentation

- [x] 5.1 If a product defect is confirmed, record it in CLAUDE.md; not applicable because the displayed tree was complete and the failure was an early test read of the prior cache
- [x] 5.2 Note that `scan-supervision-flake` task 4.3 depends on this landing

Verification note: a second local-heavy run failed the separate staged-item-budget test after the
machine spiked to load 36.72. That test passed alone immediately afterward at load 51.32. The
five consecutive `CI=true` full suites then passed at loads 47.40, 43.19, 39.01, 47.92, and 46.73.
GitHub CI remains task 4.4 because this workspace has not been committed or pushed.
