# instant-duplicate-groups Specification

## Purpose
Provide fast metadata-based duplicate candidates while requiring content verification before destructive actions and preserving exhaustive analysis.
## Requirements
### Requirement: Instant grouping without content I/O
The system SHALL compute candidate duplicate groups by grouping non-directory files on `(fileSize, case-folded name)` using only in-memory tree data, performing no file-content reads. Files below the configured minimum size SHALL be excluded. On case-sensitive volumes the name component SHALL be compared case-sensitively; on case-insensitive volumes it SHALL be case-folded.

#### Scenario: Groups appear immediately after a scan
- **WHEN** a scan has completed and the user opens the Duplicates tab
- **THEN** candidate groups (2+ files sharing size and folded name) are displayed without any file being opened or read

#### Scenario: Case sensitivity honored
- **WHEN** the scanned volume is case-sensitive and two same-size files are named `Readme.md` and `readme.md`
- **THEN** they are NOT grouped together; on a case-insensitive volume they are

### Requirement: Heuristic labeling and action gating
Instant groups SHALL be visibly labeled as not content-verified, and the system SHALL NOT offer trash or cleanup actions on any unverified group or its members.

#### Scenario: No trash affordance before verification
- **WHEN** an instant group is displayed and has not been verified
- **THEN** no trash/cleanup control is available for that group, and the group carries a "not content-verified" label

### Requirement: Per-group content verification
The system SHALL verify a candidate group on demand by content (partial hash, full hash where needed, then byte-for-byte comparison) scoped to only that group's files, splitting it into confirmed byte-identical subgroups and discarding non-matching members. Confirmed subgroups SHALL become actionable under the same rules as the existing content-scan results.

#### Scenario: Same name and size, different content
- **WHEN** a candidate group contains two files with identical size and name but different bytes and the user verifies the group
- **THEN** the group yields no confirmed pair and is removed from (or marked resolved in) the candidate list

#### Scenario: Verified group becomes actionable
- **WHEN** a candidate group's files are byte-identical and the user verifies the group
- **THEN** a confirmed duplicate group is shown with the existing cleanup affordances

### Requirement: Hardlink collapsing
Instant grouping SHALL collapse files sharing the same `(device, inode)` to a single representative using scan-time identity metadata, so hardlinked paths are never presented as reclaimable duplicates of each other.

#### Scenario: Hardlinked pair excluded
- **WHEN** two directory entries share size, name, and `(device, inode)`
- **THEN** they do not form a candidate group by themselves

### Requirement: Mutation safety
Instant results SHALL be stored path-keyed and SHALL be cleared or recomputed after any tree mutation, so no stale node index is ever dereferenced.

#### Scenario: Trash from another tab invalidates groups
- **WHEN** a file that belongs to a candidate group is trashed and the tree is compacted
- **THEN** the Duplicates tab shows recomputed (or cleared) groups with no stale entries

### Requirement: Exhaustive content mode preserved
The existing full-volume content-hash duplicate scan SHALL remain available and behaviorally unchanged.

#### Scenario: Full scan still works
- **WHEN** the user runs the full content duplicate scan
- **THEN** results match the current pipeline's behavior (size groups → partial hash → full hash → byte verification)
