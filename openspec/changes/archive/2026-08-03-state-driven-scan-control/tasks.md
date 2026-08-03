## 1. Control-State Model

- [x] 1.1 Add focused tests for the idle decision: no selection, selected volume without a tree,
  selected volume with a matching displayed root, cached-but-undisplayed volume, and a selection
  switch while another volume's tree remains displayed.
- [x] 1.2 Introduce a small state-driven scan-control model that owns the label, progress treatment,
  enabled state, and normal-scan versus full-rescan action.
- [x] 1.3 Centralize selected-volume/displayed-tree ownership using normalized volume-root identity,
  with coverage for `/` and a non-root mounted-volume path.
- [x] 1.4 Add busy-state tests for preparation (`Checking changes…`), enumeration or warm patch
  (`Scanning…`), and live-tree apply (`Updating…`), including disabled action routing and
  deterministic precedence for defensive overlapping flags.

## 2. Single Sidebar Control

- [x] 2.1 Replace `VolumePickerView`'s primary-plus-subordinate button stack with one prominent button
  rendered from the control-state model.
- [x] 2.2 Preserve progress indication and add state-appropriate icon, label, accessibility, and help
  text for `Scan Volume`, `Full Rescan`, and each busy state.
- [x] 2.3 Route `Scan Volume` to `startSelectedVolumeScan()` and `Full Rescan` to
  `startFullRescan()` from the same decision that renders the label; busy and unavailable states
  must dispatch neither callback.
- [x] 2.4 Remove `fullRescanAvailable` and remove `hasCachedTree(for:)` if it has no remaining caller,
  without changing cache validation or warm/cold scan policy.
- [x] 2.5 Confirm the living-view storm warning retains its contextual full-rescan recovery action
  while the persistent scan-control area contains only the new single control.

## 3. Lifecycle and Regression Coverage

- [x] 3.1 Cover launch without displayed data: the enabled control says `Scan Volume`, including when
  a usable cache exists but has not yet been restored into the displayed tree.
- [x] 3.2 Cover launch restore and automatic refresh: the restored selected tree produces a busy
  state while refresh runs and settles to `Full Rescan` when automatic work finishes.
- [x] 3.3 Cover volume switching in both directions and assert that label, enabled state, and invoked
  callback always follow the selected volume rather than the previously displayed tree or cache.
- [x] 3.4 Cover live auto-apply and cancelled/failed refresh states: applying is disabled and labelled
  `Updating…`; an idle still-displayed tree exposes only `Full Rescan`.
- [x] 3.5 Preserve the existing forced-cold semantics and diagnostic reason for full rescan, and keep
  existing launch restore, scan supervision, warm-start, and living-view assertions unchanged.
- [x] 3.6 Update the repository's UI behavior documentation to state that the persistent sidebar has
  one scan control and that displayed-tree ownership selects its idle meaning.

## 4. Operation-Coherent Completion Status

- [x] 4.1 Add deterministic living-apply coverage that seeds a completed scan summary and elapsed
  time, applies filesystem changes, and requires both scan values to remain unchanged.
- [x] 4.2 Move successful living-apply bookkeeping to the separate live status (`lastLiveApplyAt` and
  generation) for both automatic and explicit apply paths.
- [x] 4.3 Publish a successful warm scan's measured elapsed time into `scanProgress` at the same
  completion boundary as its warm summary.
- [x] 4.4 Remove the redundant independently rendered elapsed line from the completed-scan block.

## 5. Verification

- [x] 5.1 Run the focused scan-control, launch-restore, living-view, and scan-summary test groups.
- [x] 5.2 Run `swift test --skip-build` after a clean prebuild, or the repository's equivalent full
  suite command, and record the exact result.
- [x] 5.3 Run CI-parity verification and confirm no scan-supervision, warm-patch, or living-view
  regression was introduced.
- [x] 5.4 Exercise the sidebar manually through fresh launch, restored launch, active scan, live apply,
  completed tree, and volume switch; confirm `Scan Volume` and `Full Rescan` never appear together
  in the persistent scan-control area and completed status never combines two operations.

### Closure (2026-08-03)
5.4's states were each exercised natively across the Aug 2-3 sessions: fresh and restored launches (warm-start verification), active scans, live applies, completed trees, and volume switching to Samsung8TB - captures show the single state-driven control (Scan Volume vs Full Rescan) and one-operation completed status throughout.
