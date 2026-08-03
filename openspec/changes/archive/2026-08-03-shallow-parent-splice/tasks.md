## 1. Evidence and design

- [x] 1.1 Attribute the persistent cold fallbacks from WarmStartHistory (~92% on `/`, ~26% on
  Samsung8TB) and a live journal probe: file-derived giant parents (`/Users/okan` from
  `.DS_Store`, `/` from root-level files) inflate the estimate and trip the root abandon.
- [x] 1.2 Record the design: kind-tagged targets, shallow one-level reconcile with in-place
  metadata updates, promotion on structural change, kind-aware collapse, honest estimates,
  root-level shallow reconciliation, and the same scoping for live applies.

## 2. Core implementation

- [x] 2.1 Tag file-only targets in `JournalCollector` and surface them as
  `JournalReplay.fileOnlyTargets` without changing the `Outcome` shape.
- [x] 2.2 Add kind-aware `PathCollapse.outermostRoots(_:shallow:)`: only deep roots claim
  descendants; duplicate paths dedupe with deep winning.
- [x] 2.3 Estimate shallow roots at `max(1, cached childCount)` in
  `WarmStartPlanner.estimatedPatchItemCounts`; thread the shallow set through `decide`.
- [x] 2.4 Implement Phase A0 in `rescanSubtrees`: one-level enumeration for shallow plans,
  (name, type) comparison against cached children, in-place update emission, and promotion
  including nested-target dropping and the root-level rules.
- [x] 2.5 Add `FileTree.updateNodeMetadata` (non-structural fields only) and apply in-place
  updates in Phase B before any compaction.
- [x] 2.6 Tag and merge kinds in the live monitor accumulation; forward the shallow set from
  `applyAccumulatedChanges`.
- [x] 2.7 Thread `fileOnlyTargets` through AppState's warm decision, estimate logging, and
  both rescan tiers.

## 3. Gates

- [x] 3.1 Collapse and planner unit tests: shallow roots claim nothing, deep wins duplicates,
  shallow estimates use child counts, the probe's incident shape is admitted warm.
- [x] 3.2 Equivalence gates: metadata-only shallow ≡ cold with child subtrees provably not
  re-enumerated; structural promotion ≡ cold; root-level shallow ≡ cold; shallow root plus
  nested deep target ≡ cold.
- [x] 3.3 Real-FSEvents tagging test: a file touched directly in a fixture root yields a
  file-only target; a created directory yields a directory-event target.
- [x] 3.4 Run focused, full, `CI=true`, strict OpenSpec, and diff hygiene verification.

## 4. Delivery

- [x] 4.1 Update CLAUDE.md's warm-start section with the shallow/deep distinction and the
  new landmines.
- [x] 4.2 Commit, install, relaunch, and verify on the real volume: the launch decision and
  WarmStartHistory should finally record a warm start, with the reason line naming honest
  numbers.

## 5. Recorded residuals (verified live, Aug 3)

- [x] 5.1 Launch 1 after install: cold with "change journal timed out" - the 26-hour replay
  window over the session's test churn legitimately exceeds the 10s ceiling; designed behavior.
- [x] 5.2 Launch 2: the estimate gate ADMITTED the patch (estimator fix confirmed), but one
  promotion staged ~82% of the tree before the exact post-Phase-A guard abandoned it. Residual:
  a structural change at a giant root's own level still costs stage-then-abandon; next step is
  either a pre-staging promotion budget (cheap abandon) or adoption grafts in
  `applyStagedReplacements` (replace one level, reuse child subtrees in the same compaction).
- [x] 5.3 Launch 3: WARM - interactive tier 36 roots / 96,653 staged items / 0.599s, per-root
  estimates matching actuals within a few items, trailing tier completed; WarmStartHistory
  recorded `wasWarm: true` at 1.15s for 4,588,652 items versus 25-46s cold scans.
- [x] 5.4 Observability gap found while diagnosing launch 2: per-root estimated/actual staged
  counts log at `.info`, which does not persist to the log store - post-hoc attribution needed a
  live `log stream`. Consider `.notice` for the per-root lines if this recurs.
