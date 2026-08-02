# Design: Mount-Aware Traversal and Explicit Combined View

## Evidence and boundary

The 2026-08-01 `/` cache has 5,889,027 nodes. The displayed tree in the supplied screenshot is
6.27 TB while the selected root filesystem reports 995 GB. The screenshot also places a 5.34 TB
Samsung8TB subtree below `/Volumes`. This is direct evidence that root traversal crossed into the
newly mounted SSD.

Current device identities confirm the safe default boundary:

| Path | Device | Default result |
| --- | ---: | --- |
| `/` | 16777233 | scan root |
| `/System/Volumes/Data` | 16777233 | include |
| `/System/Volumes/Update` | 16777234 | exclude |
| `/Library/Developer/CoreSimulator/Volumes/iOS_24A5355p` | 16777239 | exclude |

The external SSD was unmounted by the time implementation began, so its device number is not
invented here. Its foreign-device status is established by being a separately mounted filesystem;
the deterministic tests inject the exact differing-device shape.

## Decisions

### 1. Scope belongs to the tree

`FileTree` records whether it was built as an individual volume, a user-selected combined view, or
the unrestricted diagnostic override. Cold scan sets it once before materialization. Every subtree
rescan reads the tree's scope rather than the scratch scanner's default, so warm start and living
refresh cannot drift from the displayed tree.

### 2. The traversal gate returns a reason

`VisitedDirectories` remains the single enqueue gate, but returns a decision instead of a Boolean.
That lets callers distinguish a mount-boundary rejection from firmlink/inode deduplication and
increment the mount-specific progress counter. A rejected foreign inode is never inserted.

A changed root is checked against the tree-root device before Phase A is seeded. This closes the
otherwise easy bypass where the mount point itself becomes a subtree-rescan root.

### 3. Combined view is an explicit session choice

The sidebar shows an **All Volumes** row only with two or more eligible local volume rows. Selecting
it points the scan at `/` and chooses combined traversal; selecting any volume row returns to
individual traversal. Mount notifications refresh availability but never select combined mode.

Combined mode is intentionally not persisted as the next-launch default. This makes “one selected
drive means one drive” stable across relaunches and hot plugs.

### 4. Path alone no longer establishes ownership

An individual boot-volume tree and a combined tree both have root path `/`. The state-driven scan
control therefore compares `(normalized root path, traversal scope)`. Only an exact match becomes
**Full Rescan**; a scope switch uses the normal scan action and copy for that scope.

### 5. Cache format and key include scope

TreeCache v3 stores the scope byte and includes scope in the cache filename key. The version bump
rejects v2 trees whose scope is unknowable, which is required because the existing `/` cache is
known to contain pooled external content. Separate keys let individual and combined caches coexist.

The same scope-qualified identity separates timeline checkpoints, exploration sessions, and warm
start diagnostics. Snapshot metadata still records the real root path; the qualified token is only
an on-disk namespace. Selected-volume identity stays byte-for-byte equal to the old root-path key so
existing individual history remains available. Combined mode does not write Storage Trends because
the current trend schema describes one volume's capacity, not an aggregate of several drives.

### 6. Reporting is separate from permissions

`ScanProgress` has a mount-specific exact count and capped path sample. The sidebar renders it as
quiet information: mounted filesystems were kept separate, not denied by macOS. Permission skips
and Full Disk Access messaging remain unchanged.

### 7. Local delivery does not publish artifacts

The repository instruction will require a local app build/install after user-facing changes so UI
verification exercises current source. That local app is not uploaded, attached to a GitHub release,
or represented as the public release; publishing remains a separately authorized release workflow.
