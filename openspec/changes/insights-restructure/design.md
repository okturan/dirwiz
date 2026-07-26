# Design — Insights Restructure

## Context

`InsightsView` is a `ScrollView` of eight `@ViewBuilder` sections sharing a `sectionHeader` helper; its action bar includes "Run Analysis" → `startSpaceAnalysis()`, whose results render only in `SpaceAnalysisView` (the Space tab). `DetailTab` is a `CaseIterable` enum driving the tab bar and `ContentView`'s switch. `activeTab` is not persisted in `SessionStateStore`, so removing a case has no migration surface. `canStartHeavyTask(.spaceAnalysis)` gates the action; `spaceAnalysisProgress` and `spaceAnalysis` results live on AppState already.

## Goals / Non-Goals

**Goals:**
- Dashboard feel: collapsible cards, consistent chrome, action-next-to-result.
- One home for space analysis; tab count 7 → 6.

**Non-Goals:**
- Changing any analyzer behavior or adding new insights content.
- A "Cleanup" surface with actionable presets (future, larger proposal — the card's content stays informational).
- Per-volume expansion state.

## Decisions

1. **`CollapsibleSection` wrapper**: header (icon + title + chevron) + content, driven by a persisted `Set<String>` of collapsed section IDs in `UserDefaults` (`insightsCollapsedSections`). Persistence logic in a small testable store type (default-expanded = absent from set, so new sections added later default open for free).
2. **Card chrome**: one background/corner style applied by the wrapper (rounded rect, subtle fill — same family as `SpaceAnalysisView`'s existing row background) so all sections inherit consistency without per-section restyling.
3. **Space card**: `SpaceAnalysisView`'s toolbar/progress/list content refactors into a `SpaceAnalysisCard` embedded as the first section; the standalone view and its file retire. Analyze button, `canStartHeavyTask` gating, progress, and the categorized list all render inside the card. The action bar's "Run Analysis" button is removed (the card owns the action); other action-bar buttons (iCloud, Volume Info, watch-related pending the living-view change) remain.
4. **Tab removal**: delete `DetailTab.spaceAnalysis`, its `ContentView` switch arm, and the view import. `DetailTab` is `String`-raw-valued but never persisted, so no decode concern. A compile-time exhaustive switch guarantees nothing dangles.
5. **Section IDs** are stable string keys (not titles) so renaming a header never resets a user's collapse state.

## Risks / Trade-offs

- [Users who knew the Space tab lose a location] → the card is the first thing Insights shows; release note covers it.
- [Collapse-all hides content and users forget] → headers always visible; default state is expanded; no "collapse all" control in v1.
- [Concurrent changes touching InsightsView (living-view removes watch buttons)] → both changes edit the action bar; explicit rebase note in tasks, whichever lands second.

## Migration Plan

UI-only; `UserDefaults` key is new. Rollback = revert (collapse-state key becomes inert).

## Open Questions

None — deliberately small scope; the ambitious "Cleanup" reframe is a separate future proposal.
