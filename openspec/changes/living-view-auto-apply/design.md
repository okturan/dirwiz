# Design — Living View Auto-Apply

## Context

`applyAccumulatedChanges()` (AppState+Analysis.swift) already: captures exploration path-keyed → `rescanSubtrees` splice → token/supersession guards → falls back to `startFullRescan()` on untrusted patches → clears `fsChanges` + rebaselines the monitor → saves `TreeCache` with the pre-splice event id → restores via `invalidateAfterTreeMutation(restoring:)`. Scans decline to start during applies and vice versa (`isApplyingChanges` / `canStartHeavyTask(.applyChanges)`). What's missing is purely *when to call it* and *how the state is presented*. Plan 037 explicitly deferred this ("decision 3a"); this design supersedes that decision.

## Goals / Non-Goals

**Goals:**
- The displayed tree converges to filesystem truth without user action, without view churn during activity storms.
- Zero new splice machinery — policy + lifecycle + presentation only.
- Preserve every existing safety guarantee (supervision invariant, mutual exclusion, fail-back to full rescan).

**Non-Goals:**
- Changing `rescanSubtrees`, `FSEventsMonitor` event collection, or warm-start behavior.
- Auto-applying during scans or making temporal snapshots automatic (separate proposal).
- CLI involvement (GUI-only feature).

## Decisions

1. **Default-on, pause as the escape hatch** (not an opt-in "live mode"). Rationale: waves 036–039 already committed the app to "the view is true" (instant restore, refresh-behind-stale-view, live tree building); a watcher that only counts is the last inconsistent piece. Pause persists via `UserDefaults` (`liveRefreshPaused`).
2. **Policy lives in a small pure type** (`LiveRefreshPolicy`, DirWizCore beside `WarmStartPlanner` for symmetry and testability): given `(pendingDirCount, now, lastEventAt, lastApplyAt, guardsActive)` returns `.apply / .wait / .storm`. Constants: quiescence 2s, min interval 10s, storm threshold 5,000 dirs (matches warm start's abandon threshold). The AppState-side coordinator is a thin timer loop consuming this.
   - *Alternative*: ad-hoc checks inline in AppState — rejected; untestable and this file is already dense.
3. **Scheduling**: monitor callback records `lastEventAt` and pending set (already does via `fsChanges`); a MainActor task (started with monitoring) ticks ~1s, consults the policy, and calls the existing `applyAccumulatedChanges()`. No new concurrency primitives; the existing token/guard structure absorbs races (a tick landing during a scan simply sees a guard and waits).
4. **Temporal-diff guard: defer, don't recompute.** Auto-applying while the diff overlay is on would repeatedly clear the diff arrays (they're index-keyed and reset by `invalidateAfterTreeMutation`). Deferring keeps the overlay stable and matches its "comparing against a fixed moment" semantics; pending changes apply when the overlay is disabled.
   - *Alternative*: recompute the diff after each apply — rejected for churn (a diff recompute per apply during activity) and semantic noise.
5. **Search re-run**: after a successful apply, post a lightweight notification (or bump an observable `treeRefreshCount`); `SearchView` re-triggers its current query — its existing generation/token structure makes this safe.
6. **Presentation**: `changeBadge` in ContentView is replaced by a pill bound to monitor + policy state: watching (● Live · relative time of last apply/scan), deferred (pending count + reason via tooltip), storm (count + "Full Rescan" button), paused (count + "Apply"). The Insights watch buttons are deleted; its FS-changes list remains as read-only history.
7. **Supervision invariant**: the coordinator never touches `scanSession`/`scanProgress` publication itself — it only ever calls the existing `applyAccumulatedChanges()`/`startFullRescan()` entry points, both already supervision-correct. A `ScanSupervisionTests` case pins that a policy tick landing mid-scan neither publishes progress nor strands state (CLAUDE.md requirement for scan-adjacent flows).

## Risks / Trade-offs

- [View changes under the user's cursor mid-interaction] → quiescence + min-interval make applies rare during active work; exploration restore keeps position; pause is one click.
- [Battery/CPU on chatty volumes] → min-interval bounds splice frequency; storm guard bounds splice size; monitoring itself is FSEvents (cheap).
- [Policy timer leaks across scans/volumes] → coordinator lifecycle tied to monitor start/stop, both keyed off scan completion/new-scan reset; test covers restart across volume switch.
- [Users relying on frozen views] → pause persists; paused behavior is exactly today's badge flow.

## Migration Plan

Single release change; the manual badge path remains as the paused state (no dead code). Reversal is trivial: default `liveRefreshPaused = true`. Update plan 037 comments and CLAUDE.md's living-view paragraph in the same PR.

## Open Questions

- Should the pill live in the sidebar footer (current badge position) or the toolbar? Default: sidebar footer, same slot as today's badge — least layout disruption.
