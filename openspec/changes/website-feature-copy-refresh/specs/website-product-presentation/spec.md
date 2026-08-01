## ADDED Requirements

### Requirement: The hero explains the user outcome first

The homepage hero SHALL explain that DirWiz maps disk usage so a person can find large content,
compare change, and remove unwanted files safely. It SHALL NOT lead with allocated-block or rectangle
sizing mechanics.

#### Scenario: A visitor reads only the hero

- **WHEN** a visitor reads the headline and first paragraph
- **THEN** they SHALL understand what problem DirWiz solves and what they can do next
- **AND** they SHALL NOT need to understand logical versus allocated size

### Requirement: The feature inventory reflects the current product

The homepage SHALL present the major current user-facing capabilities, including fast scan and
search, selectable treemap styles, warm start, living-view updates, verified duplicates, hardlink
handling, snapshot timeline, insights, native Mac controls, and the shared CLI, without presenting
internal mechanisms as separate features.

#### Scenario: A shipped capability is added to the feature grid

- **WHEN** a capability materially changes what a user can do or how often the app stays useful
- **THEN** the feature inventory SHALL be checked for an existing accurate mention
- **AND** missing high-value capabilities SHALL be added or folded into the closest card

### Requirement: Native Mac controls are described accurately

Public copy SHALL distinguish the macOS menu bar from the app window toolbar. It SHALL name only
commands and shortcuts verified in the release source or artifact.

#### Scenario: The site describes navigation and toolbar actions

- **WHEN** the copy mentions Find or Go navigation
- **THEN** it SHALL identify them as macOS menu-bar commands
- **AND WHEN** it mentions recency, snapshots, temporal diff, export, or legend visibility
- **THEN** it SHALL identify them as window-toolbar controls

### Requirement: Website claims match the downloadable release

Every present-tense feature claim on the public page SHALL be available in the release reached by
the page's primary download link. Source-only or incomplete changes MUST NOT be described as shipped.

#### Scenario: Source is ahead of the latest release

- **WHEN** a website edit describes a feature present at repository HEAD but absent from the latest
  downloadable app
- **THEN** publication SHALL wait for the corresponding release or omit that claim

### Requirement: Technical proof remains available below the hero

The page SHALL retain concrete scan measurements, allocated-block semantics, native dependency
claims, and Trash-only safety details in supporting sections.

#### Scenario: A technical reader checks accuracy

- **WHEN** a visitor continues beyond the hero
- **THEN** they SHALL find concrete performance, storage-accounting, architecture, and safety proof
  without those details overwhelming the opening message
