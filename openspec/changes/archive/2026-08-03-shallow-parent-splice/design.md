# Design

## Evidence

- `WarmStartHistory` for `/`: three explicit full rescans on Aug 2 (243s under load, 108s,
  48s), then the 22:12 launch refresh went cold with "~92% of files changed since last scan"
  four minutes after the 48s full rescan completed. 92% of 4.55M ≈ 4.2M items; the real churn
  window (builds + temp) is at most a few hundred thousand.
- Samsung8TB: cold at "~26%" twice - just over the 25% gate - on a drive that barely changed.
- Journal probe (15-minute window on `/`, same flags and reduction as `JournalCollector`):
  5,710 raw events, 1,563 unique targets, 193 collapsed roots. Depth ≤ 3 roots and their
  causes: `/` (reduced from root-level file events), `/Users/okan` (reduced from `.DS_Store`),
  `/private/tmp` (claude session cwd files), `/private/var/run` (a pid file), plus one genuine
  dir-level event. `/Users/okan` alone estimates ≈ 90% of the tree; `/` alone trips the
  root-level preflight abandon. Either is sufficient for a cold fallback, and at least one is
  present in essentially every replay window.

## The core distinction

A file event on `P/f` proves only that `P`'s OWN entry level is stale (an entry's metadata
changed, or an entry appeared/vanished). It says nothing about `P`'s child subtrees - changes
inside those produce their own events with their own targets. A directory-level event on `D`
keeps today's meaning: `D` changed in a way that warrants re-enumerating its subtree.

Target kind is therefore decided per collapsed path: `directoryEvent` if ANY event reported the
directory itself, else `parentOfFile` (shallow). Kind rides beside the existing `[String]`
target list as a `Set<String>` of shallow-eligible paths - `JournalReplay.fileOnlyTargets` -
so the `Outcome` shape and every existing call site keep compiling.

## Shallow reconcile (Phase A0 + in-place Phase B step)

1. Resolution: a shallow requested path stays shallow only if it resolves to ITSELF in the
   cached tree. Resolving upward (missing node, bundle interior) means the tracked ancestor's
   shape is unknown - treat as deep, exactly today's behavior. A bundle plan keeps the bundle
   path regardless of kind.
2. Collapse: `PathCollapse.outermostRoots(_:shallow:)` lets only DEEP roots claim descendants.
   A shallow root claims nothing (its work is one entry level, disjoint from any nested
   target's work); exact duplicates still dedupe, deep winning over shallow for the same path.
3. Phase A0 (before today's Phase A): each shallow directory plan is enumerated ONE level via
   the existing worker machinery with a no-recurse flag (`getattrlistbulk` on the target only;
   child directories are recorded as entries but never enqueued).
4. Comparison against the cached node's direct children, by (name, isDirectory):
   - Sets equal → metadata-only. Emit in-place updates: for each entry, copy size, allocated
     size, dates, and per-node flags (hardlink bit included) onto the existing child node.
     Child `firstChildIndex`/`childCount`/name are untouched. Applied in Phase B BEFORE any
     compaction, so no index is invalidated; `recomputeAggregates()` at the end repairs totals
     exactly as it already must.
   - Any difference → PROMOTE to deep: the target joins Phase A's normal full-subtree staging,
     and any other staged target nested beneath it is dropped before Phase B (a deep root
     covers them). A promoted root equal to the tree root aborts the patch into the existing
     "root-level rescan" cold fallback.
5. Root-level shallow: a `parentOfFile` target equal to the tree root is legal and reconciled
   like any shallow target (level read + in-place or promote). The preflight abandon now fires
   only for DEEP root-level targets.
6. Budget: shallow levels count their entry count toward `actualStagedItemCount`; promotions
   are naturally caught by the existing post-Phase-A exact budget recheck. The estimator
   charges shallow roots `max(1, cached childCount)` instead of `subtreeItemCount`, so the
   25% gate finally sees honest numbers (unresolved roots keep the small constant).

## Live path

`FSEventsMonitor` performs the same file→parent reduction for the living view, so accumulated
change sets get the same kind tagging: a path accumulates as shallow until any dir-level event
arrives for it, after which it stays deep for that accumulation window.
`applyAccumulatedChanges` forwards the shallow set into `rescanSubtrees` unchanged. This is
not cosmetic: every `~/.DS_Store` write currently makes the next live apply re-stage the whole
home folder.

## Equivalence obligations (gates, not aspirations)

- Metadata-only shallow patch ≡ fresh cold scan, AND the untouched child subtree is provably
  not re-enumerated (mock provider records per-path listing calls).
- Structural shallow patch promotes and ≡ fresh cold scan.
- Root-level shallow metadata patch ≡ fresh cold scan; root-level structural promotes to the
  cold fallback with the existing reason.
- Shallow root does not swallow a nested deep target; both apply; result ≡ cold.
- Planner: the probe's incident shape (huge shallow root + modest deep roots) is admitted
  warm; a genuine mass change still falls back cold via the unchanged fraction gate.

## Explicitly rejected

- Fixing only the estimator: the gate would admit a patch whose Phase A then stages millions
  of items before the exact recheck aborts it - all cost, no benefit.
- Deep-copy grafting of surviving child subtrees into staging trees: correct but charges a
  multi-hundred-MB copy per home-level `.DS_Store` write on every live apply.
- Single-file node surgery from raw events: duplicates scanner parsing per event kind and
  drifts from the bulk parser that the equivalence gate is anchored to.
