# treemap-render-style

## ADDED Requirements

### Requirement: Selectable render style
The treemap SHALL offer two render styles — Cushion and Cards — with Cushion remaining the default. The choice SHALL persist across launches. Switching styles SHALL NOT change the underlying layout, sizes, or which nodes exist.

#### Scenario: Switching preserves layout
- **WHEN** the user switches from Cushion to Cards on the same tree and view root
- **THEN** every node occupies the same layout position and area; only its painting changes

#### Scenario: Default is unchanged
- **WHEN** a user who has never chosen a style opens the app
- **THEN** the treemap renders in Cushion style exactly as before this change

### Requirement: Card style draws nested containers
In Card style, directories SHALL be drawn as rounded containers whose children are inset within them, with a header label shown when the container is large enough to fit one legibly. Leaves SHALL be drawn with a flat directional gradient rather than cushion lighting.

#### Scenario: Nesting is visible
- **WHEN** a directory containing several files is rendered in Card style at a size large enough for insets
- **THEN** the directory reads as a container with its children visually inside it, and its name is shown when it fits

### Requirement: Geometry adapts to rect size
Corner radius and inter-rect gap SHALL scale with the smaller side of each rect and collapse to zero for small rects, so that shrinking rects degrade progressively to plain fill instead of disappearing.

#### Scenario: Small rects stay visible
- **WHEN** a rect is small enough that the full radius and gap would consume it
- **THEN** it is drawn as plain fill occupying its full area rather than vanishing or rendering as pure padding

#### Scenario: Large rects get the full treatment
- **WHEN** a rect is comfortably large
- **THEN** it is drawn with the full corner radius and gap

### Requirement: Node budget is disclosed, never silent
When a view in Card style contains more nodes than the style can draw legibly, the renderer SHALL aggregate the excess rather than drawing sub-pixel slivers, and the UI SHALL state that aggregation is in effect.

#### Scenario: Aggregation is visible to the user
- **WHEN** Card style aggregates nodes because the view exceeds its budget
- **THEN** the UI indicates that not every item is drawn individually

#### Scenario: Under budget draws everything
- **WHEN** the view's node count is within the budget
- **THEN** every node is drawn individually and no aggregation notice appears

### Requirement: Dense views fall back to Cushion
When a view is too dense for Card style to represent honestly, the treemap SHALL render it in Cushion style while preserving the user's chosen setting, so that navigating to a less dense view returns to Cards.

#### Scenario: Whole-volume root falls back
- **WHEN** Card style is selected and the user views the root of a multi-million-item volume scan
- **THEN** the treemap renders in Cushion style, and zooming into a folder that fits the budget renders in Card style again without the user re-selecting it

### Requirement: Hit testing follows layout, not insets
Hover and selection SHALL resolve against layout rects, so the node under the cursor is the node the user is pointing at regardless of the visual insets Card style applies.

#### Scenario: Selection matches the cursor
- **WHEN** the user hovers near the inset edge of a rect in Card style
- **THEN** the highlighted and selectable node is the one whose layout rect contains the cursor, with no offset between what is drawn and what responds
