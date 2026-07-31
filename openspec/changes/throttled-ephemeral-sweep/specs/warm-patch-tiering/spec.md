# warm-patch-tiering

## MODIFIED Requirements

### Requirement: Deferral changes scheduling only, never totals
The system SHALL produce, once the ephemeral tier's throttled sweep has run, a tree equal to a fresh cold scan, and SHALL leave cold-scan totals unchanged by this feature. Between sweeps the ephemeral subtree is knowingly stale, and the system SHALL represent that staleness rather than present it as current.

#### Scenario: Equivalence after a sweep
- **WHEN** the ephemeral tier's sweep has run and the patch is quiescent
- **THEN** the resulting tree equals the tree a fresh cold scan of the same volume produces

#### Scenario: Between sweeps
- **WHEN** ephemeral changes are pending but the sweep interval has not elapsed
- **THEN** the ephemeral subtree retains its last swept contents and the view represents it as stale rather than current

#### Scenario: Cold scan unaffected
- **WHEN** a cold scan runs
- **THEN** ephemeral directories are enumerated and counted in full, exactly as before this change

## ADDED Requirements

### Requirement: The ephemeral tier sweeps on a throttled cadence
The system SHALL sweep the ephemeral tier at most once per configured interval, rather than once per warm patch, and SHALL make that decision in a pure clock-injected policy type testable without a filesystem.

#### Scenario: Repeated patches inside one interval
- **WHEN** several warm patches complete within a single sweep interval and each reports ephemeral changes
- **THEN** the ephemeral tier is swept at most once across them, and the interactive tier is unaffected

#### Scenario: Interval elapsed
- **WHEN** ephemeral changes are pending and the interval has elapsed
- **THEN** the ephemeral tier is swept and the sweep time is recorded

#### Scenario: Navigating into a stale ephemeral subtree
- **WHEN** the user navigates into an ephemeral subtree that has pending unswept changes
- **THEN** that subtree is swept regardless of the interval, because that is the moment its freshness has value

### Requirement: A throttled sweep never converts a warm start into a cold scan
The system SHALL bound how far the persisted cache horizon is held back by unswept ephemeral changes, and SHALL sweep regardless of the interval when that bound is reached, so that a subsequent warm start's journal replay stays within what FSEvents will serve.

#### Scenario: Horizon ages past the bound
- **WHEN** unswept ephemeral changes have held the persisted event id back to the configured bound
- **THEN** the ephemeral tier is swept on the next opportunity even though the interval has not elapsed

#### Scenario: Warm start after throttled operation
- **WHEN** the app relaunches after a session in which ephemeral sweeps were throttled
- **THEN** the journal replay succeeds and the scan stays warm, rather than falling back cold on a replay that spans too much history
