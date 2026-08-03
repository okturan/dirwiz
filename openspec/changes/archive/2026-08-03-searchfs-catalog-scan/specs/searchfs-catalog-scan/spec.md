## ADDED Requirements

### Requirement: Catalog scanning is gated by an idle matched comparison

The system SHALL NOT adopt `searchfs` as the volume-scan path until an idle, best-of-N comparison
shows that it beats traversal in wall time or ties while using materially less CPU.

#### Scenario: Catalog scanning loses both gates

- **WHEN** `searchfs` is slower than traversal and does not provide a substantial CPU reduction
- **THEN** the change stops without adding a second production scanner
- **AND** the negative measurement is recorded so the mechanism is not repeatedly re-investigated

#### Scenario: Catalog scanning passes a gate

- **WHEN** the matched comparison wins wall time or ties with materially lower CPU use
- **THEN** implementation may proceed using the recorded time, CPU, memory, and thread-count baseline

### Requirement: Whole-volume catalog records build a valid FileTree

When adopted, the catalog scanner SHALL collect resumable `searchfs` batches for every in-scope
volume and SHALL reconstruct the flat tree from stable record and parent identifiers while
preserving parent-before-child ordering.

#### Scenario: System and Data volumes are in scope

- **WHEN** a root scan spans the normal macOS System/Data volume pair
- **THEN** each in-scope volume is searched once
- **AND** their records are connected into the same logical scan without double-counting firmlinked
  content

#### Scenario: Records include multiple names for one file identity

- **WHEN** catalog results contain hardlink records sharing a file identifier
- **THEN** link-count metadata remains trustworthy
- **AND** inode-shared allocated blocks are not counted more than once

#### Scenario: Parent records arrive after descendants

- **WHEN** search batches are not ordered parent-first
- **THEN** reconstruction reorders or buckets them before publication so every parent index precedes
  its children and child slices remain contiguous

### Requirement: Catalog scanning is capability-gated and fail-closed

The system SHALL use the catalog path only when the volume advertises valid `VOL_CAP_INT_SEARCHFS`
support and the complete result passes sanity checks; otherwise it SHALL fall back to traversal with
an observable reason.

#### Scenario: Capability is absent or the syscall fails

- **WHEN** `searchfs` is unsupported or returns an error before a trustworthy tree is complete
- **THEN** the scanner discards the partial catalog result and performs the existing traversal scan
- **AND** the scan summary names the fallback reason

#### Scenario: Catalog result is implausibly small or structurally invalid

- **WHEN** record-count or connectivity checks indicate that the catalog answer may be incomplete
- **THEN** the answer is rejected rather than published
- **AND** traversal supplies the authoritative tree

#### Scenario: Catalog scanning is disabled

- **WHEN** `DIRWIZ_NO_SEARCHFS=1` is set
- **THEN** the scanner uses traversal without attempting the catalog path

### Requirement: Catalog scope does not replace folder traversal

The catalog path SHALL be limited to scans that cover whole volumes, because `searchfs` cannot scope
its result to an arbitrary subtree.

#### Scenario: User scans a folder

- **WHEN** the requested scan root is below a volume root
- **THEN** the existing traversal scanner handles the request

#### Scenario: Separate mounts are below the root volume

- **WHEN** volume discovery encounters filesystems excluded by the mount-aware traversal policy
- **THEN** those mounts are not added to the root volume's catalog scan scope

### Requirement: Catalog and traversal results satisfy the same correctness gates

A catalog-produced tree SHALL match traversal for content both paths can see, including paths,
counts, sizes, hardlink groups, cache compatibility, and warm-patch equivalence.

#### Scenario: Both scanners cover a fully visible fixture

- **WHEN** the same fixture is scanned through catalog reconstruction and traversal
- **THEN** the resulting trees and volume totals are equivalent

#### Scenario: Filesystem mutates during catalog collection

- **WHEN** files are created or removed while resumable `searchfs` batches are in progress
- **THEN** the scanner either produces a structurally valid, sanity-checked result or falls back to
  traversal
- **AND** it never publishes a corrupt partial tree

