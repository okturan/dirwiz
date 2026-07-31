## 1. Reproduce deterministically before diagnosing

- [ ] 1.1 Reproduce the failure locally using `GatedFilesystemProvider` to place the superseding scan between the trailing tier's commit and its token check
- [ ] 1.2 Confirm the reproduction shows the same signature: 125 paths against 127, missing exactly `interactive/new.txt` and `ephemeral/new.txt`
- [ ] 1.3 STOP and report if it cannot be reproduced deterministically; do not ship a speculative fix or chase it through CI pushes
- [ ] 1.4 Record whether the two missing files share one cause or are the same ordering bug occurring once per tier

## 2. Diagnose

- [ ] 2.1 Establish the ordering between the tier commit, the `warmPatchMutatesDisplayedTree` detach, and the token check at the moment content is lost
- [ ] 2.2 Determine why only newly created entries are lost while pre-existing content and all padding directories survive
- [ ] 2.3 Decide from that evidence whether this is a product defect or a wrong expectation in the test, and record the reasoning either way
- [ ] 2.4 If it is a product defect, confirm whether it can occur outside the test's narrow window, since that decides whether users can hit it

## 3. Fix

- [ ] 3.1 Correct the ordering so no committed content is lost at supersession
- [ ] 3.2 Keep the synchronous detach guarantee that stops a cancelled scanner committing renumbered nodes under stale index-keyed state
- [ ] 3.3 Do NOT weaken `assertTreesEquivalent`; it was verified untouched by `8eac839`, so the discrepancy is real
- [ ] 3.4 If the test's expectation is genuinely wrong, replace it with a narrower still-strict assertion and a written reason, never a looser one

## 4. Verify

- [ ] 4.1 The deterministic reproduction from task 1 now passes, and fails again if the fix is reverted
- [ ] 4.2 Full suite green locally, run enough times to be meaningful given this repo's history of intermittency
- [ ] 4.3 `CI=true` parity run green
- [ ] 4.4 GitHub CI green, which is the authoritative signal here because the local machine does not reproduce this at all
- [ ] 4.5 Warm-start and subtree-rescan equivalence gates still hold
- [ ] 4.6 `ScanSupervisionTests` still green, so the `8eac839` fix is not regressed

## 5. Documentation

- [ ] 5.1 If a product defect is confirmed, record it in CLAUDE.md beside the firmlink double-count, since both produce quietly wrong totals
- [ ] 5.2 Note that `scan-supervision-flake` task 4.3 depends on this landing
