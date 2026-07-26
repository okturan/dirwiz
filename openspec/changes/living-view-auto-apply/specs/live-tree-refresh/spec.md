# live-tree-refresh

## ADDED Requirements

### Requirement: Automatic monitoring after scan
The system SHALL start FSEvents monitoring of the scanned root automatically when a scan completes (cold or warm), without user action, and SHALL stop/restart it appropriately when a new scan begins or the selected volume changes.

#### Scenario: Watch begins on scan completion
- **WHEN** a scan of a volume completes successfully
- **THEN** filesystem monitoring for that root is active and the Live pill reflects the watching state

### Requirement: Debounced auto-apply with exploration preservation
Accumulated changes SHALL be applied automatically once no new FSEvents have arrived for the quiescence window (~2 seconds), with at least the minimum interval (~10 seconds) between consecutive applies. Applies SHALL preserve the user's selection, expansion, and treemap root via path-keyed capture/restore and SHALL NOT blank the detail pane.

#### Scenario: Burst of changes applies once after quiet
- **WHEN** many files are created in a watched folder over 30 seconds and then activity stops
- **THEN** the tree updates via incremental splices (not one per event), the final state appears within a few seconds of quiescence, and the user's selection and treemap root are unchanged

### Requirement: Storm guard
When the pending changed-directory set exceeds the storm threshold (5,000 directories), the system SHALL stop auto-applying, keep accumulating, and surface a suggestion to run a Full Rescan instead.

#### Scenario: Package-manager storm
- **WHEN** an operation touches more than 5,000 directories between applies
- **THEN** no further auto-apply runs; the pill shows the pending magnitude with a Full Rescan affordance

### Requirement: Politeness guards
Auto-apply SHALL defer while any heavy task is running (scan, duplicate scan, space analysis, bundle sizing, another apply) and while the temporal-diff overlay is enabled; deferred changes apply after the guard clears. After any apply, an active search query SHALL re-run automatically so results reflect the updated tree.

#### Scenario: Deferred during duplicate scan
- **WHEN** changes accumulate while a duplicate scan is running
- **THEN** no apply occurs until the duplicate scan finishes, after which the pending changes apply

#### Scenario: Search stays current
- **WHEN** an apply completes while the Search tab shows results for a query
- **THEN** the same query re-runs automatically against the updated tree

### Requirement: Live pill with pause
The sidebar status SHALL show a Live pill ("Live · updated Xs ago") while watching, clickable to pause. While paused or guard-deferred, the pill SHALL show the pending changed-folder count with a manual Apply action. The paused preference SHALL persist across launches.

#### Scenario: Pause restores manual behavior
- **WHEN** the user pauses live updates and changes accumulate
- **THEN** the tree does not change; the pill shows "N folders changed · Apply"; clicking Apply performs the incremental refresh

### Requirement: Cache continuity across applies
Each successful auto-apply SHALL persist the updated tree to `TreeCache` with the pre-splice FSEvents id, so a subsequent launch warm-starts from the applied state without re-covering already-applied changes (overlap remains idempotent).

#### Scenario: Quit after auto-applies
- **WHEN** the app quits after several auto-applies and relaunches
- **THEN** the restored view reflects the applied state and warm start replays only events after the last apply

### Requirement: Watch controls removed from Insights
The Insights tab SHALL no longer present Watch Changes / Stop Watching controls; monitoring state is owned by the automatic lifecycle and the Live pill.

#### Scenario: No manual watch toggle
- **WHEN** the user opens the Insights tab after a scan
- **THEN** no watch start/stop button is present, while the recent-changes list remains visible as information
