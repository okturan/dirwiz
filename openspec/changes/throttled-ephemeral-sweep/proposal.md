## Why

The previous change (`deferred-ephemeral-roots`, 5a35a12) moved the per-user Darwin temp root off the warm patch's critical path but did not reduce the work: interactive patch time fell from 2.03 s to 0.635 s, while combined throughput across both tiers fell from ~177,000 items/sec to 79,000-119,000 and total wall clock roughly doubled. Nothing throttles the trailing tier, so it sweeps on every patch while that root changes every ~10 seconds, meaning ~157,665 temp files are still re-enumerated continuously.

## What Changes

- Sweep the ephemeral tier on a throttled cadence rather than once per warm patch, decided by a pure clock-injected `EphemeralSweepPolicy` in DirWizCore.
- Derive the interval and a maximum cache-horizon holdback from a measured journal-replay cost curve rather than choosing them.
- Force a sweep when the held-back horizon ages past its bound, regardless of interval, so throttling cannot turn a warm start into a cold scan.
- Sweep on navigation into a stale ephemeral subtree, which is the one moment its freshness has value.
- Represent ephemeral staleness in the UI using the existing `staleViewAsOf` and skipped-directory vocabulary.
- **BREAKING** (spec-level, not API): `patched-tree ≡ fresh-cold-scan` holds only after a throttled sweep, not after the trailing pass. This deliberately weakens a guarantee CLAUDE.md protects.
- Unchanged: cold-scan totals, the interactive tier, `EphemeralPaths` classification, and the `DIRWIZ_NO_EPHEMERAL_DEFER` kill switch.

## Capabilities

### New Capabilities
- `ephemeral-sweep-scheduling`: when the deferred ephemeral tier is swept, the horizon bound that overrides the throttle, and on-demand sweeps triggered by navigation.

### Modified Capabilities
- `warm-patch-tiering`: the equivalence guarantee moves from "once the trailing pass completes" to "once the throttled sweep runs", and staleness between sweeps becomes a stated, represented condition rather than a transient one.

## Impact

- Affected code: `Sources/DirWizCore/Scanner/` (new `EphemeralSweepPolicy`, `WarmPatchCacheHorizon`), `Sources/DirWizUI/Models/AppState+Scan.swift` (trailing-tier scheduling), `AppState+Analysis.swift` (the always-on live patch must retain ephemeral targets instead of continuing to enumerate them every ~10 seconds), and `AppState+Navigation.swift` (on-demand sweep).
- Affected tests: the `patched-tree ≡ fresh-cold-scan` equivalence tests must force a sweep and then assert, rather than being loosened or deleted.
- Primary risk is inverted from the previous change: throttling widens the window over which the persisted `TreeCache` event id is held back, lengthening the next warm start's journal replay. A long enough interval can poison that replay and force the 26 s cold scan this entire line of work exists to avoid.
- No persisted-format change, so no cache `formatVersion` bump.
