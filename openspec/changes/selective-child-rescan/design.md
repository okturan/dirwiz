## Context

Warm patching today has exactly two shapes for a changed directory:

- **Shallow** (`shallow-parent-splice`): the target was blamed only by file events inside
  it. Read its one entry level, compare with the cached children by (name, isDirectory,
  isBundle); if the sets match, copy metadata onto the existing child nodes in place and
  touch nothing else. Cheap and already shipped.
- **Deep**: FSEvents reported the directory itself, OR a shallow target's level changed
  shape and was promoted. The whole subtree is re-enumerated into a staging tree and
  installed by `FileTree.applyStagedReplacements`, which removes every old descendant of the
  target and appends the staged block in one transactional compaction.

The deep shape is the problem. It is chosen by the coarsest possible signal - "something
about this directory changed" - and its cost is the entire subtree regardless of how small
the change was. That cost is charged twice: once by `WarmStartPlanner.estimatedPatchItemCounts`
(which sums `subtreeItemCount` per deep root, producing the "~84% of files changed" line)
and once by Phase A actually re-reading it.

Measured on this machine: ~1,300 changed locations per launch window, estimate 84% of
4.9M items, planner falls back to a cold scan, 30-45 seconds at multiple cores. Real churn
in the same window is a few percent.

The shallow path already demonstrates that a level read plus a diff is enough to know what
actually changed at a directory. Nothing about that machinery is specific to file-derived
targets.

## Goals / Non-Goals

**Goals:**
- A changed directory costs one level read plus the work for genuinely differing entries.
- An unchanged sibling's subtree is never re-read, removed, or reinstalled.
- Admission estimates reflect that, so ordinary churn stays warm instead of falling cold.
- Every outcome remains byte-identical to a fresh cold scan (the standing equivalence gate).

**Non-Goals:**
- Recursive descent through unchanged directories to "find" changes. FSEvents already
  reports every changed directory; walking to discover them is exactly the cost being
  removed.
- Changing the FSEvents contract, poison handling, mount/firmlink rules, cache-horizon
  invariant, or the 25% fraction gate.
- Making cold scans faster. This change reduces how often they are needed.
- Per-file surgery from raw event paths (already rejected in `shallow-parent-splice`: it
  duplicates scanner parsing and drifts from the bulk parser the equivalence gate anchors to).

## Decisions

### One reconciliation shape for every directory target

Both event kinds collapse to the same algorithm, so "deep" stops meaning "replace the
subtree" and starts meaning "this directory's level is stale":

1. **Level read.** Enumerate the target's own entries once, no recursion. This is Phase A0,
   already implemented for shallow targets; it becomes the entry point for all targets.
2. **Diff against cached children** by `(name, isDirectory, isBundle)`:
   - **unchanged** (present both sides, same type): copy metadata onto the existing node.
     Its subtree is left completely alone.
   - **added** (fresh only): enumerate that entry's subtree in full and stage it.
   - **removed** (cached only): mark that child's subtree for removal.
   - **type-changed** (file→directory or bundle→plain): treat as removed + added, since the
     node's meaning changed.
3. **Apply** all metadata updates, all removals, and all additions across every target in
   ONE transactional compaction.

Alternative rejected: keep whole-subtree replacement but graft unchanged children's cached
subtrees into the staging tree. Correct, but it copies hundreds of megabytes of nodes per
patch to avoid re-reading them - trading I/O for memory traffic and allocation, and it
still touches every index. The diff avoids both.

### Mutation primitive: partial child replacement

`applyStagedReplacements` currently means "replace ALL descendants of these targets". The
change needs "within this target, remove these named children's subtrees, append these new
staged subtrees, and leave the rest in place".

This is one new primitive on `FileTree`, transactional exactly like the existing one:
assemble the survivor set, the removal set, and the staged appendix off to the side, build
the new node array and string pool, validate, then publish - so cancellation leaves the tree
byte-for-byte untouched. The existing whole-subtree replacement becomes the degenerate case
where every cached child is in the removal set (`removeChildIndices: nil`), which keeps one
code path under test rather than two.

