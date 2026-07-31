## Why

`WarmStartPlanner.maxPatchRoots` (48) exists for one reason and its own doc comment names the condition that voids it: `removeChildren` recompacted the whole tree per call, so "**until a batched single-pass splice lands (043)**, many-root patches are structurally slower than a parallel cold scan." That splice landed in `e2d5369` and took structural compaction from 9.14 s across 38 full-tree passes to 0.118-0.164 s in one, making per-root cost effectively constant. The cap is now an arbitrary refusal, it is checked BEFORE the item budget that should be deciding, and it has become the blocking dependency for `throttled-ephemeral-sweep`.

## What Changes

- Gate warm patches on estimated staged items as a fraction of the tree, promoting the existing `maxChangedItemFraction` rule to primary.
- Demote `maxPatchRoots` to a sanity backstop set well above any plausible real patch, and stop checking it before the item budget.
- Bound `estimatedPatchItemCount` so a root that grew since the cache was written cannot silently undershoot the gate.
- Re-derive `maxChangedItemFraction` from the measured model rather than leaving 0.25 as inherited guesswork; keeping 0.25 with stated arithmetic is a valid outcome.
- Log per-root staged item counts.
- Fix `decide`'s doc comment, which wrongly claims no call site supplies the item parameters.
- Update the deliberate boundary tests in `WarmStartTests.swift` and the fixture comments in `ScanSupervisionTests.swift` that pin the old 48.

## Capabilities

### New Capabilities
- `warm-patch-gating`: how the planner decides whether a warm patch is worth attempting, which quantity that decision is based on, and the protective cases the decision must still refuse.

### Modified Capabilities
<!-- None: no existing baseline spec covers the planner's gating decision. -->

## Impact

- The user-visible win is refreshes that currently pay a full ~26 s cold scan staying warm. Root count does not predict cost: 11 roots staged 533,000 items while 18 staged 540,000, so a 48-root cap admits anything from 48 items to millions while refusing a 49-root patch that touches nothing.
- **This now blocks a second change.** `throttled-ephemeral-sweep` measured collapsed roots of 84 at a 1-minute holdback, 99 at 5 minutes and 131 at its derived 15-minute interval. Because `maxPatchRoots` is checked before the item budget, every scheduled sweep at every useful interval would cold-fall back. That change is stopped until this one lands.
- Risk to watch: raising the cap admits more roots, and more roots means more Phase A enumeration, which is the phase that is actually slow. The item gate is what must hold the line, so it has to be correct before the cap moves. A 300-root patch covering 2M of 4.75M items is 42% and must still be refused.
- Do NOT touch `unknownDirectoryCountBackstop` (5,000); it is deliberately the same constant as `LiveRefreshPolicy`'s storm threshold and a test pins that they match.
- Affected code: `Sources/DirWizCore/Scanner/WarmStart.swift`, `Sources/DirWizUI/Models/AppState+Scan.swift`. Affected tests: `WarmStartTests.swift`, `ScanSupervisionTests.swift`.
