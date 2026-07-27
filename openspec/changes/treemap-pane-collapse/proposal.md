# Treemap Pane Collapse

## Why

The main view's bottom treemap pane can only be shrunk by dragging the split divider, and
the ratio clamps at 85/15 - the treemap can never fully disappear. When the work at hand is
table-shaped (sorting, comparing dates, batch selection), the permanent map is spent pixels
the user asked to reclaim and currently cannot.

## What Changes

- The split divider gains a centered chevron control: click collapses the treemap pane to
  zero and gives the detail pane full height; click again restores. Double-clicking the
  divider does the same.
- Restore returns to the PREVIOUS split ratio, not a default - collapsing must not destroy
  the layout the user had tuned.
- The collapsed state persists across launches, through AppState's injected `defaults`
  (never `UserDefaults.standard` directly - the test-hygiene rule in CLAUDE.md).
- A new scan does not reset it: like `treemapRenderStyle`, this is a layout preference,
  not scan state.
- The temporal-diff banner stays visible while collapsed so its Clear button - and the
  fact that a diff overlay is active - never becomes unreachable.
- Out of scope: persisting the split ratio itself (today it is session-only; unchanged),
  and any collapse of the tree table (the map-only view already exists by dragging up).

## Impact

- `Sources/DirWizUI/Models/AppState.swift` - persisted `isTreemapPaneCollapsed`
- `DirWiz/ContentView.swift` - divider control, conditional layout
- No DirWizCore changes; no renderer changes (the Metal view simply leaves the hierarchy)
