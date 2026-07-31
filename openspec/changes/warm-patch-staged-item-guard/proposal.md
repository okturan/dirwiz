## Why

Master has been red for two commits and GitHub CI fails on `9431689` and `162e7f5` while `bb583c0` and everything before it pass. `retire-root-count-cap` correctly added a post-Phase-A staged-item guard (its task 2.3 asked for exactly this), but the guard abandons a warm patch *after* its staging work has already completed, using a budget derived from the cached tree, which by definition cannot represent content created since the cache was written. On the reference warm-patch fixture, ~4,000 newly created files against a ~4,340-item cached tree exceed the 1,085-item budget, so a patch that is warm-eligible and fast is abandoned into a full cold scan. Abandoning after the work is done is strictly more expensive than finishing it.

## What Changes

- The mid-patch staged-item guard SHALL judge projected remaining work rather than work already completed, so a patch is never abandoned once finishing is cheaper than falling back.
- Distinguish the two budgets that are currently one number: the up-front gate estimates from the cached tree and is a prediction, while the mid-patch guard counts real staged items and is a measurement. They answer different questions and should not share a threshold by accident.
- Restore CI to green, with the `ScanSupervisionTests` warm-patch guard assertion passing for the right reason rather than by weakening it.
- Decide explicitly whether the reference fixture documented in CLAUDE.md remains valid, since it depends on the cached-tree estimate undershooting.
- Unchanged: the up-front item-fraction gate, `maxChangedItemFraction` at 0.25, the 512-root backstop, and the gate ordering established by `retire-root-count-cap`.

## Capabilities

### New Capabilities
- `warm-patch-staged-item-guard`: how a warm patch that exceeds its predicted size is handled once staging is already underway, and when abandoning is preferable to finishing.

### Modified Capabilities
<!-- None: warm-patch-gating covers the up-front decision, which this change does not alter. -->

## Impact

- Affected code: `Sources/DirWizUI/Models/AppState+Scan.swift` (the guard and its cumulative accounting), `Sources/DirWizCore/Scanner/FileScanner.swift` (`SubtreeRescanOptions.maximumStagedItemCount`), `Sources/DirWizCore/Scanner/WarmStart.swift` (`maximumStagedItemCount`).
- Affected tests: `ScanSupervisionTests.swift` (the failing warm-patch guard at line 446), and any fixture relying on a cached-tree estimate that undershoots.
- **The failing assertion must not be relaxed.** It exists to confirm the test exercises a warm patch rather than passing for the wrong reason on a cold fallback. Changing it to accept a cold fallback would delete the guarantee it protects.
- Risk: loosening the guard too far reintroduces the failure mode `retire-root-count-cap` added it to prevent, where a subtree that grew since the cache carries an oversized patch past the up-front gate unnoticed. The protective case must keep a deterministic test.
- No persisted-format change and no cache `formatVersion` bump.
