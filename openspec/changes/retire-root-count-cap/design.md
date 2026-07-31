## Context

`WarmStartPlanner.decide` applies three gates in order: `maxPatchRoots` (48, always on), then an item-fraction rule (`maxChangedItemFraction`, 0.25) when the caller supplies `estimatedPatchItems` and `cachedTotalItemCount`, then a directory-fraction rule. The single production call site in `AppState+Scan.swift` supplies all of them, so the item rule is live today; the doc comment claiming otherwise is stale.

The root cap predates `batched-subtree-splice`. Its rationale was that `removeChildren` cost O(total tree) per call, so N roots cost N full-tree recompactions. After batching, one patch costs one compaction regardless of root count.

## Goals / Non-Goals

**Goals:**
- Make the gate reflect what actually predicts cost.
- Keep the protective behaviour: a patch that would lose to a cold scan must still be refused.
- Unblock `throttled-ephemeral-sweep`, whose accumulated roots exceed 48 at every useful interval.

**Non-Goals:**
- Making Phase A enumeration faster (`mount-aware-traversal`, `searchfs-catalog-scan`).
- Changing `unknownDirectoryCountBackstop`, which is pinned to `LiveRefreshPolicy`'s storm threshold.

## Decisions

1. **Item fraction becomes the primary gate; root count becomes a backstop checked after it.** Rationale: measured root counts of 11 and 18 staged 533,000 and 540,000 items respectively, so root count carries almost no information about cost while item count carries nearly all of it. *Alternative considered*: raise 48 to a larger number and keep the ordering. Rejected because ordering is the actual defect: a root-count refusal preempts the rule that knows what the patch costs.

2. **Bound the item estimate rather than trusting it.** `estimatedPatchItemCount` measures the CACHED subtree, so a root that grew since the cache was written is underestimated and slips through. *Alternative considered*: re-check mid-patch once real counts are known and abandon into a cold fallback, reusing `commitWarmStart`'s existing abandonment path. Both are acceptable; task 2.3 picks one on evidence and does not invent a second abandonment mechanism.

3. **Time-accumulated roots are explicitly legitimate.** A throttled sweep accumulates many roots that are individually tiny. The gate must judge those on items, not treat root count as a proxy for staleness. This is what unblocks `throttled-ephemeral-sweep`.

4. **A constant that survives review unchanged is a valid deliverable.** If 0.25 holds up against the model, keep it and record the arithmetic. Churning a constant to look productive is worse than justifying it.

## Risks / Trade-offs

- **The cap currently masks the item gate; removing it exposes any weakness there** → Section 2 hardens and characterises the item gate before section 3 moves any constant.
- **More admitted roots means more Phase A enumeration, the genuinely slow phase** → The item fraction bounds total staged work directly, which is the quantity that matters; task 4.3 asserts that patches which should go cold still do.
- **Boundary tests encode 48 deliberately** → They are updated with intent as part of the change, not adjusted until green.

## Migration Plan

No persisted-format change and no cache `formatVersion` bump. The change is confined to planner constants, their ordering, and the estimate's bound.

## Open Questions

- Whether the bound in decision 2 is best expressed as an inflated estimate for small cached subtrees or as a mid-patch re-check. Task 2.3 decides on the 1.1 data.
