# Tasks - Unify Extension Surfaces

## 1. Plumbing

- [x] 1.1 Add `extensionHash` to `PaletteEntry` at palette construction (nil for "Other"); mapping tests
- [x] 1.2 Extract `AppState.drillDownToExtension(hash:displayName:)` from the ContentView closure; state-mutation test (filter set, query cleared, tab switched)

## 2. Shared row component

- [x] 2.1 `ExtensionRowModel` + `ExtensionRowView` with `.compact` (legend) and `.table` (tab) styles; adopt in `ExtensionListView` with zero capability change
- [x] 2.2 Adopt in `ExtensionLegend`; verify identical swatch/name/size rendering across surfaces

## 3. Legend interactions

- [x] 3.1 Tap → `drillDownToExtension`; "Other" row → activate Extensions tab, with clarifying tooltip
- [x] 3.2 Hover affordance (background tint + pointing cursor)
- [x] 3.3 "See all file types →" footer button switching to the Extensions tab

## 4. Verification

- [x] 4.1 Screenshot pass at legend width extremes and long extension names (truncation)
- [x] 4.2 Full suite green; note the shared drill-down seam in the search-filter-upgrade change if it hasn't landed yet

## Implementation notes (as built)

- 1.1 needed no plumbing: `PaletteEntry.id` was ALREADY the extension hash, with
  `UInt32.max` reserved for "Other". `ExtensionRowModel.otherID` names that sentinel and a
  test pins it against a real `ExtensionPalette.assign`, so if the reserved value ever moves,
  "Other" starts drilling like a real extension and the test catches it rather than users.
- 1.2 the drill-down lived as a closure inside `ContentView`, i.e. in the app executable
  where the test target cannot reach it - which is also why the legend could not reuse it.
  It now lives on `AppState` (`drillDownToExtension`), is called by both surfaces, and is
  tested directly, following the `CLIArguments`/`TemporalDiffSummary` pattern.
- The drill-down clears `searchQuery`. A leftover query silently ANDs with the new extension
  filter and presents as "this file type has no files".
- Naming (`.swift` / `(no ext)` / `Other`) is derived in one place, `ExtensionRowModel
  .displayName`, and consumed by the legend row, the Extensions tab cell, and its tooltip.

## Screenshot pass (4.1, done after the first pass)

- Captured at 220pt (default) and inside a 1000pt window. Rows render swatch, name, size,
  count and percentage bar without clipping; long names truncate in the middle as intended
  while the size column holds its width; the "See all file types →" footer sits correctly
  at the bottom of the panel.
