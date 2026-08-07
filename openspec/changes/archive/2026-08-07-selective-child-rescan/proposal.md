## Why

Warm start refuses on nearly every launch of this machine with reasons like "~84% of files
changed since last scan", while genuine churn is a few percent. That number is not a
measure of change: it is the cost of the re-enumeration the current design commits to. A
single FSEvents event on a DIRECTORY marks that target deep, and a deep target is both
charged its entire cached subtree by the admission estimator and then re-enumerated in
full. One new folder inside a 400k-file directory bills and re-reads 400k items. A handful
of such targets across ~1,300 changed locations reaches 84% of a 4.9M-item tree, the
planner concludes a cold scan is cheaper, and the user pays a 30-45 second full
enumeration - plus the CPU that goes with it - for changes that touched a few directories.

`shallow-parent-splice` already proved the cheaper shape for file-derived targets: read one
directory level, diff it, patch in place. It stops short exactly where it matters, because
its promotion path falls back to re-enumerating the whole subtree.

## What Changes

- Every directory target - whether FSEvents reported the directory itself, or a shallow
  target promoted because its level changed shape - SHALL be reconciled by a LEVEL DIFF
  rather than a whole-subtree replacement. Read the target's own entries once, compare with
  the cached children by name and type, then act only on the difference:
  - entries present in both: metadata updated in place, their subtrees untouched;
  - entries added: only those new subtrees enumerated and installed;
  - entries removed: only those subtrees removed.
- An unchanged child's subtree SHALL NOT be re-read, removed, or re-installed. Changes
  inside it produce their own events and are handled as their own targets.
- The admission estimator SHALL charge every target its LEVEL (direct child count), not its
  cached subtree, because a level read is now what a target actually costs up front. The
  existing exact post-Phase-A staged-item guard remains the protection against a level diff
  that turns out to reveal large new subtrees, and the pre-staging promotion budget added by
  `shallow-parent-splice` continues to refuse doomed patches before any work.
- Unchanged: poison handling, the 25% item fraction and its recheck, the 512-root backstop,
  tier budgets, the cache-horizon invariant, mount/firmlink rules, and - non-negotiably -
  the equivalence gate that a patched tree is indistinguishable from a fresh cold scan.

## Capabilities

### New Capabilities
- `selective-child-rescan`: how a changed directory is reconciled against its cached
  children so that only genuinely differing entries are re-enumerated, how the resulting
  cost is estimated and admitted, and what invariants the partial mutation must preserve.

### Modified Capabilities
- `shallow-parent-splice`: its promotion path currently escalates a shallow target to a
  full-subtree rescan. Promotion becomes a level diff over the same machinery, so the
  requirement describing promotion changes shape.

## Impact

- Affected code: `Sources/DirWizCore/Scanner/FileScanner.swift` (level staging, the diff,
  partial install/removal, promotion), `Sources/DirWizCore/Scanner/FileNode.swift`
  (installing and removing individual child subtrees within one transactional compaction),
  `Sources/DirWizCore/Scanner/WarmStart.swift` (level-based estimates),
  `Sources/DirWizUI/Models/AppState+Scan.swift` (reason threading, tier budgets).
- Affected tests: `SubtreeRescanTests`, `ShallowParentSpliceTests`, `WarmStartTests`,
  `BatchedSubtreeSpliceTests`, plus new equivalence gates for partial mutation.
- Risk concentrates in tree mutation: partial installs and removals must remain ONE
  transactional compaction, since every index is invalidated by it. The equivalence gate is
  the acceptance criterion for the whole change, not a nice-to-have.
- No new dependencies; the zero-dependency rule holds.
