# Tasks — Search Filter Upgrade

## 1. Engine and filters (DirWizCore)

- [x] 1.1 Characterization tests pinning current `SearchEngine` behavior (query matching, caps, refinement, existing filters) before any change
- [x] 1.2 Extend `SearchFilters`: `extensionHashes` set (+ compatibility path for single-extension drill-down), `maximumSize`, modified-date bounds, `scopeRootIndex` + scope path
- [x] 1.3 Implement the scope bitset (single ascending pass using parent<child invariant) and integrate into the match loop; predicate ordered cheapest-reject-first
- [x] 1.4 Tests: extension-set OR semantics, size band, date bounds (edge: equal-to-bound), scope membership (deep descendants, root itself, sibling exclusion), all-filters-composed

## 2. Filter bar UI (DirWizUI)

- [x] 2.1 Extension multi-select picker fed by `fileTypeStats` (searchable, size/count shown, sorted by size) with removable OR chips; wire Extensions-tab drill-down to seed the picker
- [x] 2.2 Size range control (min + max) replacing the min-only picker; date-preset picker computing bounds at search-trigger time
- [x] 2.3 Chips row (wrapping) incl. scope chip with clear affordances; every filter mutation resets refinement state through one path
- [x] 2.4 "Search in this folder" context-menu action on tree rows → sets scope, switches to Search tab; scope re-resolves by path after tree mutations and clears with notice when unresolvable

## 3. Verification

- [x] 3.1 Latency sanity on a large tree (all filters active) — confirm no content I/O and instant-range timings; note numbers in PR
- [ ] 3.2 Full suite green; screenshot pass of the filter bar at narrow window widths

## Implementation notes (as built)

- **A behavior change I nearly shipped by accident.** Extending the empty-query gate to
  "any filter is active" broke the existing `SearchEngineTests` assertion that an empty
  query returns nothing regardless of filters. That test was right to fail: a size filter
  sits at a non-zero default, so the change would make an empty search box suddenly
  enumerate the volume. The gate now admits only filters that are themselves an explicit
  "show me this set" gesture — extension pick, folder scope, date window. Category and size
  keep the contract they shipped with.
- Extension multi-select is OR within the set, AND against every other filter kind. The set
  OVERRIDES the single-hash drill-down rather than ANDing with it; ANDing would make any
  two-extension selection match exactly nothing.
- `modifiedDate == 0` means the scanner never read a date. Date filters exclude those nodes
  rather than treating them as epoch, which would put every undated file inside every
  "older than" window.
- Scope is stored as a PATH, not a node index, and re-resolved before each query.
  `removeSubtree` renumbers every index, so a stored index silently comes to mean a
  different folder after any trash action. When the path stops resolving the scope clears
  itself WITH a visible notice — silently widening to the whole volume would look like the
  filter was honored.
- `SearchFilters.isUnsatisfiable` short-circuits inverted bands (min > max, after > before)
  so an impossible filter reads as "no results" instantly instead of as a slow search.
- New public `FileTree.nodeIndex(forPath:)` — `FileScanner.relativeComponents` is internal,
  and widening it would have leaked a scanner detail to the UI layer.
- 3.1 measured: 200k nodes with scope + 2 extensions + size band + date window active,
  best-of-5 **22.8 ms**; scope bitset construction over 100k nodes **7.5 ms**. Both are
  gated by tests. No filesystem reads on any path.

## Deferred (not implemented)

- 3.2's screenshot pass of the filter bar at narrow widths. The chips row scrolls
  horizontally and the bar's controls are fixed-width, so narrow windows clip the bar
  rather than wrapping it — worth a visual pass before release.
