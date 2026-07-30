# Tasks - Batched Subtree Splice

## 1. Characterize before changing anything

- [ ] 1.1 Add a `.serialized` timing test under `PerformanceSensitiveSuites` that builds a
      ~200k-node tree via `@testable` internals (no real filesystem), stages ~60 synthetic
      replacements, and records today's per-root Phase B wall time as the baseline the
      rework must beat. Print the number; do not assert on it yet.
- [ ] 1.2 Pin the current Phase B progress text in a test, so a later deliberate change to
      it is visible as an intentional edit rather than silent drift.

## 2. The batched primitive (DirWizCore)

- [ ] 2.1 `FileTree.applyStagedReplacements([(target: UInt32, staged: FileTree)])`: validate
      the batch (targets in bounds; no target a descendant of another - Phase B input is
      outermost-deduped already, but assert defensively rather than trusting it)
- [ ] 2.2 Mark all descendants of all targets in ONE shared bitvector. A `Set<UInt32>` at
      4.7M scale is the wrong structure; use `[Bool]` or a packed bitvector.
- [ ] 2.3 Single rebuild pass: copy survivors in order building `oldToNew`; after copying
      each target node, append its staged children with staged-local indices remapped to
      absolute positions and staged name bytes appended to the pool with rebased offsets.
      Generalize `installSubtree`'s existing remapping rather than duplicating it.
- [ ] 2.4 Rewrite every parent/first-child link through `oldToNew`, invalidate the search
      index, and leave `recomputeAggregates()` to the caller exactly as today. Never call
      `propagateSizes()` on an already-propagated tree.
- [ ] 2.5 Unit tests on hand-built trees: two targets where one staged tree is large;
      adjacent-sibling targets; a target whose staged tree is EMPTY (directory emptied);
      a 100-target scatter; a target at the array's last index.

## 3. Phase B rework (DirWizCore)

- [ ] 3.1 Resolve all targets by path against one snapshot, build the batch, call the
      primitive once. Document why resolve-once-then-single-mutation is stronger than
      today's resolve-between-mutations, so the discipline is not misread as relaxed.
- [ ] 3.2 Preserve the existing abandonment rules verbatim: unresolved paths, or any target
      collapsing to the tree root, still abandon the patch for a cold scan rather than
      publishing a half-applied tree.
- [ ] 3.3 Keep cancellation responsive. One long pass must still observe cancellation at a
      sane cadence, and a cancelled patch must leave the tree either untouched or coherent,
      never half-spliced.
- [ ] 3.4 Progress reporting: either publish during staging validation or emit one honest
      "Applying N folders" step. Update the pin from 1.2 deliberately.

## 4. Gates (all absolute)

- [ ] 4.1 `SubtreeRescanTests`, `WarmStartTests`, `AppliedChangesTests` green with no edits
      beyond justified progress-text pins. These are the equivalence gates; a failure here
      is a STOP, not a test to adjust.
- [ ] 4.2 Turn 1.1 into an assertion: batched Phase B must be within a small multiple of a
      single `removeChildren` on the same tree, pinning the O(tree) property rather than a
      flaky absolute time.
- [ ] 4.3 Real-volume measurement with the headless harness: re-run the three-refresh
      sequence on `/` and record the table. Warm patch must drop from 9.14 s to under 1 s.
      Report the actual numbers including memory peak, and STOP with them if it misses.
- [ ] 4.4 Full suite three times plus one CI-parity run, to catch order-dependence in a
      change that renumbers the whole index.

## 5. Raise the cap (last, and only if 4.3 passed)

- [ ] 5.1 Raise `maxPatchRoots` from 48, citing this change's measured numbers in the doc
      comment. Update the boundary tests deliberately.
- [ ] 5.2 Re-run the three-refresh sequence and confirm the refreshes that previously fell
      back cold now stay warm. That, not the patch time alone, is the user-visible win.
