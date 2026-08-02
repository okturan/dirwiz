# Mount-Aware Traversal and Explicit Combined View

## Why

The sidebar presents mounted volumes as separate scan targets, but a scan rooted at `/` currently
walks straight through foreign filesystems mounted below it. Plugging in an external SSD can
therefore add that SSD to the already-displayed boot-volume graph during a scan or living refresh.
That breaks the selection model: choosing one drive does not actually mean one drive.

The failure is recorded on this machine, not inferred. The cached `/` tree saved on 2026-08-01
contains 5,889,027 items and the UI reports 6.27 TB, while `df` reports the selected root filesystem
as 995 GB. The same screenshot shows the attached Samsung8TB contributing 5.34 TB beneath
`/Volumes`, which accounts for the impossible pooled total.

Foreign mounts also make ordinary single-volume totals misleading in smaller ways. Mounted disk
images can be counted once as the image file and again as the mounted view, while Simulator and
Update volumes add content that does not belong to the selected filesystem.

Pooling is still useful when it is intentional. With several drives attached, an explicit combined
map is a good overview. The defect is making that the implicit consequence of selecting one volume
or hot-plugging another.

There is a second lifecycle defect at the other edge of the same model. When the selected external
volume is later disconnected, `VolumePickerView` currently changes the selected row to another
volume but does not reconcile the displayed tree. On relaunch, `restoreOnLaunch()` returns early
when the remembered path is absent; the later volume-list refresh selects a fallback row but leaves
the app idle with no graph. A combined tree can likewise remain owned by the old scope after the
combined option disappears. Selection, display ownership, and recovery must change together.

## What Changes

- A normal volume scan uses the scan root's device identity as its traversal boundary, matching
  `du -x`. The macOS System/Data volume group remains complete because both paths report the same
  device identity on this machine.
- A foreign mount remains visible as a mount-point directory, but DirWiz does not descend into it or
  add its contents to the selected volume's totals.
- When two or more eligible local volumes are present, the sidebar offers a distinct **All Volumes**
  row with copy explaining that it produces one combined map. It never replaces or silently changes
  the selected individual volume.
- Selecting **All Volumes** is the only product UI path that intentionally restores cross-mount
  traversal. Its scan/cache scope is distinct from an individual `/` scan, so the two trees cannot
  be mistaken for one another.
- Mount/unmount notifications refresh the volume list. Hot-plugging a drive can reveal the combined
  option, but cannot select it or mutate an individual scan into a combined one.
- Skipped mounts are reported separately from permission-denied/system-protected directories, with
  a pointer to the explicit combined option.
- `DIRWIZ_CROSS_MOUNTS=1` remains a diagnostic escape hatch that reproduces unrestricted historic
  traversal.
- The tree-cache format records traversal scope and changes version, preventing a previously pooled
  `/` cache from being restored as an individual-volume tree.
- If an individual selection disappears, or an explicit combined selection ceases to be available,
  the app falls back to an available individual volume as one recovery transaction. It prefers the
  boot volume, restores that volume's exact-scope cache immediately when possible, and otherwise
  starts a truthful individual scan instead of leaving an idle blank graph.

## Impact

- Selecting Macintosh HD or an external volume means that filesystem only, both for a cold scan and
  for warm/living updates.
- Attaching a new SSD no longer causes an existing graph to jump by terabytes.
- Users with several volumes retain the useful pooled overview, but choose it deliberately through a
  clearly labelled row.
- Existing pooled caches are invalidated once by the cache-format change. That first scan is cold;
  later scans can warm-start within the same scope.
- Disconnecting a selected drive cannot relabel its old tree as another drive. The app either shows
  the fallback volume's own cached tree while refreshing it or visibly scans that volume from
  scratch.
- No firmlink behavior changes. Firmlinks share a device ID and remain covered by the separate
  `FirmlinkTable` mechanism.