**Contiguity without grafting.** Direct children must stay contiguous, and append-only
staged additions would split a target's child slice if kept siblings stayed at their old
indices. The rebuild therefore relocates kept children's subtrees into the same tail block
as the staged additions when a target has anything to install: emit kept direct children,
then the staged block, then descendants of those kept children. That is still one copy per
survivor during compaction - not the rejected "graft kept subtrees into a staging FileTree
first" approach, which would peak at a second full copy of those nodes before the rebuild.

Non-negotiable: partial mutation still invalidates every index, so all targets and their
child decisions must be resolved against ONE pre-mutation snapshot before anything mutates -
the same resolve-once-then-single-mutation discipline `rescanSubtrees` already follows.

### Estimation follows the new cost

`estimatedPatchItemCounts` charges each collapsed root `max(1, cached childCount)` - the
level read - instead of `subtreeItemCount`, because that is now what a target costs before
its diff is known. Added subtrees are genuinely unbounded at estimate time, and they are
already covered downstream:

- the pre-staging promotion budget refuses a diff whose additions are predicted to dwarf the
  remaining budget (from `shallow-parent-splice`);
- the exact post-Phase-A staged-item guard measures what was actually staged and abandons
  coherently if it exceeds the tier budget.

So the estimate becomes an honest lower bound on committed work, with two real measurements
downstream, rather than today's pessimistic upper bound that refuses good patches outright.

### Bundles and mount boundaries are unchanged

A bundle target keeps bundle semantics (opaque size computation, no level diff). Mount
boundaries and firmlink dedup continue to gate which entries may be descended, seeded from
the same `VisitedDirectories` the batch shares - a level diff must not become a way to walk
into a foreign filesystem the cold scan excludes.

## Risks / Trade-offs

- **Partial mutation is the highest-risk code in the app** → the equivalence gate (patched
  tree ≡ fresh cold scan) is the acceptance criterion, extended with cases specific to this
  change: addition only, removal only, type change, mixed, and untouched-sibling identity
  proven by a filesystem provider that records which paths were listed.
- **A missed event means a stale subtree forever.** Previously a deep rescan would
  accidentally repair drift inside the subtree; now an unchanged-looking child is trusted →
  mitigated by the fact that FSEvents poison flags (MustScanSubDirs, IdsWrapped, RootChanged,
  Mount) already force a cold fallback, which is precisely the "the journal is not
  trustworthy" signal. Document that this change makes the app rely on that contract more
  strongly, and keep the timeout-is-poison rule.
- **Name-based diffing on case-insensitive volumes** → compare using the same case discipline
  the tree already uses for lookups; a rename differing only in case must count as changed,
  not as unchanged-with-metadata.
- **Hardlink flags** (`hasMultipleHardlinks`) are captured per node during enumeration; an
  in-place metadata update must carry them, or the Hardlinks tab silently loses groups after
  a patch → covered by the existing equivalence gate, which compares that flag.
- **More, smaller staged units** could make Phase B bookkeeping dominate → measure on the
  real volume; the batched-splice work already showed one compaction handles many roots
  (38 roots: 9.14 s → 0.118-0.164 s), and this change strictly reduces the volume of nodes
  moved per compaction.

## Migration Plan

No persisted format changes: the cache stores the tree, and this only changes how a tree is
brought up to date. No `TreeCache.formatVersion` bump. Rollback is reverting the commit; a
cache written by either version remains loadable by both.

Staged so each step is independently verifiable: level-diff computation as a pure function
first (testable with no filesystem), then the mutation primitive with equivalence gates,
then the wiring that routes directory events through it, then the estimator change - because
until the estimator changes, the planner keeps refusing the very patches this makes cheap.

## Open Questions

- Should a level diff that finds a very large number of added entries promote to
  whole-subtree staging for that target (fewer, larger units), or stay per-entry? Decide
  from measurement, not taste; per-entry is the default until it demonstrably costs more.
- Does the living view want the same treatment for its accumulated directory events on the
  first apply after a long quiet period, or is the existing quiescence enough? Expected to
  fall out for free, since both paths share `rescanSubtrees`.
