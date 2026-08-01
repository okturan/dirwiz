# Living View: Always-On Watch + Debounced Auto-Apply

## Why

The FSEvents watcher currently requires opting in from the Insights tab and its only output is a "N folders changed · Refresh" badge the user must click - a watcher that watches but doesn't act. Every safety rail auto-apply needs already exists and is proven in the manual path (`applyAccumulatedChanges`: path-keyed exploration restore, idempotent splice engine, cache write-back, mutual exclusion with scans). This change formally reverses plan 037's "decision 3a" (no auto-apply, ever) now that the machinery has matured: the displayed tree should simply stay true.

## What Changes

- FSEvents monitoring auto-starts after every completed scan (cold or warm); the Insights "Watch Changes"/"Stop Watching" buttons are removed.
- Accumulated changes auto-apply after a quiescence window (~2s of FSEvents silence) with a minimum interval between applies (~10s), preserving selection, expansion, and treemap root via the existing `ExplorationCapture` restore.
- Storm guard: when the pending changed-directory set exceeds the warm-start-style threshold (5,000 dirs), auto-apply stops and the UI suggests a Full Rescan instead of grinding splices.
- Politeness guards: applies defer while any heavy task runs (existing `canStartHeavyTask` gate) and while the temporal-diff overlay is enabled; an active search re-runs automatically after an apply.
- The sidebar badge becomes a status pill: "● Live · updated Xs ago", clickable to pause. Paused (or guard-deferred) state shows today's pending count + manual Apply. Pause preference persists across launches.
- Each auto-apply writes back `TreeCache` with the pre-splice event id (already implemented in the manual path) so the next launch's warm start continues from current state.
- Plan 037's decision-3a doc comments are updated to record the reversal and its rationale.

## Capabilities

### New Capabilities
- `live-tree-refresh`: automatic monitoring lifecycle, quiescence/storm/politeness policies for applying filesystem changes to the displayed tree, the Live pill status UI, and cache continuity.

### Modified Capabilities
None - no baseline specs exist yet.

## Impact

- **DirWizUI**: `AppState+Analysis.swift` (monitor lifecycle, new auto-apply coordinator, `toggleFSMonitoring` replaced by pause semantics), `AppState+Scan.swift` (start monitoring on scan completion paths), `ContentView.swift` (Live pill replaces `changeBadge`), `InsightsView.swift` (watch buttons removed; changes list remains as informational history).
- **DirWizCore**: none required (splice engine, journal, monitor are reused as-is); policy thresholds may live beside `WarmStartPlanner` for symmetry.
- **Tests**: policy unit tests (quiescence/min-interval/storm decisions with injected clock), a `ScanSupervisionTests` case for the new scan-adjacent flow (CLAUDE.md requires the pairing invariant for anything touching scan state), guard-interaction tests.
