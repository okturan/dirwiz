# Design — Firmlink-Aware Traversal

## Context

`FileScanner` guards against firmlink/hardlink loops with `VisitedDirectories`, a thread-safe set of `(dev, inode)` pairs consulted before enqueueing any subdirectory (`FileScanner.swift`, the `visited.insert(dev:inode:)` call sites in both the raw and deferred enumeration paths). For hardlinked directories and repeat mounts it works.

It cannot work for firmlinks, because the two sides report different identities:

```
stat /Applications                       -> dev=16777233  ino=283981561
getattrlistbulk entry for "Applications"
  while enumerating "/"                  -> ino=1152921500311879701  (0x0FFFFFFF00000015)
stat /System/Volumes/Data/Applications   -> dev=16777233  ino=283981561
```

The `/`-side directory entry carries a **synthetic firmlink id** (`0x0FFFFFFF00000000 + n`), not the target's real inode. `283981561 != 1152921500311879701`, so `visited.insert` returns true for both and both subtrees are enumerated. Note `dev` is identical on both sides — firmlinks deliberately present the Data volume under the System volume's device — so a `du -x`-style "don't cross devices" rule cannot distinguish them either.

Measured consequences on a real 4.45M-item scan of `/`:

| path | reported |
|---|---|
| `/Applications` | 48.4 GB |
| `/System/Volumes/Data/Applications` | 47.4 GB (**both fully enumerated → ~47 GB double counted**) |
| `/Library` | **0.0 GB, no children** |
| `/System/Volumes/Data/Library` | 92.6 GB (**content stranded under the wrong path**) |
| `/System/Library/AssetsV2` | 0.0 GB |
| `/System/Volumes/Data/System/Library/AssetsV2` | 47.8 GB |

Two distinct failure modes from one cause: sometimes *both* sides enumerate (double count), sometimes one wins and the other is left empty (misattribution). Which happens depends on which worker reaches the inode first, so it varies run to run.

## Goals / Non-Goals

**Goals:**
- Count each firmlinked subtree once.
- Attribute it deterministically to the `/`-side path users recognise.
- Keep counting non-firmlinked Data-volume content.
- Degrade to today's behavior if the firmlink table is unavailable.

**Non-Goals:**
- Closing the remaining gap to `statfs` physical usage. After removing the duplicate the tree still exceeds physical usage, because summing per-file `allocatedSize` counts APFS-clone and hardlink bytes once per reference — 31.0 GB from duplicate `(dev, inode)` alone, on this machine. That is inherent to the measure, shared by every treemap tool, and is a *reporting* question, not a traversal bug.
- Changing `VisitedDirectories`, which still earns its keep as the loop guard.
- Any change to warm start's node layout or cache format — this is traversal only, so existing caches stay valid.

## Decisions

1. **Use the OS's own table, not an inode heuristic.** `/usr/share/firmlinks` is tab-separated `<system path>\t<data-relative path>` (19 rows on macOS 15). Parse it once per scan into the set of absolute Data-side paths `"/System/Volumes/Data/" + target`.
   - *Alternative considered — detect the synthetic id range* (`ino >= 0x0FFFFFFF00000000`): rejected. It works today but is an undocumented encoding that Apple can change silently, and a false positive would make the scanner skip real content. The table is the supported contract.
   - *Alternative considered — resolve every directory with `lstat` before the visited check*: rejected. Correct, but an extra syscall per directory across hundreds of thousands of directories, to fix a 19-entry problem.
2. **Skip the Data-side copy, keep the `/`-side path.** When a directory about to be enqueued has an absolute path in the skip set, drop it. This makes attribution deterministic and preserves familiar names. The inverse (skip the firmlinks, keep Data paths) would count correctly but display `/System/Volumes/Data/Users/...`, which is worse for users.
3. **Only skip when the `/`-side path is inside the scan root.** Guard on the scan root actually containing both, so scanning `/System/Volumes/Data` (or any subtree) directly still enumerates everything. Without this the feature would silently hide content from a legitimate scan.
4. **Fail open.** A missing, unreadable, or malformed table yields an empty skip set and today's exact behavior. This must never be the reason a scan loses data.
5. **Load once per scan, not per directory.** The set is built alongside the other per-scan setup (case-sensitivity probe, volume stats) and passed down with `visited`.

## Risks / Trade-offs

- [Totals drop on root scans; users may read it as a regression] → it is a correction, and the direction is defensible: the old number exceeded what the volume can physically hold. Worth a release-note line.
- [Some directories grow (the ones previously losing the race)] → intended; `/Library` going from 0 bytes to its real size is the fix, not a side effect.
- [The skip set is macOS-version-dependent] → it is read from the running OS at scan time, so it tracks whatever that OS declares; nothing is compiled in.
- [A firmlink target that is itself unreadable at the `/`-side path] → then we skip the Data copy and count nothing, under-reporting. Mitigation: only add a target to the skip set when the `/`-side path is statable; otherwise leave both and accept today's behavior.

## Migration Plan

Pure traversal change; no persisted format touched, warm-start caches remain valid. Rollback is a revert. Worth an env kill-switch (`DIRWIZ_NO_FIRMLINK_DEDUP=1`) matching the repo's existing `DIRWIZ_*` escape hatches, so a user on an exotic setup can restore old behavior without a rebuild.

## Open Questions

- Should the UI surface that firmlinked content is shown at its system path (a tooltip on `/Applications` etc.)? Probably unnecessary — the point is that it now matches what Finder shows.
