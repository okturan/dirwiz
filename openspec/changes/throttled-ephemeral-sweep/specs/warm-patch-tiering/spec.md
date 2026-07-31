## MODIFIED Requirements

### Requirement: Deferral changes scheduling only, never totals
The system SHALL produce, once the ephemeral tier's throttled sweep has run, a tree equal to a fresh cold scan, and SHALL leave cold-scan totals unchanged by this feature. Between sweeps the ephemeral subtree is knowingly stale, and the system SHALL represent that staleness rather than present it as current.

#### Scenario: Equivalence after a sweep
- **WHEN** the ephemeral tier's sweep has run and the patch is quiescent
- **THEN** the resulting tree equals the tree a fresh cold scan of the same volume produces

#### Scenario: Between sweeps
- **WHEN** ephemeral changes are pending but no sweep has run
- **THEN** the ephemeral subtree retains its last swept contents and the view represents it as stale rather than current

#### Scenario: Cold scan unaffected
- **WHEN** a cold scan runs
- **THEN** ephemeral directories are enumerated and counted in full, exactly as before this change
