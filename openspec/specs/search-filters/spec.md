# search-filters Specification

## Purpose
Define composable metadata-only search filters for extension, size, modification date, and folder scope.
## Requirements
### Requirement: Extension multi-filter
The system SHALL let the user select one or more extensions directly in the Search filter bar from a searchable list showing each extension's total size and file count. Selected extensions SHALL combine as OR (a file matches if its extension is any selected one) and render as individually removable chips. An empty query with an active extension filter SHALL list all matching files.

#### Scenario: Two extensions selected
- **WHEN** the user selects `.png` and `.jpg` in the extension picker with an empty query
- **THEN** results contain exactly the files whose extension is png or jpg, each chip removable independently

#### Scenario: Drill-down from Extensions tab pre-fills the picker
- **WHEN** the user taps an extension row in the Extensions tab
- **THEN** the Search tab opens with that extension as the single selected chip (current behavior preserved through the new mechanism)

### Requirement: Size range filter
The system SHALL support both a minimum and a maximum size bound; files match when `min ≤ size ≤ max` (unset bounds are unbounded).

#### Scenario: Band query
- **WHEN** the user sets min > 1 MB and max < 100 MB
- **THEN** only files in (1 MB, 100 MB) appear in results

### Requirement: Modified-date filter
The system SHALL offer modified-date presets: any, last 24 hours, last 7 days, last 30 days, last year, older than 1 year, older than 2 years, evaluated against each node's scan-time modification date.

#### Scenario: Recent files
- **WHEN** the user picks "last 7 days"
- **THEN** only files modified within 7 days of now are listed

#### Scenario: Stale files
- **WHEN** the user picks "older than 2 years"
- **THEN** only files with modification dates more than 2 years ago are listed

### Requirement: Scope to folder
The system SHALL provide a "Search in this folder" context-menu action on tree rows that restricts search to that folder's subtree, displayed as a clearable scope chip in the Search tab. Scope membership SHALL include all descendants at any depth.

#### Scenario: Scoped search
- **WHEN** the user invokes "Search in this folder" on `~/Projects` and types a query
- **THEN** only matches whose path is under `~/Projects` appear; clearing the chip restores whole-tree search

### Requirement: Filter composition without content I/O
Filters SHALL compose as AND across filter kinds (type, category, extensions, size, date, scope) and SHALL be evaluated purely against in-memory node data - no filesystem reads - preserving instant search behavior and the existing result cap semantics.

#### Scenario: Combined filters
- **WHEN** query "report", extensions {pdf}, size > 10 MB, last 30 days, and a folder scope are all active
- **THEN** results satisfy every condition simultaneously and return with instant-search latency (no content I/O)
