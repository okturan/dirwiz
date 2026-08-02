## ADDED Requirements

### Requirement: Folders leaves remain a readable extension key

Folders SHALL render direct files with clearly chromatic extension colors inside folder chrome. For
every production palette color at one container depth, the rendered direct leaf SHALL retain between
55% and 65% of source channel spread and pairwise color distance. Cushion SHALL continue to use the
unmodified extension palette.

#### Scenario: A large same-extension region is shown in Folders

- **WHEN** one extension occupies a large visible region of a Folders treemap
- **THEN** red, blue, green, and other production colors SHALL remain visibly chromatic
- **AND** they SHALL NOT collapse into a grey or slate-only code

#### Scenario: Extension identity survives the chrome transform

- **WHEN** the 17 production palette colors are transformed at the same parent depth
- **THEN** each color SHALL preserve its channel ordering
- **AND** pairwise distances SHALL be scaled uniformly rather than unpredictably collapsed

#### Scenario: Cushion is selected

- **WHEN** the user switches from Folders to Cushion
- **THEN** leaves SHALL use the raw extension palette under Cushion lighting
- **AND** the Folders transform SHALL NOT alter cached Cushion palette assignments

### Requirement: Folders hierarchy carries representative content hue

Folders SHALL derive a representative extension from a non-empty directory's descendant content,
including when no file is an immediate child. Expanded panels SHALL use that representative as a
quiet structural tint; collapsed folders SHALL use it with file-like chroma because they stand in
for their hidden contents. Actually empty folders SHALL remain neutral.

#### Scenario: Files exist below directory-only levels

- **WHEN** a visible folder's immediate children are directories and its files occur deeper
- **THEN** Folders SHALL follow the largest on-disk content branch to a representative extension
- **AND** the folder SHALL NOT fall back to unrelated grey merely because it has no direct files

#### Scenario: Direct files compete with a child subtree

- **WHEN** a directory contains direct files and child directories
- **THEN** direct file bytes SHALL be aggregated by extension and compared with the largest child
  directory's on-disk bytes
- **AND** the larger content shape SHALL determine the representative extension
- **AND** equal-size decisions SHALL use a stable tie-break

#### Scenario: A folder is expanded

- **WHEN** a folder panel surrounds visible descendants
- **THEN** it SHALL carry a quieter version of the representative content hue
- **AND** the panel SHALL bridge rather than create an abrupt neutral-grey-to-file-color boundary

#### Scenario: A folder is collapsed by the Folders density rule

- **WHEN** a folder is too small to subdivide and one tile represents all of its contents
- **THEN** that tile SHALL retain file-like representative chroma
- **AND** it SHALL NOT be painted like an empty structural panel

#### Scenario: Cushion resolves the same nested folder

- **WHEN** Cushion is selected for a directory with no direct file children
- **THEN** its historical direct-child directory color behavior SHALL remain unchanged
- **AND** the Folders-only descendant lookup SHALL NOT leak into Cushion rendering

### Requirement: The visible color key matches the selected render style

The always-visible File Types legend SHALL represent the direct-file colors used by the selected
treemap style. Folders SHALL use a stable depth-zero representative of its transformed direct-file
colors; Cushion SHALL use the raw palette.

#### Scenario: The user switches render style

- **WHEN** the user switches between Cushion and Folders
- **THEN** the legend swatches SHALL update with the direct-leaf treemap style
- **AND** extension names, ranking, sizes, counts, and selection actions SHALL remain unchanged

### Requirement: The website Cards demo follows direct-leaf app color policy

The interactive website demo SHALL apply the same direct-leaf chrome blend when Cards is selected
and SHALL leave Cushion colors unchanged. It does not claim parity for native nested panel tinting.

#### Scenario: A visitor toggles the browser demo

- **WHEN** the visitor switches the live demo from Cushions to Cards
- **THEN** leaf colors SHALL use the app's documented direct-leaf factor
- **AND** switching back SHALL restore the raw Cushion palette
