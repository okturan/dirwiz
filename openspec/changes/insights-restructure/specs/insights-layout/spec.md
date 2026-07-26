# insights-layout

## ADDED Requirements

### Requirement: Collapsible persisted sections
Every Insights section SHALL be individually collapsible via its header, defaulting to expanded, with collapse state persisted across app launches (globally, not per volume).

#### Scenario: Collapse survives relaunch
- **WHEN** the user collapses "Size Distribution" and relaunches the app
- **THEN** "Size Distribution" renders collapsed while other sections remain expanded

#### Scenario: Collapsed sections still discoverable
- **WHEN** a section is collapsed
- **THEN** its header (title + icon) remains visible and re-expands on click

### Requirement: Space analysis as an Insights card
The space-analysis category breakdown (categories with safety ratings, sizes, percentage bars, matched paths) SHALL be presented as the top Insights card, containing its own Analyze action, inline progress, and results - action and outcome in one place.

#### Scenario: Analyze from the card
- **WHEN** the user clicks Analyze in the space card
- **THEN** progress shows inside the card and, on completion, the categorized breakdown renders in the same card without switching tabs

#### Scenario: Card empty state
- **WHEN** no analysis has been run for the current tree
- **THEN** the card explains what Analyze produces and offers the action

### Requirement: Space tab removed
The tab bar SHALL no longer include a Space tab; space analysis SHALL be reachable via the Insights card. No control may trigger results that render on a tab other than the one hosting the control.

#### Scenario: Tab bar without Space
- **WHEN** the user views the tab bar after this change
- **THEN** the tabs are Tree View, Extensions, Duplicates, Hardlinks, Search, Insights - and the analysis lives in Insights
