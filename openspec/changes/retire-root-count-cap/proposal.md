# Retire the Root-Count Cap in Favour of the Item Budget

## Why

`WarmStartPlanner.maxPatchRoots` (default 48) exists for exactly one reason, and its own doc
comment states the condition under which it stops being valid:

> 042's benchmark found `FileTree.removeChildren` recompacts and renumbers the ENTIRE tree on
> every call [...] Phase B calls it once per changed root, so patch cost scales with ROOT
> COUNT regardless of how small each root's own item fraction is [...] **Until a batched
> single-pass splice lands (043)**, many-root patches are structurally slower than a parallel
> cold scan.

That splice landed in `e2d5369`. The precondition is void, and the measurements say so:

| | Before | After |
| --- | --- | --- |
| Structural compaction, real `/` patch | 9.14 s across 38 full-tree passes | **0.118-0.164 s, one pass** |
| Synthetic, 60 replacements | 60 x 7.19 ms | **3.39 ms total** |

Per-root splice cost is now effectively constant, so a cap whose whole justification was
per-root cost is now just an arbitrary refusal to warm.

And it is not a harmless one. It is the gate that actually fires. Two of three real refreshes
fell back to a full ~26 s cold scan on root count alone, while the item-fraction gate they
would have passed sat at 11-14% of its 25% budget. The user pays 26 s where they should pay
about 4 s, and the cap that was supposed to protect them from a slow patch is what causes it.

Root count also does not predict cost, which is the deeper reason it is the wrong gate:

| Roots | Items staged | Patch time |
| --- | --- | --- |
| 11 | 533,000 | 3.583 s |
| 18 | 540,000 | 4.964 s |

Nearly identical work, 64% different root counts. A 48-root cap admits anything from 48 items
to millions, and refuses a 49-root patch that touches nothing.

The right gate already exists and is already wired: `maxChangedItemFraction` (0.25) against
`estimatedPatchItems`, supplied by the real call site in `AppState+Scan.swift`. This change
promotes it to primary and demotes root count to a sanity backstop.

Note that `decide`'s doc comment is now stale on a second point: it claims "every existing
call site" omits the item parameters and therefore gets root-count-only behaviour. One call
site supplies both, so the item rule is live in production today.

## What Changes

- Raise `maxPatchRoots` substantially, or demote it to a backstop set well above any
  plausible real patch, citing the batched-splice numbers in the doc comment. Do NOT delete
  it: many scattered roots still cost per-root Phase A staging and FSEvents attribution even
  when each root is tiny, so some ceiling remains honest.
- Re-derive `maxChangedItemFraction` from measurement instead of leaving 0.25 as inherited
  guesswork. The model confirmed on both real samples is
  `warm ~= cold_seconds * (staged_items / total_items) + 0.15 s`, which predicted 3.12 s and
  3.15 s against actuals of 3.583 s and 4.964 s. Break-even against a cold scan is far above
  0.25; the question is what fraction is worth warming, which is a judgement to make with the
  numbers visible rather than a constant to inherit.
- Log the per-root staged item count. 18 roots covering 540k items means the roots are very
  large directories, and if one root dominates the patch then narrowing attribution is a
  bigger and cheaper win than either remaining throughput spec.
- Fix the stale doc comment.
- Update the deliberate boundary tests in `WarmStartTests.swift` and the two comments in
  `ScanSupervisionTests.swift` that pin fixtures under the old 48.

## Impact

- The user-visible win is refreshes that currently pay a full cold scan staying warm. That,
  not patch time in isolation, is the point.
- Risk, and the thing to watch: raising the cap admits more roots, and more roots means more
  Phase A enumeration, which is the phase that is actually slow. The item gate is what must
  hold the line, so it has to be correct before the cap moves. A 300-root patch covering 2M
  of 4.75M items is 42% and must still be refused.
- Related risk: `estimatedPatchItemCount` estimates from the CACHED tree, so a root that has
  grown enormously since the cache was written will be underestimated and could slip past the
  item gate. Worth bounding.
- Do NOT touch `unknownDirectoryCountBackstop` (5,000) as part of this. It is deliberately the
  same constant as `LiveRefreshPolicy`'s storm threshold and a test pins that they match.
- Out of scope: making Phase A faster. That is `mount-aware-traversal` and
  `searchfs-catalog-scan`.
