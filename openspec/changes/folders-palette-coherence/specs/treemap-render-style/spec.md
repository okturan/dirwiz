## ADDED Requirements

### Requirement: Native Folders review exposes ten real renderer schemes

While the color decision is open, Folders SHALL expose exactly ten numbered schemes driven by the
production Swift renderer. Switching scheme SHALL repaint the current tree without rescanning,
relayout, navigation loss, or hit-testing changes.

#### Scenario: The user opens the Folders color picker

- **WHEN** Folders is selected
- **THEN** the native view SHALL offer schemes numbered 1 through 10 with distinct names
- **AND** every option SHALL own a distinct outer-folder colour and a distinct eight-level folder
  palette
- **AND** the current selection SHALL be visibly identified

#### Scenario: The user compares two schemes

- **WHEN** the user selects another numbered scheme
- **THEN** every displayed Folders card SHALL repaint from that scheme's depth table
- **AND** the visible Folders depth key SHALL repaint to the same table
- **AND** the current root, selection, layout, labels, overlays, and hit targets SHALL remain intact

#### Scenario: The app relaunches during review

- **WHEN** a scheme has been selected and the app relaunches or scans again
- **THEN** the same numbered scheme SHALL remain selected
- **AND** an absent or invalid preference SHALL resolve to `1. SpaceMonger`

### Requirement: Review candidates are complete map palettes

Every Folders candidate SHALL provide eight explicit colours indexed by tree depth and SHALL apply
them to folders, files, collapsed blocks, and density aggregates. The ten outermost colours SHALL be
pairwise distinct and every adjacent depth pair SHALL have material RGB distance.

#### Scenario: The complete comparison set is inspected

- **WHEN** all ten structural tables are evaluated at depths 0 through 7
- **THEN** no two tables or depth-zero colours SHALL be equal
- **AND** option 1 SHALL match SpaceMonger 1.4's eight `BoxColors` base colours
- **AND** the set SHALL not be representable as ten blend strengths around one shared ramp

### Requirement: One depth semantic spans every Folders role

Every Folders candidate SHALL use its selected `depth & 7` colour for direct files, expanded folders,
collapsed folders, and density aggregates. It SHALL NOT change to extension colours at the leaf or
collapse boundary. Cushion SHALL continue to use production extension colours.

#### Scenario: Two differently typed files occupy the same depth

- **WHEN** Folders renders two direct files with different extension palette colours at one depth
- **THEN** both files SHALL use the selected scheme's colour for that depth
- **AND** a folder or aggregate at that depth SHALL use the same colour
- **AND** switching to Cushion SHALL restore the two production extension colours

#### Scenario: A fresh comparison build is launched

- **WHEN** no stored scheme exists
- **THEN** `1. SpaceMonger` SHALL be selected
- **AND** its eight colours SHALL match the reference `BoxColors` base row

### Requirement: Folder roles follow the selected recipe

The selected recipe SHALL control every visible Folders card. Expanded, collapsed, aggregate, file,
and actually-empty folder roles SHALL not introduce a second colour semantic.

#### Scenario: An expanded folder has coloured descendants

- **WHEN** a non-empty expanded folder is rendered under any review scheme
- **THEN** its panel SHALL remain the scheme's structural depth colour
- **AND** descendant extension colour SHALL not create a subtree-wide veil

#### Scenario: A folder is collapsed by density

- **WHEN** one tile represents the folder's hidden contents
- **THEN** the tile SHALL use the selected colour for that folder's depth
- **AND** expanding it SHALL continue the same adjacent depth sequence

### Requirement: Cushion is isolated from Folders comparison

Cushion SHALL ignore every Folders scheme input. Changing the numbered Folders scheme SHALL not
alter Cushion colors, palette assignments, layout, resolved-color cache identity, or direct-child
directory behavior.

#### Scenario: Scheme changes while Cushion is selected

- **WHEN** any two Folders schemes are compared at the Cushion color-input boundary
- **THEN** both SHALL produce the identical raw Cushion palette color
- **AND** no Folders depth treatment SHALL leak into Cushion

### Requirement: Density aggregation preserves occupied content area

Folders SHALL NOT expose structural folder background merely because individually small descendants
fall below the layout or card-visibility threshold. A contiguous group that is collectively visible
SHALL be represented by an occupied aggregate rectangle covering that group's layout region.

#### Scenario: Half the bytes are individually sub-threshold

- **GIVEN** one file owns half a folder's bytes and many individually sub-threshold files own the
  other half
- **WHEN** the Folders layout applies its density cutoff
- **THEN** non-background content rectangles, including aggregates, SHALL cover at least 98% of the
  folder's available area
- **AND** the small-file half SHALL not appear as the owning folder's parent-depth colour

#### Scenario: An aggregate contains hidden content

- **WHEN** one aggregate rectangle stands in for a contiguous group of hidden descendants
- **THEN** it SHALL use the selected Folders colour for its depth
- **AND** it SHALL not display the representative child's name as though that child owns the group
- **AND** hit testing SHALL resolve to the owning folder
- **AND** zooming the owning folder SHALL remain the path to the underlying detail

#### Scenario: Cushion renders the same tree

- **WHEN** the view switches from Folders to Cushion
- **THEN** Folders-only aggregate rectangles SHALL not be drawn
- **AND** Cushion's existing rect colors, labels, and hit targets SHALL remain unchanged

### Requirement: Folders exposes the correct visible color key

Folders SHALL show the selected eight-colour depth key above the File Types breakdown. The breakdown
SHALL state that map colours show depth and SHALL retain its extension drill-down behavior. Cushion
SHALL continue to present File Types as its map colour key.

#### Scenario: The user switches from Cushion to Folders

- **WHEN** Folders becomes active
- **THEN** an outer-to-inner eight-swatch key SHALL show the selected scheme
- **AND** the sidebar SHALL state that map colours show depth
- **AND** File Types rows SHALL remain usable for size comparison and Search drill-down
