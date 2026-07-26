# snapshot-history

## ADDED Requirements

### Requirement: Checkpoints accumulate
The system SHALL store multiple checkpoints per volume; creating a new checkpoint SHALL NOT remove or overwrite existing ones (retention policy aside). Each checkpoint SHALL be listable (id, creation date, total bytes, dir count, optional name, pinned flag) without decompressing checkpoint payloads.

#### Scenario: Two scans, two points
- **WHEN** a scan completes on Monday and another on Tuesday (beyond the throttle interval)
- **THEN** the store lists two checkpoints with their respective dates and totals

### Requirement: Auto-checkpoint on scan completion
The system SHALL create a checkpoint automatically when a scan completes, unless a checkpoint newer than the minimum interval (6 hours) exists for that volume and total-bytes change since it is below the growth threshold (1%).

#### Scenario: Throttled repeat scan
- **WHEN** a second scan completes 30 minutes after a checkpoint with under 1% size change
- **THEN** no new checkpoint is created

#### Scenario: Significant change overrides throttle
- **WHEN** a scan 30 minutes later shows total bytes changed by more than 1%
- **THEN** a checkpoint is created despite the interval

### Requirement: Pinned named checkpoints
The user SHALL be able to create a named, pinned checkpoint on demand (the former "Take Snapshot" action). Pinned checkpoints SHALL be exempt from retention thinning and budget eviction and SHALL display their name wherever checkpoints are listed.

#### Scenario: Pin survives retention
- **WHEN** a checkpoint named "pre-cleanup" is pinned and months of thinning cycles pass
- **THEN** "pre-cleanup" remains in the store

### Requirement: Retention thinning and storage budget
The system SHALL thin unpinned checkpoints to at most one per day older than 24 hours, one per week older than 30 days, and one per month older than 12 weeks, deleting the rest; and SHALL additionally enforce a total store budget (500 MB default) by deleting oldest unpinned checkpoints first. Retention SHALL run after each checkpoint creation.

#### Scenario: Daily thinning
- **WHEN** three unpinned checkpoints exist within one calendar day, all older than 24 hours
- **THEN** after retention only one of them remains

#### Scenario: Budget eviction order
- **WHEN** the store exceeds its budget
- **THEN** oldest unpinned checkpoints are deleted until within budget; pinned ones are never deleted

### Requirement: Per-checkpoint change summary
Checkpoint creation SHALL compute and store a compact summary vs. the immediately preceding checkpoint (total byte delta, top grown and shrunk directories, deleted-path count/bytes), retrievable from the index without loading either checkpoint payload.

#### Scenario: Summary available instantly
- **WHEN** the user views the checkpoint list
- **THEN** each entry (except the first) shows its delta summary without any checkpoint file being decompressed

### Requirement: Compare to any checkpoint
The diff feature SHALL let the user select any stored checkpoint as the comparison baseline; the diff overlay and summaries then reflect current-tree-vs-that-checkpoint. The most recent checkpoint SHALL be the default baseline.

#### Scenario: Older baseline selected
- **WHEN** the user picks a checkpoint from last month in the compare picker and enables the diff overlay
- **THEN** the treemap highlights changes relative to that month-old checkpoint

### Requirement: Fail-closed loading and versioning
The store SHALL version its container format and fail closed: a checkpoint that is truncated, corrupt, of unknown version, or otherwise doubtful SHALL be skipped (and reported in logs) without crashing, without partial data, and without affecting other checkpoints.

#### Scenario: One corrupt file among many
- **WHEN** a checkpoint file is truncated on disk
- **THEN** listing and diffing continue to work using the remaining checkpoints; the corrupt one is absent from the list

### Requirement: Legacy migration
On first access to a volume's store, an existing single-slot `.tdiff` snapshot for that volume SHALL be imported as the store's first checkpoint (pinned, named "Legacy snapshot") and the legacy file retired.

#### Scenario: Upgrade preserves the old baseline
- **WHEN** a user with an existing snapshot updates and opens the compare picker
- **THEN** their old snapshot appears as a pinned "Legacy snapshot" checkpoint with its original date

### Requirement: CLI store operations
The CLI SHALL create checkpoints in the shared store (`snapshot`), list them (`snapshot list`), and diff against the latest checkpoint by default (`diff`), sharing files and format with the GUI.

#### Scenario: GUI sees CLI checkpoint
- **WHEN** `dirwiz-cli snapshot <path>` runs and the GUI is later opened on that volume
- **THEN** the CLI-created checkpoint appears in the GUI's compare picker
