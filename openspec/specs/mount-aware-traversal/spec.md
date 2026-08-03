# mount-aware-traversal Specification

## Purpose
Device-boundary traversal scopes: individual volumes stay isolated at mount points, All Volumes combines only by explicit selection, and every cold, warm, and living rescan honors the tree's recorded scope.
## Requirements
### Requirement: An individual volume scan stays on the scan root's device

The scanner SHALL use the scan root's device identity as the default traversal boundary and SHALL
NOT descend into a directory on a different device unless a cross-mount scope is explicitly active.

#### Scenario: A foreign mount is nested below the selected volume

- **WHEN** an encountered directory's device differs from the known scan-root device
- **AND** the scan scope is an individual volume
- **THEN** the scanner keeps the mount-point directory but skips its descendants
- **AND** the foreign mount's contents do not contribute to the selected volume's totals

#### Scenario: The macOS System and Data roots share a device

- **WHEN** a root-volume scan reaches `/System/Volumes/Data`
- **AND** that directory reports the scan root's device
- **THEN** traversal continues so the macOS volume group remains complete

#### Scenario: A foreign volume is itself the scan root

- **WHEN** the user selects and scans that mounted volume directly
- **THEN** its device becomes the traversal boundary
- **AND** that volume is scanned normally

### Requirement: Combined traversal is explicit and discoverable

The volume picker SHALL offer an explicit combined-volume selection when at least two eligible local
volumes are mounted, and SHALL keep individual-volume selection as the default.

#### Scenario: A second drive is attached

- **WHEN** an individual volume is selected or displayed
- **AND** another eligible local drive is mounted
- **THEN** the volume list refreshes and offers **All Volumes**
- **AND** the existing individual selection and traversal scope remain unchanged

#### Scenario: The user chooses the combined view

- **WHEN** the user selects **All Volumes**
- **THEN** the scan control clearly offers to scan all volumes
- **AND** the resulting tree intentionally traverses mounted filesystems beneath the root
- **AND** the UI identifies that tree as a combined view rather than as an individual Macintosh HD scan

#### Scenario: Only one eligible volume is mounted

- **WHEN** the refreshed volume list contains fewer than two eligible local volumes
- **THEN** the combined-volume selection is not shown
- **AND** the remaining volume is selected individually

#### Scenario: The app relaunches after a combined scan

- **WHEN** the previous session explicitly selected the combined view
- **THEN** the next launch does not silently make combined traversal the default
- **AND** an individual volume remains the automatic selection unless the user chooses combined again

### Requirement: Scan ownership includes traversal scope

The system SHALL treat scan-root path and mount-traversal scope together as the identity of a
displayed or persisted tree, including caches, checkpoints, session navigation, and scan history.

#### Scenario: Individual and combined trees both use `/`

- **WHEN** the selected scope and displayed tree share root path `/` but have different mount scopes
- **THEN** the scan control offers the selected scope's normal scan action
- **AND** it does not mislabel the other scope's tree as eligible for **Full Rescan**

#### Scenario: A cache exists for the other scope

- **WHEN** an individual `/` scan looks up a cache created by a combined `/` scan, or vice versa
- **THEN** that cache is not loaded for the selected scope
- **AND** saving one scope does not overwrite the other scope's cache

#### Scenario: Scope-specific history exists for the same root path

- **WHEN** individual and combined `/` trees create checkpoints, session state, or scan diagnostics
- **THEN** each scope reads and writes its own persistence identity
- **AND** a combined tree cannot restore or overwrite the individual volume's history

#### Scenario: Combined capacity has no single-volume meaning

- **WHEN** a combined tree completes post-scan analysis
- **THEN** it does not record the boot volume's capacity as though it described the combined tree

#### Scenario: A pre-scope cache exists

- **WHEN** a cache from the earlier format does not record mount scope
- **THEN** it is rejected as outdated
- **AND** it cannot restore previously pooled content into an individual-volume view

### Requirement: Mount filtering fails open and has a diagnostic escape hatch

The scanner SHALL preserve unrestricted traversal when the root device cannot be determined or when
`DIRWIZ_CROSS_MOUNTS=1` is set.

