## ADDED Requirements

### Requirement: Disjoint subtree replacements commit in one compaction

The system SHALL resolve every replacement target against one pre-mutation tree snapshot and SHALL
apply all valid, disjoint staged replacements in one flat-array rebuild rather than recompacting the
entire tree once per target.

#### Scenario: Several changed roots are ready to splice

- **WHEN** a warm patch has staged replacements for multiple disjoint target directories
- **THEN** every target is resolved before mutation
- **AND** the replacements are committed through one compaction and renumbering pass

#### Scenario: A staged directory becomes empty

- **WHEN** a valid replacement contains only its staged root placeholder and no descendants
- **THEN** the target directory remains in the tree with no children
- **AND** the other replacements in the batch still commit normally

### Requirement: Batched replacement preserves flat-tree invariants

The system SHALL preserve node order, contiguous child slices, parent-before-child ordering, name
offset validity, and path resolution after a batched replacement, and SHALL invalidate indexes whose
entries refer to the old node numbering.

#### Scenario: Replacement renumbers survivors and staged descendants

- **WHEN** one batch removes old descendants and inserts staged descendants at several positions
- **THEN** every surviving and inserted parent and first-child reference resolves to the rebuilt
  array
- **AND** path lookup returns the same filesystem shape as applying the equivalent replacements
  sequentially

#### Scenario: Search was indexed before the splice

- **WHEN** a batch commits after the tree's search index has been built
- **THEN** the stale search index is discarded and a subsequent search is built against the new node
  numbering

### Requirement: Invalid or interrupted batches never publish a partial patch

The system SHALL validate the complete batch before commit and MUST NOT leave the displayed tree with
only a subset of the requested roots replaced.

#### Scenario: A target is unresolved or collapses to the scan root

- **WHEN** any requested replacement cannot be resolved safely or would replace the scan root
- **THEN** the warm patch is abandoned before mutation
- **AND** the caller may fall back to a coherent cold scan

#### Scenario: Replacement targets overlap

- **WHEN** one proposed target is a descendant of another proposed target
- **THEN** the batch is rejected before mutation because the targets are not disjoint

#### Scenario: Cancellation interrupts batched work

- **WHEN** cancellation is observed before the batch can publish a complete rebuilt tree
- **THEN** the system publishes either the untouched old tree or a structurally complete committed
  tree, never a half-spliced tree

### Requirement: Structural splice work scales with one tree rebuild

The batched primitive SHALL perform one shared survivor-marking and rebuild pass for the batch, so
increasing the number of disjoint targets does not reintroduce one full-tree compaction per root.

#### Scenario: Many scattered targets

- **WHEN** dozens or hundreds of small disjoint replacements are applied to a large cached tree
- **THEN** structural compaction remains within a small multiple of one single-root full-tree rebuild
- **AND** progress reports one honest applying phase for the batch

