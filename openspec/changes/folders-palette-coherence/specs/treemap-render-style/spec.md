## ADDED Requirements

### Requirement: Folders colors belong to the folder surface

Folders SHALL render file-extension color as a subordinate accent within neutral folder chrome.
For every production palette color at one container depth, the rendered leaf SHALL retain between
20% and 30% of the source channel spread and pairwise color distance. Cushion SHALL continue to use
the unmodified extension palette.

#### Scenario: A large same-extension region is shown in Folders

- **WHEN** one extension occupies a large visible region of a Folders treemap
- **THEN** its tiles SHALL read as tinted members of the surrounding folder surface
- **AND** the extension color SHALL NOT dominate the neutral hierarchy as a near-primary field

#### Scenario: Extension identity survives the settling transform

- **WHEN** the 17 production palette colors are transformed at the same parent depth
- **THEN** each color SHALL preserve its channel ordering
- **AND** pairwise distances SHALL be scaled uniformly rather than unpredictably collapsed

#### Scenario: Cushion is selected

- **WHEN** the user switches from Folders to Cushion
- **THEN** leaves SHALL use the raw extension palette under Cushion lighting
- **AND** the Folders settling transform SHALL NOT alter cached palette assignments

### Requirement: The visible color key matches the selected render style

The always-visible File Types legend SHALL represent the colors used by the selected treemap style.
Folders SHALL use a stable depth-zero representative of its settled colors; Cushion SHALL use the
raw palette.

#### Scenario: The user switches render style

- **WHEN** the user switches between Cushion and Folders
- **THEN** the legend swatches SHALL update with the treemap style
- **AND** extension names, ranking, sizes, counts, and selection actions SHALL remain unchanged

### Requirement: The website Cards demo follows app color policy

The interactive website demo SHALL apply the same Folders chrome blend when Cards is selected and
SHALL leave Cushion colors unchanged.

#### Scenario: A visitor toggles the browser demo

- **WHEN** the visitor switches the live demo from Cushions to Cards
- **THEN** the leaf colors SHALL settle toward neutral chrome by the app's documented factor
- **AND** switching back SHALL restore the raw Cushion palette
