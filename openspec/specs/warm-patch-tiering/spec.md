# warm-patch-tiering Specification

## Purpose
Prioritize interactive warm-patch roots ahead of ephemeral roots without weakening totals or advancing the persisted cache horizon prematurely.
## Requirements
### Requirement: Ephemeral roots are identified from the operating system, and fail open
The system SHALL derive the ephemeral path set from `confstr` (`_CS_DARWIN_USER_TEMP_DIR`, `_CS_DARWIN_USER_CACHE_DIR`) rather than hardcoded string literals, and SHALL treat nothing as ephemeral when that resolution fails, so that a failure degrades to today's single-tier patch rather than dropping content.

#### Scenario: Resolution succeeds
- **WHEN** `confstr` returns the per-user Darwin temp and cache roots
- **THEN** those roots are classified ephemeral, matched against the `/private/var/...` form that FSEvents actually reports, with the trailing slash `confstr` returns normalised away

#### Scenario: Resolution fails
- **WHEN** `confstr` returns nothing for either selector
- **THEN** no path is classified ephemeral and the warm patch behaves exactly as it did before this change

#### Scenario: Kill switch
- **WHEN** `DIRWIZ_NO_EPHEMERAL_DEFER=1` is set
- **THEN** tiering is disabled and every changed root is patched in the interactive tier

### Requirement: The warm patch splices interactive roots before ephemeral roots
The system SHALL partition the planner's target list into interactive and ephemeral tiers, splice and publish the interactive tier first, then sweep the ephemeral tier on a trailing lower-priority pass.

#### Scenario: Mixed change set
- **WHEN** a warm patch's changed roots span both ordinary content and the per-user temp root
- **THEN** the ordinary content is spliced and visible before the temp root is enumerated

#### Scenario: Both splices renumber
- **WHEN** either tier commits its transactional compaction
- **THEN** index-keyed state is invalidated and the treemap layout revision is bumped for that splice, because both renumber the flat array

### Requirement: The persisted cache horizon never claims work that was deferred
The system SHALL NOT persist a `TreeCache` whose recorded FSEvents id is newer than the changes actually applied to the tree it contains.

#### Scenario: Patch deferred and then persisted
- **WHEN** a warm patch defers the ephemeral tier and the cache is written
- **THEN** the recorded event id is held to the deferred work's horizon, so the next warm start still learns that the deferred subtree changed

#### Scenario: Interrupted before the trailing pass
- **WHEN** the app quits or the patch is cancelled between the interactive splice and the trailing sweep
- **THEN** the persisted state does not represent the ephemeral subtree as current, and a subsequent warm start re-patches it

### Requirement: Deferral changes scheduling only, never totals
The system SHALL produce, once the trailing pass completes, a tree equal to a fresh cold scan, and SHALL leave cold-scan totals unchanged by this feature.

#### Scenario: Equivalence at quiescence
- **WHEN** both tiers of a warm patch have completed
- **THEN** the resulting tree equals the tree a fresh cold scan of the same volume produces

#### Scenario: Cold scan unaffected
- **WHEN** a cold scan runs
- **THEN** ephemeral directories are enumerated and counted in full, exactly as before this change
