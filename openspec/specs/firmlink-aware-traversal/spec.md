# firmlink-aware-traversal Specification

## Purpose
Ensure root-volume traversal counts firmlinked content exactly once at its canonical system-side path without dropping unrelated Data-volume content.
## Requirements
### Requirement: Firmlinked directories are counted exactly once
When a scan root contains both a firmlink source (e.g. `/Applications`) and its Data-volume counterpart (`/System/Volumes/Data/Applications`), the scanner SHALL enumerate that content exactly once, so its bytes contribute to the tree total exactly once.

#### Scenario: Applications is not double counted
- **WHEN** a whole-volume scan of `/` completes on a Mac whose `/usr/share/firmlinks` maps `/Applications`
- **THEN** the bytes of that directory appear once in the root total, not once per path

#### Scenario: Root total excludes the duplicate
- **WHEN** the same volume is scanned before and after this change
- **THEN** the new root total is lower by the size of the duplicated firmlinked subtrees, and no other subtree's size changes

### Requirement: Firmlinked content is attributed to its system-side path
Firmlinked content SHALL be reported under its `/`-side path (`/Applications`, `/Library`, `/Users`), not under `/System/Volumes/Data/...`, regardless of enumeration order or worker scheduling.

#### Scenario: Library reports its real size
- **WHEN** a whole-volume scan completes
- **THEN** `/Library` reports the size of its actual contents and has children, rather than reporting 0 bytes with its contents attributed to `/System/Volumes/Data/Library`

#### Scenario: Attribution is deterministic across runs
- **WHEN** the same unchanged volume is scanned repeatedly
- **THEN** each firmlinked directory is attributed to the same path every time, with no run-to-run variation from worker scheduling

### Requirement: Non-firmlinked Data-volume content is still counted
Content under the Data volume that has no firmlink entry SHALL continue to be enumerated and counted.

#### Scenario: Spotlight index is not dropped
- **WHEN** `/System/Volumes/Data/.Spotlight-V100` exists and is readable, and is not listed in the firmlink table
- **THEN** its bytes remain included in the scan total

### Requirement: Absent or unreadable firmlink table degrades safely
When `/usr/share/firmlinks` is missing, unreadable, or malformed, the scanner SHALL fall back to its previous behavior rather than failing, skipping content, or crashing.

#### Scenario: No firmlink table present
- **WHEN** the firmlink table cannot be read
- **THEN** the scan completes with the pre-change traversal behavior and no error surfaced to the user

### Requirement: Subtree scans are unaffected
Scans rooted below `/` SHALL behave exactly as before, including a scan rooted directly at `/System/Volumes/Data` or at a firmlinked path.

#### Scenario: Scanning the Data volume directly
- **WHEN** the user scans `/System/Volumes/Data` as the root
- **THEN** its contents are enumerated and counted normally, with nothing skipped
