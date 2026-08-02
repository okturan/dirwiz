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

### Requirement: Folders cards preserve local boundary and text contrast

Every decorated Folders card SHALL retain an explicit outer boundary independent of the palette
colours on either side. A selected surface profile MAY add directional bevels, but a bevel-free
profile SHALL keep the flat centre and boundary without synthesizing extra colour bands. Every edge
treatment SHALL fade out before it could consume a tiny card and SHALL not shrink its hit target.
Leaf labels SHALL choose black or white from the selected depth colour with at least 4.5:1 contrast
when no post-palette overlay is active.

#### Scenario: Two saturated depth colours touch

- **WHEN** a decorated child card is drawn over a differently coloured parent or sibling
- **THEN** a dark boundary SHALL separate the two surfaces without depending on their hue distance
- **AND** Classic Bevel SHALL make the top and left inside edges brighter than the bottom and right
  inside edges
- **AND** Crisp SHALL omit those bevel bands
- **AND** the card centre SHALL retain the selected palette colour instead of a whole-tile gradient

#### Scenario: A card becomes too small for edge decoration

- **WHEN** a card shrinks below line sizes
- **THEN** it SHALL remain fully occupied, with no missing pixels, no near-black outline, and no
  bevel
- **AND** from the 3pt micro floor up it MAY darken only toward its own edge so equal-colour
  neighbours stay distinguishable, while below that floor it SHALL draw as exact plain fill
- **AND** its complete layout rectangle SHALL remain its hit target at every size

#### Scenario: A bright depth colour carries a file label

- **WHEN** black has greater contrast than white against the card's selected depth colour
- **THEN** the file label SHALL use black
- **AND** every scheme-depth combination SHALL provide at least 4.5:1 contrast with its chosen
  black-or-white label
- **AND** Cushion and active recency or temporal overlays SHALL retain the established safe white
  label treatment

### Requirement: Native Folders review separates surface from palette

While the visual decision is open, Folders SHALL expose exactly six numbered surface profiles that
are independent of the ten depth palettes. Switching surface SHALL repaint and, where required,
re-nest the currently displayed rectangles without a filesystem scan or a new Squarify layout.

#### Scenario: The user opens the surface picker

- **WHEN** Folders is selected
- **THEN** the view SHALL offer `1. Crisp`, `2. Fine Lines`, `3. Tinted Frames`,
  `4. Color Headers`, `5. Soft Cards`, and `6. Classic Bevel`
- **AND** the current surface and current color palette SHALL be identified independently
- **AND** an absent or invalid surface preference SHALL resolve to `1. Crisp`

#### Scenario: The user switches surface on a displayed tree

- **WHEN** a different surface number is selected
- **THEN** the app SHALL keep the same filesystem tree, Squarify layout, root, selection, and
  navigation state
- **AND** it SHALL rebuild card instances, post-nesting display rectangles, labels, and the Folders
  hit grid together
- **AND** the complete pre-gap display rectangle SHALL remain clickable

### Requirement: Surface profiles address distinct structural failures

The comparison SHALL include bevel-free, narrow-frame, quiet-container, header-color, soft-edge,
and source-inspired treatments. Quiet-container treatments SHALL derive folder chrome from the
selected depth color rather than extension identity, while leaves SHALL retain the exact selected
depth color.

#### Scenario: Crisp or Fine Lines is selected

- **THEN** cards SHALL use a flat center and SHALL NOT draw a directional bevel
- **AND** parent-frame padding SHALL be smaller than Classic Bevel
- **AND** every decorated card SHALL retain a visible boundary

#### Scenario: Tinted Frames is selected

- **THEN** expanded-folder frames SHALL be darker and less chromatic than their selected depth color
- **AND** files, aggregates, and collapsed content blocks SHALL retain the unmodified depth color

#### Scenario: Color Headers is selected

- **THEN** an expanded folder SHALL use quiet chrome around its children
- **AND** its reserved title row SHALL retain the selected depth color
- **AND** the folder title SHALL choose black or white for measured contrast without a dark chip

#### Scenario: Classic Bevel is selected

- **THEN** the source-inspired dark outline and bright-top-left/dark-bottom-right dual bevel SHALL
  remain available as the reference control

### Requirement: Folder title rows preserve the name before metadata

Every labelled expanded folder SHALL own the usable width of its reserved header row instead of
placing text inside an intrinsic rounded chip. Size metadata SHALL appear only when the row can fit
it without materially squeezing the folder name.

#### Scenario: A long folder name has limited width

- **WHEN** the header is wide enough for a name but not both a long name and size metadata
- **THEN** the title row SHALL omit the size
- **AND** the folder name SHALL retain the row's available width with middle truncation only as a
  final containment measure
- **AND** the title row SHALL remain clipped to the folder's displayed rectangle

### Requirement: Card boundary treatment adapts to drawn size

Folders SHALL choose each card's boundary treatment from the card's drawn size instead of applying
one fixed weight everywhere. Every surface profile SHALL share this backbone: separation SHALL
never fade to zero above the micro floor, boundary ink SHALL stay bounded at dense reading sizes,
and a profile's own structural character SHALL apply only on structurally large cards.

#### Scenario: Same-colour siblings render at dense sizes

- **WHEN** same-depth siblings are drawn below line sizes
- **THEN** each tile SHALL darken toward its own edge as a soft valley instead of drawing an
  outline or bevel
- **AND** tile centres SHALL keep the exact selected depth colour
- **AND** adjacent equal-colour tiles SHALL remain distinguishable

#### Scenario: Tiles render at reading sizes

- **WHEN** a card's smaller side is in the teens of points
- **THEN** its boundary SHALL be a darker shade of the card's own colour at a floored opacity
- **AND** every profile SHALL keep at least the guaranteed minimum background seam
- **AND** no profile SHALL apply its full structural outline weight or any directional bevel there

#### Scenario: Cards reach structural sizes

- **WHEN** a card's smaller side reaches structural sizes
- **THEN** the boundary SHALL blend toward the selected profile's structural colour, width, and
  opacity
- **AND** bevel-bearing profiles SHALL reach full bevel strength only at the top of the bevel ramp
- **AND** the adaptive backbone constants SHALL be mirrored between the Swift geometry and the
  Metal source

### Requirement: Folders surface selection is isolated from Cushion

Changing surface SHALL have no effect on Cushion instances, coefficients, shading, layout,
resolved-color cache identity, labels, or hit targets.

#### Scenario: Surface numbers are compared in Cushion

- **WHEN** Cushion is active and any two Folders surfaces are selected
- **THEN** the offscreen Cushion output SHALL remain pixel-identical
- **AND** no card-role marker or frame geometry SHALL enter the Cushion instance path
