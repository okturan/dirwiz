# Descriptor-Relative Traversal

## Why

The cold scan is kernel-bound, and one specific kernel cost dominates. Sampling eight worker
threads through a full `/` scan (4,703,194 items, 833,566 directories):

| Where the time goes | Share of samples |
| --- | --- |
| `getattrlistbulk` | 52.2% |
| `open` | 44.2% |
| Filesystem syscalls combined | 96.4% |
| Shared-lock waiting | 0.75% |

Total user-space CPU across the best runs is only about 2.5 s of a 20 s scan, so no amount of
Swift-level optimisation can find the missing time. The main thread is asleep throughout, and
the CLI links no Metal at all, so neither UI nor GPU work is involved.

The 44% in `open` is the actionable half. Every directory is opened by its FULL path, so the
kernel re-resolves every ancestor component every time. At 833,566 directories averaging
perhaps eight components deep, that is on the order of 6.7 million path-component lookups,
the overwhelming majority of them redundant re-resolutions of directories we had open
moments earlier. `openat(parentFD, childName)` resolves exactly one component.

Two things this is NOT, both already measured, so neither is worth pursuing:

- It is not per-call buffer economics. 64 KiB, 256 KiB and 1 MiB bulk buffers all measured
  22.3 to 22.8 s, which also means requesting fewer attributes is unlikely to pay and is not
  a reason to disturb the fixed-offset parser.
- It is not worker starvation. Six workers is the efficiency knee on this 4P+6E machine
  (19.44 s mean versus 21.29 s at four); IPC falls from 2.20 at four workers to 1.13 at eight
  and 0.98 at ten, so extra workers buy kernel contention, not throughput.

The real obstacle is architectural, and it is worth stating plainly because it is easy to
misdiagnose as a file-descriptor problem: the scanner is a SHARED WORK QUEUE. A directory
dequeued by a worker has no live parent descriptor, because whichever worker enumerated the
parent has long since finished with it. `openat` needs a parent descriptor to be relative to.
File-descriptor limits are a detail solved by `setrlimit`; the decomposition is the work.

## What Changes

- Workers claim SUBTREES rather than individual directories, and walk each claimed subtree
  depth-first with a bounded stack of open parent descriptors. Every child directory is then
  opened with `openat` relative to its parent, resolving one component instead of the whole
  path. Depth-first also improves locality, since a directory's children are enumerated while
  its metadata is still cache-warm.
- Work stealing keeps the pool busy: one worker landing on a huge subtree must be able to
  hand off sibling subtrees, or the tail of the scan serialises on the deepest branch. This is
  the part that decides whether the change is a win, so it needs measuring, not assuming.
- The descriptor stack is depth-bounded, and `RLIMIT_NOFILE` is raised at startup with the
  bound derived from the limit actually obtained rather than assumed. When the bound is
  reached, fall back to a full-path `open` for that directory: slower for that one node,
  never a failure.
- Full paths are still needed for reporting (skipped directories, rescan targets, the string
  pool). They are constructed from the descriptor stack, which already holds every ancestor
  name, so no extra lookup is required.
- Attribute requests are untouched. This changes HOW a directory is opened, not what is asked
  of it, so the `FSOPT_PACK_INVAL_ATTRS` fixed-offset contract and its parsing tests are
  unaffected. Keeping that boundary is deliberate.
- Out of scope: attribute-set changes, buffer sizing, worker-count defaults (a separate small
  change), and the warm patch path.

## Impact

- If path resolution is most of the 44%, this is the only genuine multi-second cold-scan win
  available. A realistic expectation is that the cold scan lands somewhere around 12 to 15 s
  with this and mount-awareness together, NOT 5 s: 833,566 directories in 5 s would be about
  6 µs per directory including open and enumerate, which is likely below the APFS floor.
  There is no MFT to read on APFS and no public API for a direct b-tree walk, so there is no
  shortcut hiding here. This should be stated up front rather than discovered late.
- Risk is HIGH: this rewrites the parallel decomposition of the scanner, the component every
  other feature depends on. Everything downstream of it (firmlink deduplication, skipped
  directory accounting, link-count capture, bundle deferral, cancellation cadence, live
  materialisation ordering) must be shown to behave identically, not assumed to.
- This is worth doing AFTER the batched splice and mount-awareness, both of which are smaller,
  safer and land larger user-visible wins per unit of risk.
- **Gated behind `searchfs-catalog-scan`.** That change removes both the opens and the bulk
  calls by having the driver walk its own catalog, where this one only reduces the cost of the
  opens. It has been proven to work on APFS and its own gate is a single measurement on an
  idle machine. If it wins, this change is unnecessary, so do not start this rewrite of the
  scanner's parallel decomposition until that measurement has been taken.
