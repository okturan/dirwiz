## Why

CI is red on master. `"A newer cold scan detaches a trailing tier that already committed before its token check"` fails the tree-equivalence gate: the resulting tree holds 125 paths where a fresh cold scan of the same on-disk fixture finds 127. The two missing entries are `interactive/new.txt` and `ephemeral/new.txt` - one newly created file from each warm-patch tier, both present on disk and both absent from the tree DirWiz would show.

That is under-reporting, which is the exact failure class the `patched-tree ≡ fresh-cold-scan` gate exists to catch, and CLAUDE.md is explicit that the gate must survive any change in this area. A tree missing files reports sizes that are too small, silently.

This is NOT the `ScanSupervisionTests` flake. That had three causes, was diagnosed from captured state, and was fixed in `8eac839` with every assertion preserved. This is a different test, a different subsystem, and a different failure mode, surfaced once that noise was removed.

## What Changes

- Determine whether the missing files are a real defect in the supersession path or an artefact of the test's own timing. That question is the change; everything else follows.
- If real: fix the path where a newer cold scan detaches a trailing tier that has already committed, so no newly created file is lost.
- Reproduce it deterministically rather than by pushing to CI, since it currently appears only on GitHub's runner.
- Leave the equivalence assertion exactly as strong as it is.

## Capabilities

### New Capabilities
- `warm-patch-supersession`: what the tree must contain when a newer cold scan supersedes a warm patch whose tiers have partly or wholly committed.

### Modified Capabilities
<!-- None: no existing baseline spec covers supersession-time tree contents. -->

## Impact

- Affected code: `Sources/DirWizUI/Models/AppState+Scan.swift` (two-tier patch, token checks, `warmPatchMutatesDisplayedTree` detach), `Sources/DirWizUI/Models/AppState.swift`, and possibly `FileScanner.rescanSubtrees`.
- Affected tests: `Tests/DeferredEphemeralWarmStartTests.swift`. `assertTreesEquivalent` in `TestHelpers.swift` is NOT to be changed; it was verified untouched by `8eac839`, so the discrepancy is real rather than a moved goalpost.
- **Blocks the 1.2.0 release.** The current release is v1.1.1 from 19 July with the repo 67 commits ahead, and this is warm-patch correctness rather than test plumbing.
- Blocks `scan-supervision-flake` task 4.3, which requires five consecutive green CI pushes and cannot pass while this fails.
- Reproduction risk: it passes 6 of 6 locally in isolation and stayed green across 14 local full-suite runs at loads 8.2-12.1, so the local machine does not currently reproduce it at all. A deterministic reproduction is the first requirement, not an optimisation.
- No persisted-format change and no cache `formatVersion` bump.
