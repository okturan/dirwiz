# Fix Firmlink Double-Traversal on Root-Volume Scans

## Why

Scanning `/` traverses firmlinked directories twice — once at their familiar path (`/Applications`) and again under the Data volume (`/System/Volumes/Data/Applications`) — because the two report **different inodes** to `getattrlistbulk`, so the `(dev, inode)` visited-set guard never matches them. Two user-visible defects follow, both measured on a real 4.45M-item scan:

- **A directory's bytes get counted twice.** `/Applications` = 48.4 GB and `/System/Volumes/Data/Applications` = 47.4 GB were both fully enumerated and both summed into the root total — roughly 47 GB of double count from that one path.
- **Which path "wins" is a race, so content lands under the wrong name.** In the same scan `/Library` came back **0.0 GB with no children** while its real 92.6 GB sat under `/System/Volumes/Data/Library`; likewise `/System/Library/AssetsV2` was empty with its 47.8 GB under the Data path. A user looking for `/Library` finds it apparently empty. Because it depends on which worker claims the inode first, results differ between runs of the same scan.

The `(dev, inode)` guard was designed for exactly this and silently does nothing here: `stat` resolves `/Applications` to inode `283981561`, but the directory entry `getattrlistbulk` returns while enumerating `/` carries the firmlink's synthetic id `1152921500311879701` (`0x0FFFFFFF00000015`). Real inode vs synthetic id never compare equal, so both subtrees are enqueued.

macOS publishes the mapping authoritatively in **`/usr/share/firmlinks`** (19 tab-separated `<system path>\t<data-relative path>` rows), so this does not need inode-range heuristics.

## What Changes

- The scanner learns about firmlinks and counts each firmlinked subtree exactly once, at its `/`-side path (`/Applications`, `/Library`, `/Users`, …) — the name users expect — rather than whichever path won the race.
- Content on the Data volume that is *not* firmlinked (e.g. `.Spotlight-V100`, `.fseventsd`, `MobileSoftwareUpdate`) keeps being counted; measured at 0 bytes on the probe machine, but it must not be silently dropped.
- Applies only when both sides are inside the scan root (i.e. whole-volume `/` scans). Scanning `/System/Volumes/Data` directly, or any subtree, is unaffected.
- Totals will drop on root-volume scans, and some directories will report *more* than before (the ones that were losing the race). Warm-start caches from before the change stay valid — this is traversal behavior, not node layout.
- **Explicitly out of scope**: the remaining gap between the summed total and `statfs` physical usage. That is inherent to summing per-file allocated sizes when APFS clones and hardlinks share blocks (measured 31.0 GB from duplicate `(dev, inode)` alone), is not a traversal defect, and every treemap tool has it. Reporting shared-byte totals honestly in the UI is tracked separately.

## Capabilities

### New Capabilities
- `firmlink-aware-traversal`: single-counting of firmlinked directories on whole-volume scans, deterministic path attribution, and preservation of non-firmlinked Data-volume content.

### Modified Capabilities
None — no baseline specs exist yet.

## Impact

- **DirWizCore**: `FileScanner` gains a firmlink table loaded once per scan (parsed from `/usr/share/firmlinks`, absent/unreadable → feature disables itself and today's behavior stands) and consults it when enqueueing directories; `VisitedDirectories` stays as the loop guard it already is.
- **Tests**: the existing `(dev, inode)` guard has no coverage for the synthetic-id case. New tests must pin single-counting and, critically, **deterministic attribution** — the current bug is racy, so a test that only asserts a total would pass intermittently against the unfixed code.
- **Docs**: CLAUDE.md's scanner section should record why the `(dev, inode)` guard is insufficient for firmlinks, so the mechanism isn't rediscovered.
