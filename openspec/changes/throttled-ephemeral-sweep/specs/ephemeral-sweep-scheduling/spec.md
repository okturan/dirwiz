## ADDED Requirements

### Requirement: The ephemeral tier sweeps on a throttled cadence
The system SHALL sweep the deferred ephemeral tier at most once per configured interval rather than once per warm patch, and SHALL make that decision in a pure clock-injected policy type that is testable without a filesystem.

#### Scenario: Several patches inside one interval
- **WHEN** multiple warm patches complete within a single sweep interval and each reports pending ephemeral changes
- **THEN** the ephemeral tier is swept at most once across them and the interactive tier is unaffected

#### Scenario: Repeated live temp churn inside one interval
- **WHEN** always-on live refresh receives repeated ephemeral changes inside one sweep interval
- **THEN** those roots remain pending without being enumerated or advancing the persisted cache horizon, while non-ephemeral live changes continue through the existing interactive patch

#### Scenario: Interval elapsed with pending changes
- **WHEN** ephemeral changes are pending and the configured interval has elapsed
- **THEN** the ephemeral tier is swept and the sweep time is recorded

#### Scenario: No pending ephemeral changes
- **WHEN** the interval has elapsed but no ephemeral root has changed
- **THEN** no sweep runs

### Requirement: A deferred sweep decision is never silent
The system SHALL expose a human-readable reason whenever an ephemeral sweep is withheld, consistent with the warm-start observability discipline that no cold or deferred decision goes unexplained.

#### Scenario: Sweep withheld by the interval
- **WHEN** the policy declines to sweep because the interval has not elapsed
- **THEN** it returns a reason naming that cause, and that reason is available to the UI

#### Scenario: Sweep withheld by an active guard
- **WHEN** a scan, heavy task, or temporal-diff overlay is active
- **THEN** the policy declines with a reason naming the guard, and the decision is re-evaluated on the next tick rather than latching

### Requirement: A throttled sweep never converts a warm start into a cold scan
The system SHALL bound how far the persisted cache horizon is held back by unswept ephemeral changes, and SHALL sweep regardless of the interval once that bound is reached, so a subsequent warm start's journal replay stays within what FSEvents will serve.

#### Scenario: Horizon ages past its bound
- **WHEN** unswept ephemeral changes have held the persisted event id back to the configured bound
- **THEN** the ephemeral tier is swept at the next opportunity even though the interval has not elapsed

#### Scenario: Warm start after a throttled session
- **WHEN** the app relaunches after a session in which ephemeral sweeps were throttled
- **THEN** the journal replay succeeds and the scan stays warm rather than falling back cold on a replay spanning too much history

### Requirement: Navigating into a stale ephemeral subtree sweeps it
The system SHALL sweep an ephemeral subtree on demand when the user navigates into it while it has pending unswept changes, regardless of the interval.

#### Scenario: User opens the stale temp subtree
- **WHEN** the user navigates into an ephemeral subtree carrying pending unswept changes
- **THEN** that subtree is swept and its displayed sizes stop being marked stale
