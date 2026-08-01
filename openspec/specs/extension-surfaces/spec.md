# extension-surfaces Specification

## Purpose
Define the shared extension legend, row presentation, navigation, and analysis capabilities exposed across DirWiz surfaces.
## Requirements
### Requirement: Interactive legend rows
Legend rows SHALL be tappable: tapping a concrete extension row SHALL activate the Search tab filtered to that extension (identical outcome to the Extensions tab's drill-down). A hover affordance SHALL indicate interactivity. Tapping the synthetic "Other" row SHALL open the Extensions tab instead.

#### Scenario: Legend drill-down
- **WHEN** the user taps the ".mp4" row in the legend
- **THEN** the Search tab activates with the extension filter set to mp4, matching the Extensions-tab drill-down behavior

#### Scenario: Other routes to the full table
- **WHEN** the user taps the "Other" legend row
- **THEN** the Extensions tab opens (no extension filter is applied)

### Requirement: Shared row presentation
The legend and the Extensions tab SHALL render extension rows through one shared component with consistent visual hierarchy (color swatch, display name, size, file count, percentage), differing only in density/columns appropriate to each surface.

#### Scenario: Consistent rendering
- **WHEN** the same extension appears in both surfaces
- **THEN** its swatch color, display name, and size formatting are identical in both

### Requirement: See-all navigation
The legend SHALL include a "See all file types" footer that opens the Extensions tab.

#### Scenario: Footer navigation
- **WHEN** the user clicks the legend's see-all footer
- **THEN** the active tab switches to Extensions

### Requirement: Extensions tab capabilities preserved
The Extensions tab SHALL retain its filter field, sort options (name, size, count, category), category column, and drill-down behavior.

#### Scenario: Table unchanged in capability
- **WHEN** the user filters and sorts in the Extensions tab after this change
- **THEN** all pre-existing capabilities behave as before
