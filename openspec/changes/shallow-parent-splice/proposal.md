## Why

Warm start is effectively dead on real volumes, and every launch silently pays a cold scan.
`WarmStartHistory` shows the last genuine warm admits on Jul 29 (small `~/code` trees); since
then `/` fell back cold with "~92% of files changed" four minutes after a completed full rescan,
and the Samsung8TB volume fell back twice at ~26%, a hair over the 25% gate. A journal probe over
15 minutes of ordinary background activity names the mechanism exactly: with `FileEvents`
granularity, a file event is reduced to its parent directory, so Finder touching
`~/.DS_Store`-class files makes `/Users/okan` a rescan target, and root-level file events make
`/` itself one. `PathCollapse` then swallows every precise deep target beneath those giants, the
estimator charges each root its full cached subtree (~4M items for the home folder ≈ 90%), and
the "/" target independently trips the root-level preflight abandon. Both paths individually
guarantee cold on nearly every launch, and the same reduction feeds the living view's splices.

## What Changes

- Journal replay and the live monitor SHALL distinguish how a directory became a target:
  `directoryEvent` (FSEvents reported the directory itself) versus `parentOfFile` (the target
  exists only because files directly inside it changed).
- A `parentOfFile` target SHALL be treated as SHALLOW: only the directory's own entry level is
  stale. Phase A reads that one level; when the fresh level's name/type sets match the cached
  children, the patch applies in-place metadata updates and never touches child subtrees. Any
  structural difference PROMOTES the target to today's full-subtree semantics.
- The estimator SHALL charge a shallow target its direct child count, not its cached subtree.
- Outermost-root collapse SHALL be kind-aware: a shallow root never claims the precise deep
  targets nested beneath it.
- A shallow target equal to the tree root SHALL be reconcilable (root-level file churn is the
  common case); a deep or promoted root-level target SHALL keep today's cold abandon.
- Unchanged: poison handling, the 25% item gate and its post-Phase-A exact recheck, the 512-root
  backstop, tier budget sharing, the cache-horizon invariant, and the warm-equivalence gate
  (patched ≡ fresh cold scan).

## Capabilities

### New Capabilities
- `shallow-parent-splice`: how file-derived parent targets are scoped, estimated, reconciled
  in place, and promoted when the directory level actually changed shape.

### Modified Capabilities
<!-- warm-patch-gating's thresholds and ordering are untouched; only the estimate fed into the
existing gate becomes honest for shallow targets. -->

## Impact

- Affected code: `Sources/DirWizCore/Scanner/WarmStart.swift` (collector tagging, collapse,
  estimator), `Sources/DirWizCore/Scanner/FileScanner.swift` (shallow Phase A0, promotion,
  in-place Phase B step), `Sources/DirWizCore/Scanner/FileNode.swift` (in-place metadata
  update), `Sources/DirWizCore/Scanner/FSEventsMonitor.swift` and the live accumulation path
  (kind tagging and merge), AppState's warm decision plumbing.
- Affected tests: `SubtreeRescanTests` (new shallow/promotion equivalence gates),
  `WarmStartTests`, planner and collapse unit tests, live-refresh coordination tests.
- The warm-equivalence gate MUST NOT be weakened: every new path ends in a tree
  indistinguishable from a fresh cold scan.
