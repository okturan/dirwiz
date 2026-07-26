# Design - Unify Extension Surfaces

## Context

`ExtensionLegend` renders `ExtensionPalette.entries` (top-N by size, the treemap's color source) with a private inert `ExtensionRow`. `ExtensionListView` renders `fileTypeStats` (`FileTypeStat`, all extensions) with its own row layout and an `onDrillDown` closure that sets `appState.search.extensionFilter` (+ display name), clears the query, and activates the Search tab. Two data types, two row implementations, one interaction implemented once.

## Goals / Non-Goals

**Goals:**
- One row component, one drill-down path, discoverable legend interactivity.
- No capability regression in the tab.

**Non-Goals:**
- Treemap hover-highlight sync (follow-up; Metal renderer scope).
- Changing palette composition, colors, or the "Other" bucketing.
- Removing either surface.

## Decisions

1. **Shared component over shared data**: keep the two data sources (palette entries for the legend, full stats for the tab) and unify at the row-view level - `ExtensionRowView(model: ExtensionRowModel, style: .compact | .table)` where `ExtensionRowModel` is a tiny value struct both `PaletteEntry` and `FileTypeStat` map into (name, hash?, color?, size, count, fraction). Unifying the data sources instead was rejected: the palette's top-N + Other shape is a rendering concern of the treemap and shouldn't leak into the stats table.
2. **Drill-down centralized on AppState**: extract the closure body from `ContentView` into `AppState.drillDownToExtension(hash:displayName:)` used by both surfaces (and by the future multi-select seeding in the search-filter-upgrade change - the two changes touch the same seam; whichever lands second adapts trivially).
3. **`PaletteEntry` identity**: add `extensionHash` at palette construction if absent ("Other" gets nil → routes to the Extensions tab). No persisted formats involved.
4. **Hover affordance**: row background tint + pointing-hand cursor on hover (standard AppKit cursor via `onHover`), matching the tab rows' tap affordance; percentage bar remains non-interactive content.
5. **Footer**: plain button styled as a tertiary link, pinned under the scroll list.

## Risks / Trade-offs

- [Two changes touching search drill-down (this + search-filter-upgrade)] → both route through the single `drillDownToExtension` seam; explicit note in both task lists to reconcile on rebase.
- [Legend width (220pt) constraining the shared row] → the `.compact` style owns truncation rules; screenshot pass gates merge.
- ["Other" tap surprising users] → tooltip on the row ("Show all file types") clarifies the different destination.

## Migration Plan

UI-only refactor; no persisted state. Rollback = revert.

## Open Questions

None blocking; treemap hover-sync deliberately deferred.
