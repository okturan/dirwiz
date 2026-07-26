# Insights Restructure: Collapsible Sections + Space Tab Retirement

## Why

The Insights tab is a fixed stack of eight sections with no way to collapse the ones you don't care about — and its "Run Analysis" button populates a *different tab* (Space), a wiring users experience as a button that does nothing. The Space tab's categorized output is conceptually just another Insights card; two surfaces for one analysis is one too many.

## What Changes

- Every Insights section becomes collapsible (chevron header, animated), with expansion state persisted across launches; sections default to expanded.
- The space-analysis category breakdown (safety badges, matched paths, size bars) moves into Insights as its top card ("Where did my disk go?") with the Analyze action and progress inline.
- **BREAKING (UI)**: the Space tab is removed from `DetailTab`; space analysis is reachable only via Insights. (No persisted state references the tab — `activeTab` isn't part of saved session state.)
- The Insights action bar's "Run Analysis" is renamed/absorbed into the new card so the action and its results live together.
- Sections get consistent card chrome (header, spacing) so the tab reads as a dashboard rather than a scroll of loosely stacked lists.

## Capabilities

### New Capabilities
- `insights-layout`: collapsible/persisted sections, the space-analysis card contract, and the Space tab's removal.

### Modified Capabilities
None — no baseline specs exist yet.

## Impact

- **DirWizUI**: `InsightsView` (collapsible wrapper, card chrome, space card), `SpaceAnalysisView` (content refactored into the card; standalone view retired), `AppState.DetailTab` (case removed) and `ContentView` tab switch, action-bar cleanup.
- **DirWizCore**: none (analysis engine untouched).
- **Tests**: expansion-persistence logic, `DetailTab` case set, space-card state handling (running/empty/results) at the state-model level.
