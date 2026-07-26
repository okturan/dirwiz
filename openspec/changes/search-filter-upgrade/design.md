# Design - Search Filter Upgrade

## Context

`SearchEngine.search` evaluates a per-node predicate over `nodesSnapshot()` + the lowercase search pool, with a 10K result cap and a prefix-refinement optimization (`previousMatches` reused only when the new query extends the old and the old wasn't capped). `SearchFilters` is a small Sendable value struct; `SearchView` owns the filter bar and already nils `previousMatchIndices` on any filter change. Extension identity is a scan-time FNV hash (`extensionHash: UInt32`) on every file node; `fileTypeStats` (AppState+Stats) already aggregates per-extension size/count for the picker's data.

## Goals / Non-Goals

**Goals:**
- Richer filters with zero regression to instant latency or the refinement optimization's correctness.
- Extension filtering reachable entirely inside the Search tab.
- Subtree scoping that's O(n) once per search, O(1) per node thereafter.

**Non-Goals:**
- Typed query-token syntax (`ext:png size:>1gb`) - future layer on the same `SearchFilters`.
- Content-based filters (kind detection by magic bytes), saved searches, regex.

## Decisions

1. **`SearchFilters` shape**: replace `extensionHash: UInt32?` with `extensionHashes: Set<UInt32>` plus a parallel display-name list for chips (engine consumes hashes only). Keep a computed compatibility setter for the drill-down path so `ExtensionListView`'s single-extension flow just seeds a one-element set. Add `maximumSize: UInt64` (0 = unbounded, matching `minimumSize`'s convention), `modifiedAfter`/`modifiedBefore: UInt32` epoch bounds (presets computed in the view), and `scopeRootIndex: UInt32?`.
2. **Scope membership via one ascending pass**: node indices satisfy parent < child for scanned trees (CLAUDE.md invariant), so `inScope[i] = (i == root) || inScope[parentIndex(i)]` in a single forward loop building a `[Bool]`/bitset before the match loop. Rebuilt per search; invalidated naturally because `SearchView` clears cached state on `scanToken` change and filter changes nil `previousMatchIndices`.
   - *Alternative*: per-node parent-chain walk (O(depth) per candidate) - rejected; the bitset is simpler and strictly cheaper for whole-tree scans.
   - Scope stores the root's *path* alongside the index for display + revalidation; on tree mutation the index is re-resolved via `descendPath` (indices don't survive `removeSubtree`).
3. **Predicate order**: cheapest-reject first - nodeType, scope bitset, size bounds, date bounds, extension set (`Set.contains` on UInt32), category, then name match. Name matching stays last (it's the expensive part).
4. **Refinement safety**: refinement remains keyed to query-prefix extension only; any filter mutation clears `previousMatchIndices` (existing behavior, now covering the new fields - enforced by routing all filter mutations through one `onChange` that resets refinement state).
5. **Picker UI**: a `Menu`-based searchable list over `fileTypeStats` sorted by size desc, checkmark toggles, capped visual list with an inline filter field (same pattern as `ExtensionListView`'s filter). Chips render in a wrapping row under the filter bar; scope chip appears first with a folder glyph.
6. **Date presets** computed at trigger time (not stored as absolutes in state) so a re-run after auto-apply (living-view change) stays current.

## Risks / Trade-offs

- [Bitset allocation per search on multi-million-node trees] → one `[Bool]` of n (2.5 MB at 2.5M nodes) allocated only when scope is active; released with the search task.
- [Extension hash collisions across distinct extensions] → same tolerance the treemap palette already accepts; display names come from stats, not reverse-hashing.
- [Scope index invalidation after mutations] → path-backed re-resolution; unresolvable scope clears the chip with a subtle notice rather than silently searching the whole tree.
- [Filter bar crowding] → chips wrap; pickers stay compact; measured pass on 13" layout before merge.

## Migration Plan

Pure addition to view + engine; drill-down API preserved. No persisted formats. Rollback = revert.

## Open Questions

- Should scope also be settable from the treemap's right-click menu? Default: yes if trivial (same action), but tree-row menu is the required surface.
