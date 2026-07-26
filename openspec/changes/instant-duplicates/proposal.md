# Instant Duplicates (name + size) with Verify-to-Act

## Why

The content-hash duplicate scan is I/O-bound (minutes on large volumes) and hides behind a button press, while the scanned tree already holds size and name for every file - enough to surface likely duplicates in well under a second with zero filesystem reads. A two-tier flow (instant heuristic preview, content verification to unlock actions) makes the Duplicates tab useful the moment a scan finishes.

## What Changes

- New DirWizCore analyzer that groups files by `(fileSize, case-folded name)` over a tree snapshot - pure in-memory, no file-content I/O.
- The Duplicates tab auto-runs this instant grouping when opened after a completed scan; no button press required.
- Instant groups are explicitly labeled as heuristic ("same name & size - not content-verified") and expose **no trash actions**.
- Per-group (and verify-all) "Verify" runs the existing partial-hash → full-hash → byte-compare pipeline scoped to just that group's files; only byte-identical files graduate to actionable, confirmed groups.
- Entries sharing `(device, inode)` (hardlinks) are collapsed to one representative inside instant groups, reusing scan-time identity metadata - zero I/O.
- The existing full-volume content scan remains available unchanged as the exhaustive mode.
- Out of scope (follow-up proposals): persistent hash cache (P7), APFS clone detection.

## Capabilities

### New Capabilities
- `instant-duplicate-groups`: zero-I/O heuristic duplicate grouping by size + case-folded name, its labeling/gating rules, per-group content verification, and hardlink collapsing.

### Modified Capabilities
None - this repo has no baseline specs yet; all behavior here is specified as new.

## Impact

- **DirWizCore**: new `InstantDuplicateFinder` (walks snapshots via the blessed `forEachFileInSnapshot` pattern; reuses the lowercase name pool and `isCaseSensitive`); a scoped-verification entry point refactored out of `DuplicateFinder` passes 2–4; `DuplicateContentVerifier` reused as the final gate.
- **DirWizUI**: `DuplicateState` gains instant-mode state + token; `DuplicateFilesView` gains the unverified/verified two-section layout, verify buttons, and auto-run-on-open; `invalidateAfterTreeMutation` must clear/recompute instant groups (results are path-keyed so they survive index renumbering).
- **Tests**: new suite for the instant finder (case sensitivity, hardlinks, min-size), equivalence tests pinning scoped verification ≡ `DuplicateFinder` for the same inputs.
