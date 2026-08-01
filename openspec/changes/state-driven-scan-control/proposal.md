## Why

DirWiz now refreshes a loaded tree automatically at launch and keeps it current through living-view
auto-apply. Showing `Scan Volume` and `Full Rescan` together after data is already displayed presents
a false choice: the app owns incremental freshness, so the only manual scan action left is rebuilding
the selected volume from scratch.

## What Changes

- Replace the simultaneous primary `Scan Volume` and secondary `Full Rescan` affordances with one
  prominent state-driven control.
- Show `Scan Volume` when the selected volume has no displayed tree, and route it through the normal
  cache-aware scan path.
- Show `Full Rescan` when the selected volume's tree is already displayed, and route it through the
  existing forced-cold path.
- While scan preparation, enumeration, or live-tree apply is active, make the same control report the
  current work and reject another scan action.
- Remove cache-file existence as the UI decision for showing a second scan action. Cache policy and
  automatic warm/cold fallback remain internal scan behavior.
- Add state and action-routing tests covering fresh launch, restored data, volume switching, active
  scan, and live auto-apply.

## Capabilities

### New Capabilities

- `state-driven-scan-control`: The single sidebar scan control's label, availability, and action for
  each selected-volume and scan-lifecycle state.

### Modified Capabilities

<!-- None: there is no baseline capability spec for the current scan buttons. -->

## Impact

- `Sources/DirWizUI/Views/VolumePickerView.swift`: replace the two-button stack with one state-driven
  control and remove `fullRescanAvailable`.
- `Sources/DirWizUI/Models/AppState+Scan.swift` or a small UI model: expose a testable decision based
  on selected volume, displayed tree ownership, scan preparation/enumeration, and live apply state.
- `Sources/DirWizUI/ContentView.swift`: keep the existing normal-scan and forced-cold entry points,
  but route the single control to exactly one of them.
- Tests: pin labels, disabled states, selected-volume ownership, and callback routing. No scanner,
  cache format, FSEvents, or warm-start policy changes.
