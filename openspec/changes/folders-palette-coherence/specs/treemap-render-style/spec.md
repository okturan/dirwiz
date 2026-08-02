## ADDED Requirements

### Requirement: Native Folders review exposes ten real renderer schemes

While the color decision is open, Folders SHALL expose exactly ten numbered schemes driven by the
production Swift renderer. Switching scheme SHALL repaint the current tree without rescanning,
relayout, navigation loss, or hit-testing changes.

#### Scenario: The user opens the Folders color picker

- **WHEN** Folders is selected
- **THEN** the native view SHALL offer schemes numbered 1 through 10 with distinct names
- **AND** each option SHALL change at least one renderer recipe input
- **AND** the current selection SHALL be visibly identified

#### Scenario: The user compares two schemes

- **WHEN** the user selects another numbered scheme
- **THEN** the displayed tree and visible File Types key SHALL repaint from that scheme
- **AND** the current root, selection, layout, labels, overlays, and hit targets SHALL remain intact

#### Scenario: The app relaunches during review

- **WHEN** a scheme has been selected and the app relaunches or scans again
- **THEN** the same numbered scheme SHALL remain selected
- **AND** an absent or invalid preference SHALL resolve to `1. Clean`

### Requirement: Every review candidate preserves extension identity

Every Folders candidate SHALL preserve channel ordering and at least 60% of the production palette's
source channel spread and pairwise RGB distance. `7. Tinted` SHALL reproduce the rejected installed
treatment as a comparison control, not as the implied default.

#### Scenario: Production palette colors are rendered by every candidate

- **WHEN** all 17 production colors are transformed at one container depth
- **THEN** every candidate SHALL retain at least 60% channel spread
- **AND** each candidate SHALL scale pairwise distances uniformly
- **AND** red, blue, green, and other extension identities SHALL not collapse into grey aliases

#### Scenario: A fresh comparison build is launched

- **WHEN** no stored scheme exists
- **THEN** `1. Clean` SHALL show neutral folder panels with full-strength direct-file colors
- **AND** representative descendant colors SHALL contribute zero expanded-panel tint

### Requirement: Folder roles follow the selected recipe

Folders SHALL continue to derive a representative extension from non-empty descendant content,
including directory-only chains. The selected recipe SHALL independently control direct leaves,
expanded structural panels, collapsed content-bearing folders, chrome base, and depth step. Actually
empty folders SHALL remain structural chrome.

#### Scenario: A recipe has zero panel accent

- **WHEN** a non-empty expanded folder is rendered under a zero-accent scheme
- **THEN** its panel SHALL remain the scheme's neutral chrome
- **AND** descendant representative color SHALL not create a subtree-wide veil

#### Scenario: A recipe has a nonzero panel accent

- **WHEN** a non-empty expanded folder is rendered under an accented scheme
- **THEN** its tint SHALL use the deterministic largest-content-branch representative
- **AND** the recipe's explicit bounded strength SHALL be applied

#### Scenario: A folder is collapsed by density

- **WHEN** one tile represents the folder's hidden contents
- **THEN** the tile SHALL use the selected collapsed-folder treatment
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

While native selection is open, the local website Cards demo SHALL use Scheme 1's zero direct-leaf
blend and Cushion SHALL remain raw. The website SHALL NOT be deployed as a final palette decision
until the native winner is selected and separately verified.

#### Scenario: A visitor toggles the local browser demo

- **WHEN** the local demo switches between Cushions and Cards during review
- **THEN** direct file colors SHALL remain unwashed in both styles
- **AND** Cards geometry SHALL remain the distinguishing treatment
