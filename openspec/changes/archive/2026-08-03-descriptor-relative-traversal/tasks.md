# Tasks - Descriptor-Relative Traversal

## 1. Prove the premise before rewriting anything

- [ ] 1.1 Microbenchmark, outside the app: walk a large real subtree twice, once opening each
      directory by full path and once with `openat` relative to its parent, same attribute
      set both times. Report the delta.
- [ ] 1.2 STOP CONDITION: if `openat` does not show a clear win at realistic depth, this
      change is not worth its risk. Report the numbers and stop. The 44% figure says where
      time is spent, not that this specific fix recovers it, and that distinction is the
      whole reason this task exists first.
- [ ] 1.3 Record the descriptor cost: peak open descriptors for a depth-first walk at the
      real tree's depth distribution, so the bound in 3.3 is derived rather than guessed.

## 2. Baseline the behaviour that must not change

- [ ] 2.1 Characterization test: on a fixture with firmlink-style duplicates, protected
      directories, hardlinks, bundles and deep nesting, pin the exact resulting tree (paths,
      sizes, counts, skipped-directory count, link-count flags).
- [ ] 2.2 Record current cold-scan timings on `/` at 4, 6 and 8 workers, best-of-N, as the
      comparison the rework must beat.

## 3. Subtree-claiming workers (DirWizCore)

- [ ] 3.1 Replace the per-directory queue with a subtree work queue: a unit of work is a
      directory plus an open descriptor for it, and the worker owns that subtree.
- [ ] 3.2 Depth-first walk per claimed subtree with an explicit descriptor stack, opening each
      child directory via `openat` relative to its parent. Close descriptors on the way back
      up, deterministically, including on every early-exit and cancellation path.
- [ ] 3.3 Bound the stack from the descriptor limit actually obtained after raising
      `RLIMIT_NOFILE`, divided across workers with headroom. On exceeding the bound, fall back
      to a full-path `open` for that directory rather than failing.
- [ ] 3.4 Work stealing: a worker on a large subtree publishes sibling subtrees back to the
      queue so the pool stays busy. Measure the tail specifically; a scan whose last seconds
      run single-threaded on the deepest branch would erase the win.
- [ ] 3.5 Build reporting paths from the descriptor stack's ancestor names, so no full-path
      lookup is reintroduced through the back door.

## 4. Preserve every downstream contract

- [ ] 4.1 Firmlink deduplication still gates on the scan root and still skips Data-side paths,
      in both `scan` and `rescanSubtrees`.
- [ ] 4.2 Skipped-directory counting and paths unchanged, including the permission-denied case.
- [ ] 4.3 `ATTR_FILE_LINKCOUNT` capture and `linkCountsCaptured` unchanged; hardlink groups
      still populate identically.
- [ ] 4.4 Bundle deferral unchanged: bundles stay opaque leaves during the scan.
- [ ] 4.5 Cancellation remains responsive at a comparable cadence, and a cancelled scan leaves
      no leaked descriptors. Assert the descriptor count returns to baseline.
- [ ] 4.6 Live materialisation still publishes progressively; depth-first changes the ORDER
      tiles appear in, so confirm the live view still fills in sensibly rather than finishing
      one branch at a time. This is a judgement call about feel, so look at it, do not only
      test it.
- [ ] 4.7 Never `reserveCapacity(count + smallDelta)` on a per-directory path; the O(n^2)
      landmine is easy to reintroduce while restructuring enumeration.

## 5. Gates

- [ ] 5.1 2.1's characterization test passes unmodified. A diff in the resulting tree is a
      STOP.
- [ ] 5.2 Warm-start equivalence suites green: patched tree ≡ fresh cold scan.
- [ ] 5.3 Cold scan on `/` beats 2.2's baseline at the same worker count, best-of-N, reported
      as a table with the worker sweep. Report the honest number even if it undershoots the
      hoped-for figure.
- [ ] 5.4 Full suite three times plus one CI-parity run.
- [ ] 5.5 CLAUDE.md: record that the scanner is now per-worker depth-first with a descriptor
      stack, why (44% of samples in `open`, redundant ancestor resolution), and that the
      attribute-set boundary was deliberately not crossed.

## 6. Follow-on, separate and small

- [ ] 6.1 Revisit the default worker count with the new decomposition. The old knee (six on
      this machine, IPC 2.20 at four falling to 0.98 at ten) was measured against path-based
      opens and will move once the kernel path-lookup contention is reduced.

### Closure (2026-08-03)
Archived unstarted as deferred exploration, not planned work. A hardening idea with no current driver; revisit only with a concrete incident. No spec delta is synced.
