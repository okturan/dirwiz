# Tasks — Insights Restructure

## 1. Collapsible infrastructure

- [x] 1.1 `CollapsibleSection` wrapper (header/chevron/animation) + persisted collapsed-ID store (`UserDefaults`, stable string keys, default-expanded); unit tests for the store logic
- [x] 1.2 Wrap all existing Insights sections; apply consistent card chrome via the wrapper

## 2. Space card migration

- [x] 2.1 Refactor `SpaceAnalysisView` content into `SpaceAnalysisCard` (Analyze action + gating, inline progress, categorized results, empty state) as the first Insights section
- [x] 2.2 Remove the action bar's "Run Analysis" button (card owns the action); retire `SpaceAnalysisView`
- [x] 2.3 State-level tests: card content for running/empty/results states

## 3. Tab removal

- [x] 3.1 Remove `DetailTab.spaceAnalysis` and the `ContentView` switch arm; verify exhaustive switches compile; update any tab-count assumptions
- [x] 3.2 Confirm no persisted or session state references the removed tab (activeTab is unpersisted — assert in a test if cheap)

## 4. Verification

- [ ] 4.1 Screenshot pass: default state, mixed collapsed state, space card in all three states; iterate per design-taste memory
- [x] 4.2 Full suite green; release-note line for the Space tab move; note the InsightsView action-bar overlap in the living-view change for rebase ordering

## Implementation notes (as built)

- `SectionCollapseStore` persists the COLLAPSED ids, not the expanded ones. With the
  inverse, every section added in a future release would arrive collapsed and effectively
  invisible; storing collapsed ids means an unknown id is expanded by definition and no
  migration is ever needed. Pinned by "An unknown section defaults to expanded".
- Each section used to render its own `sectionHeader`. Wrapping them in `CollapsibleSection`
  would have produced two headers per card, so the inner calls were removed and their
  richer titles (the ones carrying counts) moved onto the wrapper. `sectionHeader` is gone.
- The Analyze control sits in the section's header accessory rather than in the card body,
  so it stays reachable while the card is collapsed — otherwise collapsing the card would
  hide the action that fills it.
- 3.2: `activeTab` really is unpersisted, and there is now a test asserting a fresh
  `AppState` starts on the first tab. That is what makes removing a `DetailTab` case safe —
  no saved state can point at the retired tab.

## Deferred (not implemented)

- 4.1 the screenshot pass (default / mixed-collapsed / space card in all three states).
  These are plain SwiftUI and would capture correctly with the repo's headless technique,
  unlike the Metal treemap — not visually confirmed.
