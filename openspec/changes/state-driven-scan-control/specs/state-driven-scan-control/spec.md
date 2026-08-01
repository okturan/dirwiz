## ADDED Requirements

### Requirement: The sidebar exposes one scan control

The sidebar SHALL render exactly one prominent scan control for the selected volume. It MUST NOT
present `Scan Volume` and `Full Rescan` as simultaneous choices.

#### Scenario: No volume is selected

- **WHEN** no volume is selected
- **THEN** the control SHALL be labelled `Scan Volume`
- **AND** the control SHALL be disabled
- **AND** activating it SHALL start no work

#### Scenario: The selected volume has no displayed tree

- **WHEN** a volume is selected and the displayed tree does not belong to that volume
- **THEN** the control SHALL be labelled `Scan Volume`
- **AND** the control SHALL be enabled when no scan or live-tree apply is active

#### Scenario: The selected volume owns the displayed tree

- **WHEN** a volume is selected and the displayed tree belongs to that volume
- **THEN** the control SHALL be labelled `Full Rescan`
- **AND** no separate `Scan Volume` action SHALL be shown

#### Scenario: A cache exists without a matching displayed tree

- **WHEN** a cache exists for the selected volume but no tree for that volume is currently displayed
- **THEN** the control SHALL remain `Scan Volume`
- **AND** cache existence SHALL NOT cause a second scan action or a `Full Rescan` label to appear

#### Scenario: The user selects a different volume

- **WHEN** the displayed tree belongs to one volume and the user selects another volume
- **THEN** the control SHALL change to `Scan Volume` for the newly selected volume
- **AND** it SHALL NOT describe the old volume's displayed tree as data for the new selection

### Requirement: The one control routes the state-appropriate action

The control's label and action SHALL derive from the same state decision. `Scan Volume` SHALL use
the existing cache-aware scan entry point, while `Full Rescan` SHALL use the existing forced-cold
entry point.

#### Scenario: Starting a volume with no displayed data

- **WHEN** the enabled `Scan Volume` control is activated
- **THEN** the app SHALL start the selected volume through the normal scan path
- **AND** the scan planner MAY restore or use valid cached data according to existing cache policy

#### Scenario: Rebuilding a displayed volume

- **WHEN** the enabled `Full Rescan` control is activated
- **THEN** the app SHALL start the selected volume through the forced-cold path
- **AND** the scan SHALL bypass the cached tree and re-enumerate the volume

#### Scenario: Label and callback cannot diverge

- **WHEN** the selected volume's control state changes between `Scan Volume` and `Full Rescan`
- **THEN** both the rendered label and the invoked scan entry point SHALL reflect the new state
- **AND** a stale callback from the prior state SHALL NOT be invoked

### Requirement: Active work is represented by the same control

While scan preparation, filesystem enumeration, or live-tree apply is active, the single control
SHALL report the current work, SHALL be disabled, and MUST NOT start another scan.

#### Scenario: Scan preparation is active

- **WHEN** the selected scan flow is checking cached or journal state before enumeration
- **THEN** the control SHALL show progress and be labelled `Checking changes…`
- **AND** the control SHALL be disabled

#### Scenario: Filesystem enumeration is active

- **WHEN** a scan is enumerating or patching filesystem content after preparation
- **THEN** the control SHALL show progress and be labelled `Scanning…`
- **AND** the control SHALL be disabled

#### Scenario: Live changes are being applied

- **WHEN** the app is applying completed live changes to the displayed tree
- **THEN** the control SHALL show progress and be labelled `Updating…`
- **AND** the control SHALL be disabled
- **AND** no scan action SHALL be dispatched

#### Scenario: Automatic work settles on a displayed tree

- **WHEN** launch refresh or living-view work finishes with the selected volume's tree displayed
- **THEN** the same control SHALL settle to the enabled `Full Rescan` state

### Requirement: Automatic freshness remains implicit

Once the selected volume has a displayed tree, automatic launch refresh and living-view auto-apply
SHALL remain the normal mechanisms for keeping it current. The persistent sidebar scan control MUST
NOT offer a manual incremental refresh action for that loaded volume.

#### Scenario: A loaded living view is idle

- **WHEN** the selected volume has a displayed tree and no automatic work is active
- **THEN** the only persistent sidebar scan action SHALL be `Full Rescan`

#### Scenario: A displayed refresh was cancelled or could not continue

- **WHEN** the selected volume's tree remains displayed after automatic refresh is cancelled or
  cannot continue
- **THEN** the scan control SHALL still represent the available manual action as `Full Rescan`
- **AND** it SHALL NOT introduce a second generic refresh button

#### Scenario: The living-view storm guard requests a rebuild

- **WHEN** the existing living-view safety UI recommends a full rescan
- **THEN** that contextual recovery affordance MAY remain alongside its warning
- **AND** the persistent scan-control area SHALL still contain exactly one state-driven control

