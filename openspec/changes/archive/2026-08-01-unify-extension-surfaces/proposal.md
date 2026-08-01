# Unify Extension Surfaces

## Why

File-type information lives in two visually different, behaviorally inconsistent places: the always-visible right-sidebar legend (the treemap's color key - completely inert, no tap targets) and the Extensions tab (sortable, filterable, drill-down to Search). The always-visible surface being the dumb one is backwards; the two should read as one system.

## What Changes

- A shared extension-row component renders both surfaces with the same visual hierarchy (swatch, name, size, count, percentage bar).
- Legend rows become interactive: tap → the same Search drill-down the tab performs (extension filter + Search tab); hover affordance makes tappability discoverable. The synthetic "Other" bucket drills to the Extensions tab instead (it has no single extension to filter by).
- The legend gains a "See all file types →" footer opening the Extensions tab.
- The Extensions tab keeps its filter field, sorting, and category column - it remains the full table; the legend remains the compact color key. Both now share rows, formatting, and interactions.
- `PaletteEntry` carries whatever identity the drill-down needs (extension hash) if not already present.
- Out of scope: hover-highlighting matching treemap tiles (tracked as a possible follow-up; touches the Metal renderer).

## Capabilities

### New Capabilities
- `extension-surfaces`: shared row presentation and the legend's interaction contract (drill-down, Other behavior, See-all navigation).

### Modified Capabilities
None - no baseline specs exist yet.

## Impact

- **DirWizUI**: `ExtensionLegend` (interactions + footer + shared rows), `ExtensionListView` (adopt shared row), `PaletteEntry`/palette construction if hash plumbing is missing; drill-down goes through the existing `appState.search` path (single-extension flow, compatible with the search-filter-upgrade change's multi-select seeding).
- **DirWizCore**: possibly `ExtensionPalette`/`PaletteEntry` field addition (no persisted formats involved).
- **Tests**: drill-down state mutation tests via AppState; palette-entry identity mapping tests.
