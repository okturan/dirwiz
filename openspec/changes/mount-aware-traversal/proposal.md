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

## Impact

- Selecting Macintosh HD or an external volume means that filesystem only, both for a cold scan and
  for warm/living updates.
- Attaching a new SSD no longer causes an existing graph to jump by terabytes.
- Users with several volumes retain the useful pooled overview, but choose it deliberately through a
  clearly labelled row.
- Existing pooled caches are invalidated once by the cache-format change. That first scan is cold;
  later scans can warm-start within the same scope.
- No firmlink behavior changes. Firmlinks share a device ID and remain covered by the separate
  `FirmlinkTable` mechanism.
