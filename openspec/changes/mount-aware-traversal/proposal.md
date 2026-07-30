# Mount-Aware Traversal

## Why

This is a correctness bug that also costs time.

`VisitedDirectories` deduplicates by `(device, inode)` but never rejects a foreign device
(FileScanner.swift), so a scan of `/` descends into every mounted filesystem underneath it.
The consequences:

- A mounted disk image is counted TWICE: once as the `.dmg` file that actually occupies
  blocks, and again as the mounted volume's contents, which are a view of those same blocks.
  This is the same shape of double count as the firmlink bug, and it is why the reported
  total still exceeds physical capacity after that fix (about 1019 GB on a 926 GB volume).
- A mounted external drive counts against the volume being scanned, which is nonsense: a
  2 TB external cannot occupy space on a 926 GB SSD.
- Measured traversal that is redundant or misattributed, with Simulator runtimes mounted:
  four Simulator images at 477,845 entries (2.6 to 3.2 s), plus `/System/Volumes/Update` at
  118,921 entries (0.9 s). Roughly 600,000 entries, about 13% of the scan.

Device numbers verified on this machine, which is what makes the fix implementable:

| Path | Device |
| --- | --- |
| `/` | 16777233 |
| `/System/Volumes/Data` | 16777233 |
| `/Users` | 16777233 |
| `/System/Volumes/Update` | 16777234 |

The System and Data volumes share a device number, so ordinary `du -x` same-device semantics
KEEP the macOS volume group intact while excluding genuinely separate mounts. This is the
detail that makes the rule safe, and it is the opposite of the firmlink case, where both
sides also share a device and so a mount rule cannot help. The two mechanisms are
complementary and both are needed.

The performance saving is real but conditional on what is mounted: with no Simulator
runtimes mounted it is closer to 1 s, with them it is several seconds. The correctness fix is
unconditional, which is the reason to do it.

## What Changes

- Traversal skips a directory whose device differs from the scan root's device, the standard
  `du -x` rule, with the volume group preserved because it shares a device.
- Skipped mounts are reported, not silently dropped. A user who scanned `/` with an external
  drive attached must be able to see that DirWiz deliberately did not descend into it,
  consistent with the existing skipped-directory honesty (`358 system-protected folders
  skipped`). Silence here would read as missing data.
- Scanning a mount directly still works and scans all of it. Rooting a scan at
  `/Volumes/External` or `/System/Volumes/Data` measures that volume in full; the rule is
  relative to the scan root, never absolute.
- `DIRWIZ_CROSS_MOUNTS=1` restores the old behaviour, matching the repo's habit of shipping
  an escape hatch beside a traversal change (`DIRWIZ_NO_FIRMLINK_DEDUP`).
- Fails open: if the scan root's device cannot be determined, traverse everything exactly as
  today. Losing content is never an acceptable outcome of an optimisation.
- Out of scope: presenting skipped mounts as separate scannable volumes in the sidebar, and
  any change to firmlink deduplication.

## Impact

- The volume total stops exceeding the volume's capacity, which is the headline.
- Cold scan drops by roughly 1 s normally and several seconds with disk images mounted.
- Risk is that "whole disk" semantics must remain honest. The mitigation is that the rule is
  relative to the scan root and the skips are surfaced, so nothing is quietly missing.
