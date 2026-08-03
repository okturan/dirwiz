## ADDED Requirements

### Requirement: A live menu bar presence over existing state

DirWiz SHALL offer a menu bar item whose panel presents the current volume gauge, free-space
trend, growth since the last checkpoint, the live changing-now list, and the living-view
status, all composed from already-published scan, monitor, and checkpoint state. Opening the
panel SHALL NOT initiate scans, enumerations, or analyzer work; its only filesystem read is
the volume-stats call. The item SHALL be removable and restorable via a named setting.

#### Scenario: The user opens the panel while the living view is quiet

- **WHEN** the menu bar panel opens with a displayed tree and no active scan
- **THEN** it SHALL show used/available/total for the volume, the free-space trend, and the
  top growers recorded by the latest checkpoint summary
- **AND** no scan, splice, or analyzer SHALL start as a result of opening it

#### Scenario: Background churn is visible

- **WHEN** the FSEvents monitor has accumulated directory changes
- **THEN** the panel's changing-now list SHALL show the top accumulated directories with
  their change counts
- **AND** the living-view status line SHALL match the sidebar's Live pill reason

#### Scenario: Explicit actions only

- **WHEN** the user invokes Scan Now or Take Checkpoint from the panel
- **THEN** the existing scan or checkpoint flow SHALL run exactly as if triggered in the
  window
- **AND** no menu bar surface SHALL trigger filesystem work without such an explicit action

### Requirement: The icon reports state honestly

The menu bar icon SHALL be a template glyph with distinct idle, scanning, and low-space
states, and MAY show a free-space text label behind a setting that defaults to off. State
selection SHALL be a pure, tested function of published app state.

#### Scenario: Low space changes the icon

- **WHEN** available space crosses below the configured threshold
- **THEN** the icon SHALL adopt its warning variant until recovery above the re-arm margin

### Requirement: Residency keeps the living view alive without a window

With "Keep DirWiz in the menu bar" enabled, closing the last window SHALL switch the app to
accessory activation policy: no Dock icon, menu bar item retained, FSEvents monitoring, live
applies, and cache writes continuing unchanged. Reopening from the menu bar SHALL restore a
regular app with its window. The bundle identity SHALL NOT change between modes, so privacy
grants are unaffected. With residency disabled, window close SHALL quit exactly as today.
Quit from the panel SHALL always terminate.

#### Scenario: Close the window, keep watching

- **WHEN** residency is enabled and the last window closes
- **THEN** the process SHALL continue as an accessory with monitoring and cache writes active
- **AND** selecting Open DirWiz later SHALL restore the window with the living view current

### Requirement: Launch at login is offered and truthful

A Settings toggle SHALL register or unregister the app as a login item via ServiceManagement
and SHALL surface the actual registration status, including approval-required states, rather
than assuming success.

#### Scenario: Registration requires approval

- **WHEN** the system reports the login item as requiring approval
- **THEN** Settings SHALL say so and link to the Login Items pane instead of showing the
  toggle as silently on

### Requirement: Notifications are rare, actionable, and policy-driven

Low-space notifications SHALL be governed by a pure, clock-injected hysteresis policy: fire
once on crossing the threshold, re-arm only after recovery above a margin, at most one
notification per volume per day. Notifications SHALL be actionable (opening DirWiz), the
growth alert SHALL default to off, notification authorization SHALL be requested only on
first enable, and every knob SHALL persist through the injected defaults store.

#### Scenario: Hovering around the threshold does not spam

- **WHEN** available space oscillates just below and above the threshold repeatedly
- **THEN** at most one notification SHALL fire until genuine recovery re-arms the policy

### Requirement: Automation surfaces expose existing verbs

DirWiz SHALL expose App Intents for Get Free Space, Largest Files, Scan Volume, and Take
Checkpoint - answerable from cached state where read-only, reporting cache age honestly -
plus a Dock menu with recent volumes and a Finder Services entry that scans a selected
folder. Intents SHALL share query logic with the CLI vocabulary and introduce no second
scan pipeline.

#### Scenario: Largest files from Shortcuts

- **WHEN** the Largest Files intent runs with a count and volume
- **THEN** it SHALL answer from the cached tree without scanning
- **AND** the result SHALL state when that cache was written

### Requirement: Platform integrations that need extension bundles are out of scope

WidgetKit widgets, FinderSync badges, and Quick Look previews SHALL NOT ship in this change;
they require embedded app-extension bundles the SwiftPM layout and release script do not
produce. Any future adoption SHALL be its own change covering embedding, signing, and
notarization.

#### Scenario: A widget is requested

- **WHEN** widget support is considered
- **THEN** it SHALL be planned as a separate change extending the release machinery first
