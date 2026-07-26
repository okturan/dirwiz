# Search Filter Upgrade

## Why

Search is instant but its filters are minimal (files/dirs, category, fixed min-size steps), and filtering by extension requires a round-trip through the Extensions tab. Every field needed for richer filtering (extension hash, size, modified date, tree structure) is already on each node, so filters can grow substantially with zero cost to the instant feel.

## What Changes

- Extension filter becomes first-class in the Search filter bar: a searchable multi-select picker fed by `fileTypeStats` (showing per-extension size/count), rendering as removable OR-combined chips. The Extensions-tab drill-down keeps working and now just pre-fills this picker.
- Size filter gains a maximum bound (range, not just minimum).
- New modified-date filter with presets (any / 24h / 7d / 30d / 1y / older than 1y / older than 2y).
- Scope-to-folder: context-menu action ("Search in this folder") on tree rows sets a subtree scope, shown as a clearable chip; search matches only nodes under that folder.
- All filters compose (AND across filter kinds, OR within the extension set) as O(1) per-node predicates — no content I/O, preserving the instant architecture.
- Out of scope (follow-up): typed query tokens (`ext:png size:>100mb`); saved searches.

## Capabilities

### New Capabilities
- `search-filters`: the extension multi-filter, size range, modified-date presets, subtree scoping, and their composition/UI rules.

### Modified Capabilities
None — no baseline specs exist yet.

## Impact

- **DirWizCore**: `SearchFilters` gains `extensionHashes: Set<UInt32>` (superseding the single `extensionHash`), `maximumSize`, modified-date bounds, and a scope root; `SearchEngine` predicate extended; an O(n) subtree-membership bitset built per search (parent-before-child index invariant makes this a single ascending pass).
- **DirWizUI**: `SearchView` filter bar (picker menu, size range, date presets, chips row), tree-row context menu entry, `SearchState` scope plumbing; prefix-refinement optimization safety preserved (any filter change already invalidates `previousMatchIndices`).
- **Tests**: characterization tests for current `SearchEngine` behavior first, then new predicate tests (extension sets, size range, date bounds, scope membership including deep nesting).
