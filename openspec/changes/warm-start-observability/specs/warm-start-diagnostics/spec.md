# warm-start-diagnostics

## ADDED Requirements

### Requirement: Cache-load failure reason distinct from no-cache
When a cache file exists on disk for the target path but fails to load (structural corruption, version mismatch, checksum failure), the system SHALL produce a specific human-readable reason and route it through the same cold-fallback reason mechanism used for planner-declined warm starts, rather than silently cold-scanning with no explanation.

#### Scenario: Version-mismatched cache
- **WHEN** a cache file exists but was written by an older format version
- **THEN** the resulting cold scan's summary names the reason (e.g. "cache format outdated"), not just "Scanned N items"

#### Scenario: No cache ever existed
- **WHEN** a volume has never been scanned before
- **THEN** the resulting cold scan's summary does not claim a cache was rejected — it reads as a first scan, not a failure

### Requirement: A cache rejected at launch surfaces a reason without auto-scanning
When the app's launch-time restore (`restoreOnLaunch`) discovers that the previously scanned volume's cache exists but fails to load, the system SHALL surface the rejection reason (via the summary shown at launch and the decision history) without automatically starting a scan — the existing empty-launch-state behavior for "nothing to restore" is unchanged; only the explanation is added.

#### Scenario: Corrupted cache discovered at launch
- **WHEN** the app launches, a prior scan's path is remembered, and that path's cache file exists but is structurally corrupted
- **THEN** the launch summary names the rejection reason, a history entry records it, and no scan starts automatically

#### Scenario: Behavior matches the no-cache-at-all case except for the message
- **WHEN** comparing a launch where no cache was ever written against a launch where a cache existed but was rejected
- **THEN** both leave the app in the same empty, no-scan-running state — only the rejected case's summary explains why

### Requirement: Warm-patch abandonment surfaces a reason
When a warm-start patch is attempted but abandoned mid-flight (unresolved changed paths, or a change resolving to the scan root with nothing narrower), the resulting cold fallback SHALL carry a specific reason through the same mechanism as a planner-declined warm start, not a silent, unexplained cold scan.

#### Scenario: Unresolved path abandons the patch
- **WHEN** a warm-start patch can't resolve one of its changed paths against the cached tree and falls back to cold
- **THEN** the resulting scan summary names that as the reason, distinct from "no cache" or "planner declined"

### Requirement: Warm-start decision history persists across launches
The system SHALL persist a capped, append-only history of warm-start decisions per volume (at minimum: timestamp, warm-or-cold, reason if cold, item count, elapsed time), surviving app relaunch, so a pattern across multiple launches is inspectable rather than only the most recent decision.

#### Scenario: Recurring cold fallback visible
- **WHEN** the last 5 launches for a volume all cold-scanned for the same reason
- **THEN** the persisted history shows all 5 entries with that reason, not just the latest one

### Requirement: History is capped, not unbounded
The persisted history SHALL retain at most a fixed number of recent entries per volume (oldest evicted first), so it cannot grow without bound over the life of the app.

#### Scenario: Cap enforced
- **WHEN** more than the cap's worth of scans have occurred for a volume
- **THEN** only the most recent entries up to the cap remain in the persisted history

### Requirement: Decision reason reaches the system log at a persisted level
Every warm-start decision (warm or cold-fallback) SHALL be logged at a level the system log store actually persists, so `log show` can retrieve it after the fact without requiring a live `log stream` session or an ad hoc diagnostic build.

#### Scenario: Retroactive log inspection
- **WHEN** a cold fallback occurred during a past launch and the user later runs `log show` for the app's subsystem
- **THEN** the fallback reason appears in the results

### Requirement: History visible in the UI without reading logs
The system SHALL provide a discoverable UI affordance showing the persisted warm-start history, so a user (or developer) can see why recent scans were cold without inspecting logs or writing diagnostic code.

#### Scenario: Affordance shows recent decisions
- **WHEN** the user opens the warm-start history affordance
- **THEN** the last several decisions are listed with their timestamps, warm/cold status, and reasons where applicable
