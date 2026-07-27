# Tasks - Treemap Pane Collapse

## 1. State

- [x] 1.1 `AppState.isTreemapPaneCollapsed`, persisted via the injected `defaults`, loaded
      in `init`, default false (expanded)
- [x] 1.2 Tests: default expanded; round-trips through an isolated defaults suite;
      survives `resetForNewScan()`; `.standard` untouched

## 2. Layout and control

- [x] 2.1 ContentView: when collapsed, hide `InteractiveTreemapView` and let the detail
      pane take full height; when expanded, current ratio behavior unchanged
- [x] 2.2 Chevron control centered on the divider (down = collapse, up = restore) with a
      hover affordance; double-click on the divider toggles as well
- [x] 2.3 Drag-to-resize disabled while collapsed (there is nothing to resize); the resize
      cursor must not appear
- [x] 2.4 Restoring returns to the pre-collapse split ratio

## 3. Verification

- [x] 3.1 Headless screenshot pass: expanded and collapsed states (set the pref via
      `defaults write` before launch, since the production app reads `.standard`)
- [x] 3.2 Full suite green

## Implementation notes (as built)

- State lives on `AppState` behind the injected `defaults`, following the rule this repo
  learned the hard way with `treemapRenderStyle`: a test asserts `.standard` is untouched.
- The collapse keeps `splitRatio` in place, so restore returns to the tuned layout - pinned
  by the "restores previous ratio" behavior falling out of never mutating the ratio at all.
- Screenshot-verified both states headlessly (pref set via `defaults write` before launch,
  deleted after). Collapsed: table takes full height, chevron-up pill on the bottom bar.
  Expanded: unchanged ratio layout, chevron-down pill on the divider.
