# Defer Ephemeral Roots in the Warm Patch

## Why

A real-volume diagnostic on an idle machine (loadavg 1.59, three production-planner warm
decisions, three replays each) found one root dominating every patch:

| Workload | Roots | Staged items | Largest root | Share |
| --- | ---: | ---: | --- | ---: |
| 1 | 6 | 359,827 | `/private/var/folders/.../T` (151,609) | 42.13% |
| 2 | 19 | 359,876 | same | 42.13% |
| 3 | 7 | 292,853 | same | **51.77%** |

That directory is the per-user Darwin temp directory. It was initially suspected to be the
benchmark measuring its own `TreeCache` scratch, since the harness places it there. It is not:
watched for 60 s with no benchmark running, its own mtime changed 6 times (roughly every 10 s)
across 12,250 direct children, with zero net entry change, meaning transient files appearing
and disappearing between samples. Its direct child count rose from 12,250 to 12,288 during
this investigation.

So this is not an artifact. It is a permanent fixture of every macOS machine: a directory that
changes every few seconds and holds ~151,600 items. DirWiz therefore re-enumerates ~151,600
temp files on **every** warm patch, forever, for every user, and that is 42-52% of all staged
work.

The cost is worth removing precisely because the value is near zero. A user cares what their
temp directory *costs* (it can be many gigabytes, which is exactly the kind of thing a disk
analyzer should reveal). Nobody needs it accurate to the second.

Removing it from the patch is worth as much as a large throughput win:

| Workload | Staged now | Without the temp root | Patch time |
| --- | ---: | ---: | --- |
| 1 | 359,827 | 208,218 (-42%) | 2.03 s -> ~1.18 s |
| 2 | 359,876 | 208,267 (-42%) | 2.02 s -> ~1.17 s |
| 3 | 292,853 | 141,244 (-52%) | 1.66 s -> ~0.80 s |

For context on why that matters: Phase A runs at 176,900 items/sec against the cold scan's
179,800, so it is already at full scanner throughput and cannot be made faster by better
patching. Excluding one directory achieves most of what a 2x to 3.6x throughput improvement
would have, which is the sub-second target `batched-subtree-splice` chased and could not reach.

Note also what the diagnostic did NOT reproduce: root counts were 6, 19 and 7, nowhere near
the 48-root cap. The earlier observation that the cap forces cold fallbacks came from a loaded
machine, which is the same load that made those timings unusable. `retire-root-count-cap` is
therefore resequenced after this change, and its item-threshold derivation depends on this one
anyway, because this changes what `estimatedPatchItems` counts.

## What Changes

**Defer, do not skip.** A two-tier patch: resolve and splice the non-ephemeral roots first so
the interactive result lands fast, then sweep the ephemeral roots on a trailing lower-priority
pass. This is the whole reason to prefer deferral over exclusion: `Tests/SubtreeRescanTests.swift`
and `Tests/WarmStartTests.swift` pin `patched-tree ≡ fresh-cold-scan`, CLAUDE.md is explicit
that the gate must survive, and a trailing pass keeps it true at quiescence. Skipping outright
would break that equivalence by design and force the gate to be rescoped, which is a far worse
trade than a second pass.

- Identify ephemeral roots from the OS, not from hardcoded strings: `confstr` with
  `_CS_DARWIN_USER_TEMP_DIR` and `_CS_DARWIN_USER_CACHE_DIR`. Same discipline as
  `FirmlinkTable` parsing macOS's own `/usr/share/firmlinks` rather than guessing.
- Cold scans are UNCHANGED and keep counting these directories in full, so totals stay honest.
  This changes patch scheduling only.
- The trailing pass must be cancellable and must not fight `LiveRefreshPolicy`.

## Impact

- Warm patch roughly halves on real workloads, with no throughput work required.
- **The dangerous part, and the one to get right first: the persisted `lastEventId` must not
  advance past deferred work.** `TreeCache` stores the tree plus the FSEvents id it is current
  as of. If a patch defers the temp subtree and then saves the cache with the newer id, the
  next warm start replays from that id, never learns the temp subtree was stale, and the
  staleness becomes permanent and invisible. That is a silent-wrong-totals bug of exactly the
  class the firmlink work already fixed once. Either hold the id back to the deferred work's
  horizon, or do not persist until the trailing pass completes.
- Path-form landmine, and it will fail silently rather than loudly: `confstr` returns
  `/var/folders/<...>/T/` with a TRAILING SLASH, while FSEvents reports
  `/private/var/folders/<...>/T`. `/var` is a firmlink to `/private/var`. Compare canonicalised
  paths with the slash normalised, or the match never fires and the change appears to do
  nothing.
- Honesty requirement: while a subtree is deferred it is stale. Per this repo's "never silent"
  discipline, that must be representable rather than presented as fresh.
- Out of scope: making Phase A faster (`mount-aware-traversal`, `searchfs-catalog-scan`).
- **Sequencing correction (2026-07-31):** this proposal placed `retire-root-count-cap` after the
  ephemeral work, and that was wrong. `throttled-ephemeral-sweep` later measured collapsed roots
  of 84/99/131 at 1/5/15-minute holdbacks, against a cap of 48 that `decide` checks BEFORE its
  item budget, so the cap blocks any throttled sweep. The 6/19/7 root counts that justified
  deprioritising the cap were measured on live patches at a ~10-second cadence and do not
  generalise to accumulated intervals. The cap work now comes first.
