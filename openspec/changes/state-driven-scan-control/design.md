## Context

The volume sidebar currently renders a prominent `Scan Volume` button and, whenever a cache file
exists for the selected path, a subordinate `Full Rescan` button. That made sense when the first
button could be read as an ordinary refresh action. It no longer matches DirWiz's ownership model:
launch restore immediately refreshes cached data, and the living view automatically applies later
filesystem changes. Once a tree is displayed, the only distinct manual scan operation is the
forced-cold rebuild.

Cache existence is also the wrong UI predicate. A cache may exist before its volume is displayed,
and a displayed tree may remain visible while the user selects a different volume. The UI decision
has to follow the selected volume and the tree the user is actually looking at, while leaving cache
acceptance and warm/cold fallback inside the scanner.

## Goals / Non-Goals

**Goals:**

- Expose one prominent scan control whose meaning follows the selected volume's displayed state.
- Make the transition from first scan to full rescan legible without presenting a false choice.
- Represent preparation, enumeration, and live apply as disabled states of that same control.
- Keep label and action routing mechanically consistent and straightforward to unit test.
- Preserve automatic launch refresh, living-view auto-apply, and forced-cold recovery behavior.

**Non-Goals:**

- Change cache validation, warm-patch planning, cold fallback, FSEvents, or scan supervision.
- Remove the contextual full-rescan recovery action from the living-view storm warning.
- Add a manual incremental-refresh mode or change automatic refresh retry policy.
- Disable full rescan while post-scan analyses such as bundle sizing run; existing cancellation and
  coordination rules continue to apply.

## Decisions

### 1. Displayed-tree ownership, not cache existence, selects the idle action

The idle control is `Full Rescan` only when a selected volume exists and `fileTree.rootPath`
identifies that selected volume. Otherwise it is `Scan Volume` (disabled when no volume is
selected). The comparison will use the repository's normalized volume-path identity rather than
merely testing `fileTree != nil`.

This handles the important cross-volume case: selecting volume B while volume A's tree remains on
screen must offer a first scan of B, not a rebuild of A or a misleading rebuild label. An on-disk
cache for B does not change the label; the normal scan entry point may use that cache internally.

Alternatives considered:

- **Keep using cache-file existence.** Rejected because it exposes an implementation detail and can
  label an undisplayed volume as already scanned.
- **Use any non-nil displayed tree.** Rejected because the tree may belong to a different volume.
- **Track a separate `hasScanned` flag.** Rejected because it duplicates authoritative tree
  ownership and introduces lifecycle/reset edges.

### 2. A single control-state value owns presentation and action

Introduce a small, testable UI decision value with these states, in priority order:

1. scan preparation: progress, `Checking changes…`, disabled;
2. scan enumeration or warm patch: progress, `Scanning…`, disabled;
3. completed live changes being applied: progress, `Updating…`, disabled;
4. selected volume owns the displayed tree: `Full Rescan`, enabled;
5. all other idle states: `Scan Volume`, enabled only when a volume is selected.

`VolumePickerView` will render exactly one prominent button from that value. The value will also
decide whether activation invokes the normal or forced-cold callback. This prevents a correct label
from being paired with a stale or opposite closure after selection changes.

Scan preparation and enumeration are listed separately because `isPreparingScan` is a refinement of
`scanProgress.isScanning`. Live apply is included because the scan entry points intentionally reject
work during `isApplyingChanges`; the UI must describe that work rather than offer a clickable no-op.

Alternatives considered:

- **Scatter label, disabled state, and callback conditions across the SwiftUI body.** Rejected
  because those independent branches can drift and are harder to cover without view introspection.
- **Hide the control while busy.** Rejected because the existing progress label explains why the
  scan action is temporarily unavailable.

### 3. Preserve the two existing scan entry points behind the one control

`Scan Volume` continues to call `startSelectedVolumeScan()`, including its cache-aware warm/cold
decision. `Full Rescan` continues to call `startFullRescan()`, including `forceCold: true` and the
existing diagnostic reason. The UI consolidation does not merge these operations; it makes exactly
one of them relevant at a time.

`ContentView` may continue to provide two closures, or the view may accept one state-routed action,
as long as the state decision is the sole authority and both paths remain directly testable. The
cheap `hasCachedTree(for:)` helper may be removed if no non-UI caller remains after the subordinate
button is deleted.

### 4. Contextual recovery remains distinct from the persistent control

The living-view storm guard may continue to display its contextual `Full Rescan` recovery action.
That control explains and resolves a particular safety condition; it is not a second persistent
choice in the volume scan-control area. The new invariant is scoped to the sidebar's normal scan
control and does not weaken the existing storm guard.

### 5. Completed status belongs to one operation

`lastScanSummary`, `scanProgress` counters, and `scanProgress.elapsedTime` describe the most recently
completed warm or cold scan. A living-view subtree apply mutates the already displayed tree but is
not a new scan: it reports recency through `lastLiveApplyAt` and the living-view row, and must not
replace only `lastScanSummary` while leaving the older scan's counters and elapsed time visible.

A successful warm scan publishes its measured elapsed time into `scanProgress` at the same boundary
that publishes the warm summary. The sidebar renders elapsed time once, inside that operation-owned
summary, rather than repeating a separately sourced elapsed line below it. This preserves both facts
in the reported case: the cold cache rebuild took 30.7 seconds, and a later living apply completed
independently without pretending those values belonged to one operation.

## Risks / Trade-offs

- **Equivalent paths compare unequal.** Volume roots can differ syntactically through trailing
  separators or URL normalization. Centralize the ownership comparison and cover root and
  non-root-volume examples instead of comparing ad hoc strings in the view.
- **A selected-volume switch leaves old content visible briefly.** The control intentionally follows
  the selection and becomes `Scan Volume`; it must not imply that the visible old tree belongs to the
  new volume. This change does not redesign the main content's cross-volume transition.
- **Users lose a perceived manual refresh action.** That action was not semantically distinct once
  automatic refresh and living-view apply owned freshness. The remaining `Full Rescan` is explicit
  about its higher-cost behavior.
- **Busy-state precedence could obscure an unusual overlapping flag.** Scan and live apply are
  supervised as mutually exclusive, but the resolver's priority is deterministic and tests will pin
  the result if defensive overlap occurs.

## Migration Plan

1. Add the pure control-state decision and ownership tests.
2. Replace the two-button stack in `VolumePickerView` with the one state-driven button.
3. Remove cache-existence-based presentation code that no longer has a caller.
4. Verify first launch, cache restore, automatic refresh, volume switching, full rescan, and live
   apply through focused and full-suite tests.

No cache or settings migration is required. Rolling back restores the previous view wiring without
changing persisted data.

## Open Questions

None. The product rule is fixed: no matching displayed tree means `Scan Volume`; a matching displayed
tree means `Full Rescan`; active automatic work temporarily owns the same control.
