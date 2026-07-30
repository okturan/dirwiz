# Batched Subtree Splice

## Why

`FileTree.removeChildren(of:)` (FileNode.swift:1034) rebuilds and renumbers the ENTIRE node
array on every call. The cost is O(total tree), independent of how much is being removed:
roughly 6.2ms on a 200k-node tree, and roughly 100ms per call on a multi-million-node
volume. Warm-start Phase B calls it once per changed root.

Measured on this Mac's boot volume (4,703,194 items, 833,566 directories), headless so no
UI or GPU work is involved:

| Refresh | Result | Time |
| --- | --- | --- |
| 1 | cold fallback (83 changed roots exceeded the 48-root cap) | 21.39 s |
| 2 | genuinely warm, 38 roots | 9.69 s |
| 3 | cold fallback (one changed subtree was ~75% of the tree) | 23.19 s |

The warm run breaks down as 0.50 s cache decode, 0.02 s FSEvents replay, and **9.14 s
patching**. Nearly all of that 9.14 s is 38 full-tree recompactions of a 4.7-million-node
array to replace subtrees that are collectively a rounding error.

The second cost is worse than the first: because per-root splicing is so expensive, the
planner hard-caps warm patches at 48 roots. Two of the three refreshes above fell back to a
full 20-second cold scan for exactly that reason. So today a user routinely pays 20 s where
they should pay about 1 s, and the cap that protects them from a slow patch is what causes
it.

This is the single highest-value performance change available, and it is the number users
meet on every launch. It does not make the cold scan faster; it makes the cold scan rare.

## What Changes

- New Core primitive `FileTree.applyStagedReplacements(_:)`: apply every staged subtree
  replacement in ONE compaction and renumbering pass, so Phase B costs approximately one
  `removeChildren` total instead of one per root.
- `FileScanner`'s Phase B resolves ALL targets by path against a single snapshot FIRST, then
  performs exactly one mutation. This strengthens the existing resolve-before-apply
  discipline rather than weakening it: today's code re-resolves between mutations precisely
  because each mutation renumbers indices, and with one mutation there is nothing to
  invalidate mid-flight.
- `removeChildren`/`installSubtree`/`removeSubtree` keep their current semantics for
  single-root callers (notably the trash path in `TreeActions`), which are out of scope.
- Once the primitive is proven by the gates, raise the planner's `maxPatchRoots` cap so
  ordinary day-to-day churn stays warm. The item-fraction rule remains the real guard
  against patching a subtree that is most of the tree.
- Out of scope: Phase A staging, any other planner rule, the cold scan path, bundle sizing.

## Impact

- Warm start goes from 9.69 s to roughly cache decode plus real enumeration, so about 1 s.
- Refreshes that currently fall back cold because of the root cap stay warm, which converts
  20 s into that ~1 s for the common case.
- Risk is HIGH and concentrated in one place: this is index compaction, the most dangerous
  code in the app, and any index held across it is garbage. The mitigation already exists
  and is absolute: `SubtreeRescanTests`, `WarmStartTests` and `AppliedChangesTests` pin
  patched-tree ≡ fresh-cold-scan equivalence. Those suites are the judge, and they must pass
  unmodified apart from progress-text pins that legitimately changed.
- Memory: peak is old array + new array + staged trees, the same order as `removeSubtree`
  today. Record the real numbers rather than predicting them.
