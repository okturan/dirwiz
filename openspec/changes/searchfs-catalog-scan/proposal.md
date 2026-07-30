# searchfs Catalog Scan

## Why

The cold scan is 96.4% filesystem syscalls: 52.2% `getattrlistbulk`, 44.2% `open`, with only
about 2.5 s of user CPU in a 20 s scan. Both of those costs exist because we walk the tree
ourselves, one directory at a time, opening each by full path.

`searchfs(2)` asks the filesystem driver to search a whole volume and return attributes in
batches. It is a legacy Darwin syscall, and the common belief is that APFS dropped it. That
belief is wrong, and it was worth checking: this is the closest thing macOS has to reading
the NTFS Master File Table, which is exactly the capability DirWiz's own marketing says the
platform lacks.

Measured on this machine (Data volume, 5,175,927 records):

| Property | Result |
| --- | --- |
| `VOL_CAP_INT_SEARCHFS` on `/`, Data, home | YES, with the valid bit set |
| Records returned | name, fileID, parentID, objtype, and sizes |
| Path reconstruction correctness | 400 of 400 sampled paths verified against `lstat`, 0 type mismatches, 0 missing |
| Tree connectivity | 1 orphan in 5,175,927; 0 cycles; average depth 10.0, max 29 |
| Reconstruction cost | 0.12 s to build the id map, 0.30 s to resolve every path |
| Memory for the full record set | 412 MB (records 118, names 101, map 192) |
| Hardlinks | surface as 50,289 duplicate file IDs, which is usable signal rather than a defect |
| Under continuous catalog mutation | completed cleanly, no `EBUSY`, paths still verified |
| Items found | 5,684,648 across both volumes, versus 4,703,194 from our traversal |

Two structural facts, both confirmed: it is per-VOLUME rather than per-path (a `/` scan is one
search of the System volume and one of the Data volume, which maps cleanly onto the firmlink
structure we already handle), and the requested attribute set does not affect completeness.

What is NOT established is the only number that decides adoption: wall clock. Timings for the
identical operation drifted from 26.9 s to 54.6 s purely as unrelated load accumulated on the
machine, so no honest comparison against the 20.3 s traversal baseline was possible. That
measurement is this change's gate, and it must be taken on an idle machine.

The reason to spec this BEFORE `descriptor-relative-traversal` is that searchfs removes both
the opens and the bulk calls, while openat only reduces the cost of the opens. If searchfs
wins, the openat work (which rewrites the scanner's parallel decomposition, the component
every other feature depends on) is unnecessary. Measuring first is much cheaper than
rewriting first.

## What Changes

- A whole-volume scan path that calls `searchfs` once per volume in the scan's scope,
  collects flat records, and builds the `FileTree` from parent IDs instead of by traversal.
- Volume discovery for a root scan: enumerate the volumes reachable under the scan root and
  search each. The System/Data pair is the normal case.
- Aggregation stays ours: sizes are summed up the reconstructed tree with the existing
  `propagateSizes`/`recomputeAggregates` code, and inode-shared blocks are counted once using
  the duplicate file IDs the search already surfaces.
- Traversal is NOT removed. `searchfs` cannot scope to a subfolder, so folder scans keep the
  existing scanner. That means two code paths, which is a real cost and must be weighed
  honestly against the win rather than hidden.
- Capability gating and fallback: check `VOL_CAP_INT_SEARCHFS` at runtime, and fall back to
  traversal on any doubt (capability absent, error, suspiciously low record count). A wrong
  or partial answer is worse than a slower correct one.
- `DIRWIZ_NO_SEARCHFS=1` forces the traversal path, matching the repo's habit of shipping an
  escape hatch beside a scanner change.
- Out of scope: replacing the warm-start patch path, and folder-scoped scans.

## Impact

- If wall clock wins, this is the largest cold-scan change available, because it deletes the
  work rather than optimising it.
- Even if wall clock only ties, it may still be worth adopting: the search runs on ONE thread
  where traversal saturates six to eight. That is the difference between a scan the machine
  notices and one it does not, which matters directly on a laptop and is the complaint that
  started this work.
- Possible accuracy gain: the search returned about 981,000 more items than traversal, most
  plausibly content inside the 358 protected directories traversal cannot enter. If that is
  the explanation, totals get MORE accurate, not less. It must be confirmed rather than
  assumed, because the alternative explanations (snapshot records, duplicate link entries)
  would mean over-counting.
- Risk: a second scanner to maintain, an unusual and lightly documented syscall, and totals
  that must be proven equivalent to traversal before they can be trusted.
