# warm-patch-supersession Specification

## Purpose
Preserve committed filesystem content and index safety when a newer scan supersedes an in-flight warm patch.
## Requirements
### Requirement: Supersession never loses committed content
The system SHALL ensure that when a newer scan supersedes a warm patch, the resulting tree contains every filesystem entry present on disk, including entries created during the patch, so that supersession can never cause the displayed tree to under-report.

#### Scenario: Newer cold scan arrives after the trailing tier commits
- **WHEN** a newer cold scan supersedes a warm patch whose trailing tier has already committed but whose token check has not yet run
- **THEN** the resulting tree is structurally indistinguishable from a fresh cold scan of the same on-disk fixture, with no path missing

#### Scenario: Newly created files in either tier
- **WHEN** files are created under both an interactive root and an ephemeral root during a patch that is then superseded
- **THEN** both files are present in the resulting tree

#### Scenario: Supersession during the interactive tier
- **WHEN** a newer scan supersedes a warm patch before the interactive tier commits
- **THEN** the resulting tree still matches a fresh cold scan, whether that is achieved by completing the patch or by discarding it in favour of the newer scan's own enumeration

### Requirement: Detaching a mutated tree preserves index-keyed safety
The system SHALL continue to detach a displayed tree synchronously when a superseding scan begins, so a cancelled scanner cannot commit renumbered nodes under stale index-keyed state, and SHALL do so without discarding content already committed.

#### Scenario: Cancelled scanner commits after detach
- **WHEN** a warm patch's scanner commits after cancellation and after the displayed tree has been detached
- **THEN** no index-keyed UI state refers to renumbered nodes, and no committed content is lost

### Requirement: Supersession behaviour is deterministically testable
The system SHALL expose enough control over patch progression that supersession can be placed at a chosen point in the patch, so that these guarantees are verified deterministically rather than by intermittent scheduling.

#### Scenario: Supersession placed in a named window
- **WHEN** a test needs a newer scan to arrive between a tier's commit and its token check
- **THEN** it can gate the patch at that point without relying on machine load or timing luck
