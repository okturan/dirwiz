## MODIFIED Requirements

### Requirement: Shallow reconciliation preserves cold-scan equivalence

A shallow target whose fresh entry level matches its cached children by name and type SHALL be
patched by in-place metadata updates without re-enumerating or restructuring child subtrees.
Any structural difference at that level SHALL be reconciled by the level diff defined in
`selective-child-rescan` - installing only the added entries and removing only the vanished
ones - rather than by re-enumerating the target's whole subtree. Every outcome SHALL leave the
tree indistinguishable from a fresh cold scan.

#### Scenario: A file directly inside the target changed size

- **WHEN** a shallow target's level matches the cached children by name and type
- **THEN** existing child nodes SHALL receive the fresh metadata in place
- **AND** no child subtree SHALL be re-enumerated
- **AND** the resulting tree SHALL equal a fresh cold scan after aggregate recomputation

#### Scenario: An entry appeared or vanished at the target's level

- **WHEN** the fresh level differs from the cached children in names or types
- **THEN** only the differing entries SHALL be enumerated or removed
- **AND** unchanged siblings SHALL keep their existing subtrees without re-enumeration
- **AND** staged targets nested beneath a removed entry SHALL be dropped as covered
- **AND** the resulting tree SHALL equal a fresh cold scan

#### Scenario: Files directly inside the scan root changed

- **WHEN** the tree root becomes a target only through file events directly inside it
- **THEN** the patch SHALL reconcile the root's own level instead of abandoning
- **AND** a root-level target whose level changed shape SHALL likewise be reconciled by level
  diff rather than forcing a cold fallback
