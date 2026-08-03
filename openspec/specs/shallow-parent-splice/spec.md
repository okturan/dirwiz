# shallow-parent-splice Specification

## Purpose
Scope file-derived warm-start and living-view targets to the parent's own entry level, with honest estimates, in-place metadata reconciliation, structural promotion, and cold-scan equivalence.
## Requirements
### Requirement: File-derived targets are scoped to the parent's own entry level

The system SHALL record, for every changed-directory target, whether any FSEvents event
reported the directory itself. A target whose only evidence is file events directly inside it
SHALL be treated as shallow: eligible for one-level reconciliation and never charged its cached
subtree by the admission estimator.

#### Scenario: Background noise touches files directly inside the home folder

- **WHEN** a replay window contains file events for entries directly inside a huge directory
  and no directory-level event for that directory
- **THEN** the directory SHALL become a shallow target estimated at its direct child count
- **AND** the admission gate SHALL NOT see its cached subtree size
- **AND** precise deeper targets SHALL survive collapse beside it

#### Scenario: The directory itself was reported changed

- **WHEN** any event in the window reports the directory itself
- **THEN** the target SHALL keep full-subtree semantics, estimation, and collapse behavior

### Requirement: Shallow reconciliation preserves cold-scan equivalence

A shallow target whose fresh entry level matches its cached children by name and type SHALL be
patched by in-place metadata updates without re-enumerating or restructuring child subtrees.
Any structural difference at that level SHALL promote the target to full-subtree rescan
semantics before any mutation. Every outcome SHALL leave the tree indistinguishable from a
fresh cold scan.

#### Scenario: A file directly inside the target changed size

- **WHEN** a shallow target's level matches the cached children by name and type
- **THEN** existing child nodes SHALL receive the fresh metadata in place
- **AND** no child subtree SHALL be re-enumerated
- **AND** the resulting tree SHALL equal a fresh cold scan after aggregate recomputation

#### Scenario: An entry appeared or vanished at the target's level

- **WHEN** the fresh level differs from the cached children in names or types
- **THEN** the target SHALL be promoted to a full-subtree rescan before any mutation
- **AND** staged targets nested beneath the promotion SHALL be dropped as covered
- **AND** the resulting tree SHALL equal a fresh cold scan

#### Scenario: Files directly inside the scan root changed

- **WHEN** the tree root becomes a target only through file events directly inside it
- **THEN** the patch SHALL reconcile the root's own level instead of abandoning
- **AND** a deep or promoted root-level target SHALL keep the existing cold fallback

### Requirement: The living view shares shallow scoping

The live monitor's file-to-parent reduction SHALL carry the same kind tagging, and accumulated
changes SHALL merge kinds with directory-level evidence winning. Live applies SHALL pass
shallow scoping into the same splice path.

#### Scenario: A watched volume sees only direct-file churn in a huge directory

- **WHEN** accumulated live changes for a directory consist solely of file events directly
  inside it
- **THEN** the next apply SHALL reconcile that directory's level in place
- **AND** SHALL NOT re-stage the directory's subtree
