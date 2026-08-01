# hardlink-capture

## ADDED Requirements

### Requirement: Scan-time link-count capture
The scanner SHALL obtain each file's link count within the existing bulk enumeration call (no additional per-file syscalls) and SHALL mark files whose link count exceeds 1 with a multiple-hardlinks flag. Directories SHALL never carry the flag.

#### Scenario: Hardlinked file flagged during scan
- **WHEN** a volume containing a file with two hardlinked paths is scanned
- **THEN** both corresponding nodes carry the multiple-hardlinks flag, captured without extra stat calls

#### Scenario: Directories exempt
- **WHEN** a directory with many children is scanned
- **THEN** its node does not carry the multiple-hardlinks flag regardless of its filesystem link count

### Requirement: Automatic hardlink grouping
Hardlink groups SHALL be computed automatically after every completed scan and recomputed (or cleared then recomputed) after any tree mutation, with no user-initiated run step. The Hardlinks tab SHALL always show current results or an explicit "no hardlinks found" state.

#### Scenario: Tab is populated without a button
- **WHEN** a scan completes and the user opens the Hardlinks tab
- **THEN** groups are already listed (or the empty state shown); no run/scan button exists

### Requirement: Fast-path equivalence
Grouping computed via the flag fast path SHALL produce identical groups to the full per-file grouping for scanned trees. Trees lacking identity metadata (synthetic/test trees) SHALL fall back to the full path.

#### Scenario: Equivalence gate
- **WHEN** the same scanned tree is grouped by fast path and by full grouping
- **THEN** the resulting group sets (inode, device, member paths) are identical

### Requirement: Cache format safety
The tree-cache format version SHALL be bumped with the node layout change; caches written by prior versions SHALL be rejected fail-closed, falling back to a cold scan.

#### Scenario: Old cache rejected cleanly
- **WHEN** the app loads a cache written before this change
- **THEN** cache load returns nil and a normal cold scan runs; no crash, no misread fields
