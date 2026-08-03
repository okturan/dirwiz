## ADDED Requirements

### Requirement: Descriptor-relative traversal is gated by measured benefit

The system SHALL NOT replace the current directory work queue until a matched real-tree benchmark
shows that opening child directories relative to a live parent descriptor clearly improves on
opening the same directories by full path.

#### Scenario: Relative opens show no clear win

- **WHEN** the full-path and `openat` benchmark produce equivalent or worse results for descriptor-
  relative traversal at realistic depth
- **THEN** implementation stops before the scanner's parallel decomposition is rewritten

#### Scenario: Relative opens show a clear win

- **WHEN** `openat` materially reduces traversal time under the same attribute workload
- **THEN** the measured descriptor depth and baseline become inputs to the implementation and its
  final performance gate

### Requirement: A worker traverses a claimed subtree relative to open parents

When the measurement gate passes, each worker SHALL walk its claimed subtree depth-first and SHALL
open child directories with `openat` relative to the parent descriptor whenever the descriptor is
available.

#### Scenario: A child is below an open directory

- **WHEN** a worker enumerates a child directory while its parent descriptor is on the traversal
  stack
- **THEN** the child is opened relative to that parent without resolving the full ancestor path
- **AND** the reporting path is reconstructed from the retained ancestor names

#### Scenario: One subtree has most of the remaining work

- **WHEN** a worker owns a large subtree while other workers would otherwise become idle
- **THEN** eligible sibling subtrees are returned to the shared queue for work stealing

### Requirement: Descriptor use is bounded and fails safe

The system SHALL derive a per-worker descriptor-stack bound from the file-descriptor limit actually
obtained at runtime, SHALL close descriptors on every exit path, and SHALL fall back to a full-path
open when the bound is reached.

#### Scenario: Traversal exceeds the descriptor-stack bound

- **WHEN** a directory is deeper than the safe descriptor allowance
- **THEN** that directory is opened through the existing full-path mechanism rather than omitted or
  failed

#### Scenario: Scan is cancelled mid-subtree

- **WHEN** cancellation interrupts a descriptor-relative walk
- **THEN** every descriptor owned by the interrupted work is closed
- **AND** cancellation remains responsive at the established scanner cadence

### Requirement: Traversal output and metadata contracts remain equivalent

Descriptor-relative traversal SHALL change how directories are opened, not which filesystem
attributes are requested or which scanner results are produced.

#### Scenario: The characterization fixture is scanned by both decompositions

- **WHEN** a fixture contains protected directories, firmlink-style duplicates, hardlinks, bundles,
  and deep nesting
- **THEN** both traversal modes produce equivalent paths, sizes, counts, skip reporting, link-count
  flags, and bundle treatment

#### Scenario: Live materialisation is enabled

- **WHEN** a cold scan publishes progressively while workers walk subtrees depth-first
- **THEN** the tree remains structurally valid at every publication
- **AND** the final tree is equivalent to the current traversal result

