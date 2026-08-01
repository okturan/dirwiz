# treemap-pane-collapse Specification

## Purpose
Define a persistent, discoverable way to collapse and restore the treemap pane without hiding recovery controls.
## Requirements
### Requirement: The treemap pane can collapse completely and restore

The main split view SHALL let the user collapse the treemap pane to zero height and SHALL restore it
to the split ratio that was active before collapse.

#### Scenario: User collapses from a tuned split

- **WHEN** the user activates the divider's collapse control after adjusting the split ratio
- **THEN** the treemap leaves the layout and the detail pane receives the available height
- **AND** the existing split ratio is retained for restoration

#### Scenario: User restores the treemap

- **WHEN** the user activates the restore control while the pane is collapsed
- **THEN** the treemap returns at the pre-collapse split ratio rather than a default ratio

### Requirement: The divider exposes an honest collapse interaction

The divider SHALL provide a centered directional control and double-click gesture for toggling the
treemap, and SHALL NOT present drag-to-resize behavior while no treemap pane is visible.

#### Scenario: Treemap is expanded

- **WHEN** the treemap pane is visible
- **THEN** the divider control indicates collapse
- **AND** ordinary divider dragging continues to resize the split

#### Scenario: Treemap is collapsed

- **WHEN** the treemap pane has zero height
- **THEN** the control indicates restore
- **AND** the divider does not advertise or perform drag resizing

#### Scenario: User double-clicks the divider

- **WHEN** the divider receives a double-click
- **THEN** it toggles between the same collapsed and restored states as the centered control

### Requirement: Collapse is a persistent layout preference

The system SHALL store the collapsed state through `AppState`'s injected defaults, SHALL default to
expanded when no preference exists, and SHALL preserve the preference across scans and launches.

#### Scenario: A new installation launches

- **WHEN** no treemap-collapse preference has been stored
- **THEN** the treemap starts expanded

#### Scenario: A collapsed preference is restored

- **WHEN** the user relaunches after collapsing the treemap
- **THEN** the treemap starts collapsed
- **AND** tests can isolate the preference without reading or writing `UserDefaults.standard`

#### Scenario: A new scan begins

- **WHEN** scan state is reset while the treemap preference is collapsed
- **THEN** the treemap remains collapsed because scan lifecycle does not own layout preferences

### Requirement: Collapsing the treemap does not hide temporal-diff recovery

The system SHALL keep the temporal-diff banner and its clear action reachable when the treemap pane
is collapsed.

#### Scenario: A temporal diff is active while collapsed

- **WHEN** the treemap is collapsed while a temporal comparison is displayed
- **THEN** the interface still identifies the active diff
- **AND** the user can clear it without restoring the treemap first
