# warm-patch-gating Specification

## Purpose
Bound warm-patch work primarily by estimated staged items, retain root count only as a defensive backstop, and expose estimate quality.
## Requirements
### Requirement: The warm-patch decision is gated on estimated staged items
The system SHALL decide whether to attempt a warm patch primarily from the estimated number of items the changed roots represent as a fraction of the cached tree, and SHALL evaluate that rule before any root-count rule.

#### Scenario: Many roots covering few items
- **WHEN** a change set collapses to more roots than the former operational cap but remains within the high sanity backstop and the independent directory-fraction rule, and the estimated staged items are a small fraction of the tree
- **THEN** the planner decides to patch warm, because the item fraction governs

#### Scenario: Few roots covering most of the tree
- **WHEN** a change set collapses to a handful of roots whose estimated staged items exceed the configured fraction
- **THEN** the planner falls back cold and the reason names the fraction rather than the root count

#### Scenario: Roots accumulated over time
- **WHEN** changed roots have accumulated across a long interval, are individually small, and remain within the independent directory-fraction rule
- **THEN** the planner judges them on total estimated items, so accumulation alone does not force a cold fallback

### Requirement: Root count survives only as a sanity backstop
The system SHALL retain a root-count ceiling set well above any plausible real patch, applied only after the item-fraction rule, so that pathological change sets are still refused without the ceiling preempting the rule that knows the cost.

#### Scenario: Backstop far above real workloads
- **WHEN** a patch presents a root count within the backstop
- **THEN** the root count alone never causes a cold fallback

#### Scenario: Pathological root count
- **WHEN** a change set presents a root count beyond the backstop
- **THEN** the planner falls back cold and names the count

### Requirement: The staged-item estimate does not silently undershoot
The system SHALL bound the error of its staged-item estimate, which is derived from the cached tree and therefore underestimates any root that has grown since the cache was written, so that growth cannot carry an oversized patch past the gate unnoticed.

#### Scenario: Root grew since the cache was written
- **WHEN** a changed root's real subtree is substantially larger than the cached subtree the estimate is derived from
- **THEN** the patch either is refused up front or is abandoned mid-patch into a coherent cold fallback whose reason is recorded

#### Scenario: Estimate accurate
- **WHEN** the cached and real subtree sizes agree
- **THEN** the estimate is used directly and the patch proceeds

### Requirement: Per-root staged item counts are observable
The system SHALL record the estimated and actual staged item count per changed root, so that a single dominant root is visible rather than hidden inside an aggregate.

#### Scenario: One root dominates a patch
- **WHEN** a warm patch stages items across several roots and one accounts for most of them
- **THEN** the per-root counts are recorded and that root is identifiable
