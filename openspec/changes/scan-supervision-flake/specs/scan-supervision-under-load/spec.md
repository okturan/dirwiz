## ADDED Requirements

### Requirement: Warm-patch supervision holds under machine contention
The system SHALL maintain its supervision guarantees when the machine is heavily contended, so that a warm patch behind a stale view never publishes a misleading empty state, never strands progress, and never loses its warm-patch-specific status.

#### Scenario: Warm patch under heavy parallel filesystem load
- **WHEN** a warm patch runs behind a stale view while the machine is under heavy concurrent filesystem activity
- **THEN** previously populated hardlink groups stay populated or visibly recomputing, progress reflects a warm patch rather than a generic status, and no state is stranded

#### Scenario: Journal delivery degraded by contention
- **WHEN** FSEvents cannot enumerate changes because its per-client queue overflowed and it raises `MustScanSubDirs`
- **THEN** the system falls back coherently with a recorded reason rather than presenting an incorrect or empty result

### Requirement: Suite results are trustworthy signals
The system's test suite SHALL produce a failure only when a guarantee is actually violated, so that a red run attributes to the change under test rather than to ambient contention.

#### Scenario: Unrelated change under load
- **WHEN** the full suite runs under contention against a change that does not touch scan supervision
- **THEN** the supervision tests pass, so the run's result attributes to the change under test

#### Scenario: Real supervision regression
- **WHEN** a change genuinely breaks a supervision guarantee
- **THEN** the corresponding test fails reliably rather than intermittently, and its assertion still names the violated guarantee

### Requirement: Intermittency is diagnosed from captured state, not inferred
The system SHALL make the supervision state at the moment of an assertion failure observable, so a cause can be established from evidence rather than from line numbers.

#### Scenario: Assertion fails during a run
- **WHEN** a supervision assertion fails
- **THEN** the recorded diagnostics identify whether the journal replay poisoned and with which flag, whether the patch was abandoned and why, and what progress status was published
