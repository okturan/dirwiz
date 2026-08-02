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
- **THEN** the displayed folder hierarchy SHALL repaint from that scheme
- **AND** file tiles and the visible File Types key SHALL keep their raw extension colours
- **AND** the current root, selection, layout, labels, overlays, and hit targets SHALL remain intact

#### Scenario: The app relaunches during review

- **WHEN** a scheme has been selected and the app relaunches or scans again
- **THEN** the same numbered scheme SHALL remain selected
- **AND** an absent or invalid preference SHALL resolve to `1. Pearl`

### Requirement: Review candidates are full hierarchy palettes

Every Folders candidate SHALL provide eight explicit structural colours indexed by folder depth.
The ten outermost colours SHALL be pairwise distinct, their luminance range SHALL include both light
and dark treatments, and the set SHALL include brightening, darkening, and alternating trajectories.

#### Scenario: The complete comparison set is inspected

- **WHEN** all ten structural tables are evaluated at depths 0 through 7
- **THEN** no two tables or depth-zero colours SHALL be equal
- **AND** at least one table SHALL brighten, one SHALL darken, and one SHALL alternate with depth
- **AND** the set SHALL not be representable as ten blend strengths around one shared dark ramp

### Requirement: Every review candidate preserves extension identity

Every Folders candidate SHALL pass direct-file and collapsed-folder content through at the raw
production palette colour. Expanded structural panels SHALL not inherit descendant content tint.

#### Scenario: Production palette colors are rendered by every candidate

- **WHEN** all 17 production colors are transformed at one container depth
- **THEN** every candidate SHALL return each direct-file colour byte-for-byte
- **AND** every candidate SHALL return each collapsed content-bearing folder colour byte-for-byte
- **AND** red, blue, green, and other extension identities SHALL not be muted or shifted

#### Scenario: A fresh comparison build is launched

- **WHEN** no stored scheme exists
- **THEN** `1. Pearl` SHALL show a light outer folder surface that darkens inward
- **AND** representative descendant colours SHALL contribute zero expanded-panel tint

### Requirement: Folder roles follow the selected recipe

Folders SHALL continue to derive a representative extension from non-empty descendant content,
including directory-only chains, for collapsed folders that stand in for hidden content. The
selected recipe SHALL control the complete expanded structural depth table. Actually empty folders
SHALL remain structural palette colour.

#### Scenario: An expanded folder has coloured descendants

- **WHEN** a non-empty expanded folder is rendered under any review scheme
- **THEN** its panel SHALL remain the scheme's structural depth colour
- **AND** descendant representative color SHALL not create a subtree-wide veil

#### Scenario: A folder is collapsed by density

- **WHEN** one tile represents the folder's hidden contents
- **THEN** the tile SHALL use its raw representative extension colour
- **AND** it SHALL remain distinguishable from an actually empty structural panel

### Requirement: Cushion is isolated from Folders comparison

Cushion SHALL ignore every Folders scheme input. Changing the numbered Folders scheme SHALL not
alter Cushion colors, palette assignments, layout, resolved-color cache identity, or direct-child
directory behavior.

#### Scenario: Scheme changes while Cushion is selected

- **WHEN** any two Folders schemes are compared at the Cushion color-input boundary
- **THEN** both SHALL produce the identical raw Cushion palette color
- **AND** no Folders descendant treatment SHALL leak into Cushion

### Requirement: Website remains on the clean review baseline

While native selection is open, the local website Cards demo SHALL keep direct-file colours raw and
Cushion SHALL remain raw. The website SHALL NOT be deployed as a final palette decision
until the native winner is selected and separately verified.

#### Scenario: A visitor toggles the local browser demo

- **WHEN** the local demo switches between Cushions and Cards during review
- **THEN** direct file colors SHALL remain unwashed in both styles
- **AND** Cards geometry SHALL remain the distinguishing treatment
