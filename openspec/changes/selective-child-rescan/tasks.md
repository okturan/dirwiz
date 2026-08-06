## 1. Characterize before changing anything

- [x] 1.1 Pin current behaviour: a directory-level event on a directory with a large subtree
  today stages the whole subtree, and the estimator charges `subtreeItemCount` for it.
- [x] 1.2 Record the measured incident this change targets: ~1,300 changed locations,
  "~84% of files changed since last scan", cold fallback of 30-45 s at multiple cores while
  genuine churn was a few percent.

## 2. Level diff as a pure function

- [x] 2.1 Add a pure `DirectoryLevelDiff` in DirWizCore taking cached children and freshly
  read entries, returning unchanged / added / removed / type-changed sets.
- [x] 2.2 Match the tree's existing case discipline; a case-only rename counts as changed,
  never as unchanged-with-metadata.
- [x] 2.3 Unit tests for every combination including empty-both, empty-cached, empty-fresh,
  type flips (file↔directory, plain↔bundle), and pure metadata changes.

## 3. Partial mutation primitive

- [ ] 3.1 Extend `FileTree` with a transactional "within these targets, remove these child
  subtrees, install these staged subtrees, keep the rest" primitive resolved against ONE
  pre-mutation snapshot.
- [ ] 3.2 Express the existing whole-subtree replacement as its degenerate case (every cached
  child removed) so one code path stays under test.
- [ ] 3.3 Prove cancellation before commit leaves the tree byte-for-byte unchanged.
- [ ] 3.4 Keep aggregate repair after commit; never call `propagateSizes()` on an already
  propagated tree.

## 4. Route every directory target through the diff

- [ ] 4.1 Make Phase A0's level read the entry point for directory-event targets, not just
  file-derived ones.
- [ ] 4.2 Replace promotion-to-full-subtree with the level diff: enumerate only added
  entries, remove only vanished ones, update the rest in place.
- [ ] 4.3 Drop staged targets nested beneath a removed entry as covered.
- [ ] 4.4 Keep bundles on opaque sizing, and keep mount-boundary and firmlink gating on every
  newly descended entry.
- [ ] 4.5 Apply the same treatment to the living view's accumulated directory events (shared
  `rescanSubtrees` path) and confirm no separate wiring is needed.

## 5. Estimation and admission

- [ ] 5.1 Charge every collapsed root its direct child count in
  `WarmStartPlanner.estimatedPatchItemCounts`.
- [ ] 5.2 Keep the pre-staging promotion budget and the exact post-Phase-A staged-item guard
  as the two real measurements; keep their reason strings honest.
- [ ] 5.3 Planner tests: the measured incident shape is admitted warm, and a genuine mass
  change still falls back cold.

## 6. Equivalence gates (acceptance criteria)

- [ ] 6.1 Addition-only, removal-only, type-change, and mixed diffs each equal a fresh cold
  scan.
- [ ] 6.2 Untouched siblings are provably untouched: a recording filesystem provider asserts
  no directory inside an unchanged child was listed during the patch.
- [ ] 6.3 Root-level level-diff equals a fresh cold scan.
- [ ] 6.4 Multi-target batch (several directories each adding, removing, and retaining)
  equals a fresh cold scan in one compaction.
- [ ] 6.5 Hardlink flags and bundle sizes survive in-place metadata updates.
- [ ] 6.6 Real-FSEvents fixture: a created directory and a deleted directory each produce the
  expected diff, using the established wait-for-complete-shape discipline and the 20 s
  ceiling.

## 7. Verification and delivery

- [ ] 7.1 Run focused, full, `CI=true`, strict OpenSpec, and diff hygiene verification.
- [ ] 7.2 Measure on the real volume: warm-start decision, per-root estimated vs actual staged
  counts, patch wall time, and memory peak; report the numbers and STOP with them if a patch
  that should be warm still falls cold.
- [ ] 7.3 Commit, install, relaunch, and confirm from `WarmStartHistory` that launches which
  previously fell cold now record a warm patch.
- [ ] 7.4 Update CLAUDE.md with the new reconciliation shape and its landmines (partial
  mutation transactionality, reliance on FSEvents poison flags, case discipline).
