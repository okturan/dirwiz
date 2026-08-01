## Context

The landing page already has strong technical proof lower down: real scan time, allocated-block
semantics, screenshots, safety details, and CLI examples. Repeating storage semantics in the hero
wastes the sentence that should explain what the app does for a person. Meanwhile, the code now has
two distinct native control surfaces that the site does not explain:

- the macOS menu bar: Find and Go commands for Back, Forward, Enclosing Folder, and Root;
- the window toolbar: recency heatmap, snapshot pinning, temporal diff, CSV/JSON export, and legend
  visibility.

The site also omits living-view auto-apply and describes snapshots as one baseline rather than a
compressed checkpoint timeline.

## Goals / Non-Goals

**Goals:**

- Make the hero immediate, plain, and outcome-led.
- Bring the feature grid up to date without turning it into a changelog.
- Describe menu-bar and toolbar controls with correct macOS terms.
- Keep public claims tied to the downloadable release.
- Preserve the existing visual system and live demo.

**Non-Goals:**

- Redesign the page or add a separate documentation site.
- List every context-menu action, keyboard shortcut, or implementation detail.
- Advertise incomplete OpenSpec changes or unpublished builds.
- Change download URLs, checksums, or release metadata in this copy-only change.

## Decisions

### 1. The hero sells the outcome; allocated blocks remain proof

Use this hero paragraph:

> DirWiz scans millions of files in seconds and turns your disk into a map you can explore. Find the
> space hogs, compare what changed, and move what you no longer need to the Trash.

The technical allocated-block claim remains in the screenshot caption and stats strip, where a
reader looking for accuracy can verify it without parsing scanner semantics in the hero.

### 2. Expand the feature grid from seven to nine cards

Add `Living view` and `Mac-native controls`, producing a balanced three-by-three desktop grid.
Update `Snapshots & diffs` to `Snapshot timeline`. Keep warm start, duplicates, search, CLI, and
insights because they remain distinct user-facing reasons to choose the app.

### 3. Name the two Mac control surfaces correctly

Do not call the window toolbar a menu bar. The feature copy states that the macOS menu bar contains
Find and Go navigation, while the window toolbar contains recency, snapshot, diff, export, and
legend actions. Mention representative shortcuts only when verified in source.

### 4. Public copy follows the public artifact

Source code can be ahead of the release linked on the page. Before deployment, verify the downloaded
latest app contains every newly advertised feature. If a source-only feature is relevant, hold that
sentence for the release rather than weakening the truth gate. This refresh does not advertise the
unreleased state-driven scan control or the in-flight Folders palette change as shipped in 1.2.1.

## Risks / Trade-offs

- Nine feature cards are more copy. Keep each paragraph short and concrete; deeper mechanics remain
  in the existing sections below.
- “Mac-native controls” can become generic marketing. Naming the actual commands prevents that.
- The release can move after the spec is written. The implementation task rechecks the downloaded
  artifact immediately before publication.

## Open Questions

None. The source inventory establishes which controls exist and where they live.
