## ADDED Requirements

### Requirement: A warm patch is never abandoned once finishing is cheaper than restarting
The system SHALL evaluate the mid-patch staged-item guard against the projected remaining work rather than the work already staged, and SHALL continue a patch whose remaining cost is below that of the cold scan it would fall back to.

#### Scenario: Patch exceeds its predicted size but is nearly complete
- **WHEN** staged items exceed the predicted budget while the remaining roots represent a small fraction of the tree
- **THEN** the patch continues to completion rather than abandoning, because a cold scan would repeat the work already done

#### Scenario: Patch is genuinely oversized
- **WHEN** staged items exceed the predicted budget and the projected remaining work still exceeds the cost of a cold scan
- **THEN** the patch abandons into a coherent cold fallback whose reason is recorded

#### Scenario: Approximation fails safe
- **WHEN** the projected remaining work cannot be estimated confidently
- **THEN** the patch continues rather than abandoning, so an uncertain estimate never discards completed work

### Requirement: Prediction and measurement budgets are distinct
The system SHALL derive the mid-patch guard's threshold separately from the up-front gate's threshold, because the up-front value predicts from a cached tree that cannot represent newly created content while the guard measures items actually staged.

#### Scenario: Content created since the cache was written
- **WHEN** a changed root contains many items that did not exist when the cache was written
- **THEN** the up-front gate admits the patch on its cached estimate and the guard evaluates the real staged count against its own threshold

#### Scenario: Thresholds independently adjustable
- **WHEN** either threshold is changed
- **THEN** the other is unaffected, and each carries its own recorded rationale

### Requirement: Unbounded subtree growth is still refused
The system SHALL abandon a warm patch into a coherent cold fallback when a changed subtree has grown far beyond its cached size, so growth invisible to the up-front estimate cannot carry an arbitrarily large patch to completion.

#### Scenario: Subtree grew by orders of magnitude
- **WHEN** a changed root's real subtree is vastly larger than the cached subtree the estimate was derived from, and the remainder still exceeds a cold scan
- **THEN** the patch abandons, the reason is recorded in the scan summary, and the resulting tree is coherent

### Requirement: The warm-patch status assertion is preserved
The system SHALL continue to publish a warm-patch-specific status during a warm patch, so tests can distinguish a genuine warm patch from a cold fallback that would otherwise satisfy their assertions for the wrong reason.

#### Scenario: Warm patch in flight behind a stale view
- **WHEN** a warm patch is running behind a preserved stale view
- **THEN** the published progress status identifies it as a warm patch rather than a generic or cold-scan status
