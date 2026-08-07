## ADDED Requirements

### Requirement: A changed directory is reconciled by level diff

Every directory warm-patch target SHALL be reconciled by reading its own entry level once
and comparing it with its cached children by name, directory-ness, and bundle-ness. The
patch SHALL act only on the difference: entries present on both sides receive fresh metadata
in place, entries present only on disk have their subtrees enumerated and installed, entries
present only in the cache have their subtrees removed, and an entry whose type changed SHALL
be treated as a removal plus an addition. A target's subtree SHALL NOT be re-enumerated
wholesale merely because the directory was reported changed.

#### Scenario: One folder is created inside a large directory

- **WHEN** a target directory holding many cached children gains one new folder
- **THEN** only the new folder's subtree SHALL be enumerated and installed
- **AND** the other children SHALL keep their existing subtrees without re-enumeration
- **AND** the resulting tree SHALL equal a fresh cold scan

#### Scenario: A folder is deleted from a large directory

- **WHEN** a cached child of the target no longer exists on disk
- **THEN** only that child's subtree SHALL be removed
- **AND** its siblings SHALL be untouched
- **AND** the resulting tree SHALL equal a fresh cold scan

#### Scenario: An entry changes type

- **WHEN** a cached entry is a file and the fresh level reports a directory of that name, or
  a plain directory becomes a bundle
- **THEN** the stale node and any descendants SHALL be removed and the fresh entry installed
- **AND** the resulting tree SHALL equal a fresh cold scan

### Requirement: Untouched subtrees are provably untouched

Reconciliation SHALL NOT read, remove, or reinstall the subtree of a child that appears
unchanged at the target's level. Changes inside such a child are reported by their own
events and reconciled as their own targets.

#### Scenario: A sibling subtree is never listed

- **WHEN** a target is reconciled and one of its children is unchanged at that level
- **THEN** no directory inside that child SHALL be enumerated during the patch
- **AND** the child's descendant nodes SHALL retain their identities

### Requirement: Partial mutation stays transactional

Metadata updates, subtree removals, and subtree installations for every target in a batch
SHALL be committed in ONE compaction, resolved against a single pre-mutation snapshot.
Cancellation before that commit SHALL leave the tree byte-for-byte unchanged, and aggregate
totals SHALL be repaired after it.

#### Scenario: Cancellation lands mid-patch

- **WHEN** the patch is cancelled after staging but before the commit
- **THEN** the destination tree SHALL be exactly as it was before the patch
- **AND** no partially installed or partially removed child SHALL be observable

#### Scenario: Several targets change in one batch

- **WHEN** multiple directories each gain, lose, and retain entries
- **THEN** all of their changes SHALL be applied in one compaction
- **AND** the resulting tree SHALL equal a fresh cold scan

### Requirement: Admission reflects the level, not the subtree

The warm-start estimator SHALL charge a changed directory its direct child count rather than
its cached subtree item count, because a level read is what the target costs before its diff
is known. Work revealed by the diff SHALL remain governed by the existing pre-staging
promotion budget and the exact post-staging staged-item guard, whose refusals SHALL keep
naming the honest measured or predicted fraction.

#### Scenario: Ordinary churn no longer reads as most of the disk

- **WHEN** a launch window reports many changed directories whose levels are small
- **THEN** the estimate SHALL be proportional to those levels, not to their subtrees
- **AND** the patch SHALL be admitted warm

#### Scenario: A diff reveals genuinely large additions

- **WHEN** reconciliation stages new subtrees that exceed the caller's remaining budget
- **THEN** the patch SHALL abandon into a coherent cold fallback with a recorded reason
- **AND** the destination tree SHALL be left untouched

### Requirement: Traversal rules survive the diff

Level reconciliation SHALL honor the same mount-boundary, firmlink-deduplication, and bundle
rules as a cold scan. A bundle target SHALL keep opaque bundle sizing rather than being
level-diffed.

#### Scenario: A mount point appears inside a reconciled directory

- **WHEN** a fresh entry crosses a device boundary the scan's scope excludes
- **THEN** it SHALL be recorded as a skipped mount rather than descended
- **AND** the resulting tree SHALL equal a fresh cold scan of the same scope
