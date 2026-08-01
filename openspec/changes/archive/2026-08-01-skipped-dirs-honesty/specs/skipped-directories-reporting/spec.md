# skipped-directories-reporting

## ADDED Requirements

### Requirement: Skipped path recording
The system SHALL record the paths of directories skipped for permission reasons during scans and subtree rescans, up to a cap of 100 paths, while the skipped count SHALL remain exact beyond the cap. Recorded paths SHALL reset at the start of each scan.

#### Scenario: Paths available after scan
- **WHEN** a scan skips 12 permission-denied directories
- **THEN** the completed scan exposes all 12 paths and the count 12

#### Scenario: Cap respected, count exact
- **WHEN** a scan skips 250 directories
- **THEN** 100 paths are retained and the reported count is 250

### Requirement: Quiet presentation when Full Disk Access is granted
When FDA is granted and directories were skipped, the sidebar SHALL present a non-alarming, secondary-styled line ("N system-protected folders skipped") that opens a popover listing the recorded paths with an explanation that macOS protects these locations even from Full Disk Access apps. No FDA call-to-action SHALL be shown in this state.

#### Scenario: FDA user sees explanation, not alarm
- **WHEN** FDA is granted and 8 directories were skipped
- **THEN** the line renders in secondary (non-orange) styling and its popover lists the 8 paths with the system-protection explanation

### Requirement: Unified warning when Full Disk Access is missing
When FDA is not granted, skipped-directory information SHALL be presented as part of the FDA warning surface (warning styling, Grant action) rather than as a second independent warning, and SHALL NOT suggest FDA to users who already granted it.

#### Scenario: One alarm, one action
- **WHEN** FDA is missing and directories were skipped
- **THEN** the FDA banner carries the skip information and the Grant action; no separate orange skip line appears