#### Scenario: Root device lookup fails

- **WHEN** the scanner cannot determine the scan root's device
- **THEN** it traverses encountered devices rather than risking silent data loss

#### Scenario: Cross-mount override is enabled

- **WHEN** `DIRWIZ_CROSS_MOUNTS=1` is present
- **THEN** directories are not rejected merely because their devices differ from the scan root

### Requirement: Skipped mounts are reported distinctly

The system SHALL count and surface mount-boundary skips separately from permission-denied or
system-protected directories, including sampled paths and why they were excluded.

#### Scenario: A mounted filesystem is excluded

- **WHEN** an individual scan skips a foreign mount point
- **THEN** scan progress records that mount path in the mount-specific count and sample
- **AND** the sidebar explains that mounted filesystems were deliberately kept separate
- **AND** it points to **All Volumes** when that combined choice is available

### Requirement: Cold, warm, and living traversal share the mount boundary

The same tree-owned mount scope SHALL apply to full scans, warm subtree rescans, and living-view
subtree updates.

#### Scenario: A changed path reaches a foreign mount during warm patching

- **WHEN** `rescanSubtrees` encounters a device that an equivalent cold individual scan excludes
- **THEN** the warm path also excludes and reports it
- **AND** the completed warm tree remains equivalent to a fresh cold scan under the same scope

#### Scenario: A foreign mount is itself a changed root

- **WHEN** an FSEvents update resolves directly to an excluded mount-point node
- **THEN** warm/living staging does not bypass the mount boundary by treating that node as a new root
- **AND** the previously empty mount point remains excluded

#### Scenario: A skipped mount is reachable by another eligible path

- **WHEN** a foreign-device occurrence is rejected
- **THEN** its inode is not marked visited merely because of that rejection
- **AND** a separately encountered eligible occurrence may still be traversed

### Requirement: Unavailable selections recover to a truthful individual tree

The application SHALL reconcile volume availability, selected scope, displayed-tree ownership, and
scan work as one state transition when a selected target is no longer available. It SHALL prefer the
boot volume as the individual fallback and SHALL NOT relabel an unavailable or combined tree as that
fallback.

#### Scenario: The remembered volume is absent at launch

- **WHEN** initial volume discovery does not contain the persisted last-scanned individual path
- **THEN** the boot volume is selected in individual-volume scope when it is available
- **AND** a valid exact-scope cache for that fallback is displayed immediately and refreshed
- **AND** if no valid fallback cache exists, an individual scan starts automatically instead of
  leaving an idle empty graph

#### Scenario: The selected individual volume is disconnected

- **WHEN** a mount refresh no longer contains the selected individual volume
- **THEN** active scan work owned by the unavailable target is superseded
- **AND** an already-committing non-cancellable living splice settles before selection and displayed
  ownership switch together
- **AND** the app deterministically selects the boot volume, or the lexicographically first
  normalized available path when the boot volume is absent
- **AND** recovery uses only that fallback's individual cache or a new individual scan

#### Scenario: The combined choice disappears

- **WHEN** the explicit combined view is selected
- **AND** fewer than two eligible local volumes remain
- **THEN** the remaining fallback is selected as an individual volume
- **AND** the old combined tree is not treated as the remaining volume's tree
- **AND** the fallback cache-or-scan recovery behavior is the same as for a disconnected individual

#### Scenario: An unrelated volume changes while the selection remains valid

- **WHEN** mount availability changes but the selected individual volume is still present
- **THEN** its selection, scope, displayed tree, and active scan remain unchanged
- **AND** the app does not automatically rescan merely because another drive appeared or disappeared

#### Scenario: No eligible local volume exists

- **WHEN** availability reconciliation yields no individual volume
- **THEN** the selected target is cleared
- **AND** no recovery scan is started for an invented or unavailable path

#### Scenario: Fallback persistence waits for completion

- **WHEN** recovery begins for an available fallback volume
- **THEN** the previously persisted last-scanned path is not replaced merely by selecting or starting
  the fallback
- **AND** it changes only after a fallback scan completes successfully
- **AND** the AppState-visible completed state is not published before that successful ownership
  write
