## Context

`retire-root-count-cap` promoted the item-fraction rule to the primary warm-patch gate and, because that gate's input is an estimate derived from the cached tree, added a mid-patch guard that counts items as they are actually staged. `AppState+Scan.swift` computes `maximumStagedItemCount = cachedTotalItemCount * 0.25`, threads a `remainingStagedItemCount` through `SubtreeRescanOptions`, and accumulates `cumulativeStagedItemCount` across the interactive and trailing tiers.

The guard is necessary. Content created since the cache was written is invisible to the up-front estimate, so without a measured check a subtree that grew without bound would carry an arbitrarily large patch past the gate. That is the exact hole its task 2.3 identified.

What is wrong is not that the guard exists but what it does when it trips, and which quantity it compares against.

## Goals / Non-Goals

**Goals:**
- Keep the protection: a patch that would genuinely lose to a cold scan is still refused.
- Never abandon a patch that is already cheaper to finish than to restart.
- Return master and CI to green without weakening the assertion that caught this.

**Non-Goals:**
- Revisiting the up-front gate, its 0.25 fraction, the 512-root backstop, or the gate ordering. Those landed on evidence and stand.
- The ephemeral sweep and its interval, which remain blocked for separate reasons.

## Decisions

1. **Trip on projected remaining work, not on completed work.** Once N items are staged, the cost of finishing is what remains; the cost of abandoning is a full cold scan of the whole tree plus the N items already thrown away. Abandonment is only rational while the projected remainder still exceeds a cold scan. *Alternative considered*: keep the current comparison and simply raise the budget. Rejected because it treats a symptom: any fixed multiple of the cached count is wrong for a subtree whose growth is unbounded, which is precisely the case the guard exists for.

2. **Separate the prediction from the measurement.** The up-front budget answers "is this patch likely worth attempting?" and the mid-patch guard answers "has this patch turned out to be far larger than predicted?" Sharing one constant makes the second silently inherit the first's calibration. *Alternative considered*: one constant with a comment. Rejected because the two are computed from different denominators, one of which cannot see new content.

3. **The fixture is evidence, not an obstacle.** CLAUDE.md documents the reference fixture as deliberately shaped to stay warm-eligible while producing real churn. It now fails because it relies on the cached estimate undershooting, which is the very condition the guard detects. Decide deliberately whether it is a valid warm-patch shape that the guard should permit, or a genuinely oversized patch whose fixture needs more padding. Do not adjust it until green.

## Risks / Trade-offs

- **Loosening the guard reintroduces the unbounded-growth hole** → The protective case keeps a deterministic test with a subtree that grew far beyond its cached size, asserting a coherent cold fallback with a recorded reason.
- **Projected-remaining requires an estimate of what is left** → It may be cheap and approximate; the guard is a safety valve, not an accountant. State the approximation and its failure direction, which must be to finish rather than to abandon.
- **A weakened assertion would hide this class of bug permanently** → The `ScanSupervisionTests` guard must keep asserting a warm-patch-specific status.

## Migration Plan

No persisted format changes and no `formatVersion` bump. The change is confined to the guard's comparison and the constants feeding it.

## Open Questions

- Whether the mid-patch guard should abandon at all, or instead stop staging further roots and commit what it has as a partial patch with the remainder deferred. Partial commit preserves completed work but weakens the tree-equals-cold-scan guarantee, so it is listed here rather than decided.
