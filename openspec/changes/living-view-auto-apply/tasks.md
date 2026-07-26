# Tasks — Living View Auto-Apply

## 1. Policy core

- [x] 1.1 Add `LiveRefreshPolicy` (DirWizCore, beside `WarmStartPlanner`): pure decision function over (pending count, timestamps, guard flags) → apply/wait/storm, with the 2s/10s/5,000 constants
- [x] 1.2 Unit tests with injected clocks: quiescence not yet reached, min-interval enforcement, storm threshold crossing and recovery, guard-active deferral

## 2. Lifecycle and coordinator (DirWizUI)

- [x] 2.1 Auto-start monitoring on scan completion (cold, warm, and post-restore refresh paths); stop on new scan start and volume change; replace `toggleFSMonitoring` with pause semantics + persisted `liveRefreshPaused` preference
- [x] 2.2 Add the MainActor tick loop consuming `LiveRefreshPolicy` and invoking the existing `applyAccumulatedChanges()`; storm state routes to a Full Rescan suggestion instead
- [x] 2.3 Temporal-diff guard: policy sees the overlay-enabled flag; pending changes apply after the overlay is disabled
- [x] 2.4 Post-apply search re-run hook (observable refresh count; `SearchView` re-triggers current query through its existing generation guards)

## 3. Presentation

- [x] 3.1 Replace `changeBadge` with the Live pill (watching / deferred / storm / paused states, relative last-updated time, pause toggle, manual Apply when paused)
- [x] 3.2 Remove Watch Changes / Stop Watching from `InsightsView`; keep the changes list as read-only history
- [x] 3.3 Wording + tooltips pass (pill states must be self-explanatory)

## 4. Safety and docs

- [x] 4.1 `ScanSupervisionTests` case: a policy tick during an active scan performs no apply and publishes no scan state; supervision invariant holds across auto-apply flows
- [x] 4.2 Guard-interaction tests: apply defers during duplicate scan/bundle sizing; applies afterward; pause blocks applies entirely
- [x] 4.3 Cache continuity test: auto-apply persists tree + pre-splice event id (extend existing apply tests)
- [x] 4.4 Update plan 037 decision-3a doc comments and CLAUDE.md living-view paragraph; full suite green

## Implementation notes (as built)

- This formally reverses plan 037's "decision 3a: no auto-apply, ever". That decision was
  right when the splice engine was young; it is now the same path warm start takes on every
  launch, with path-keyed exploration restore and an idempotent splice.
- `LiveRefreshPolicy` is pure and clock-injected, mirroring `WarmStartPlanner`'s shape, so
  every branch (quiescence boundary, interval floor, storm crossing, each guard) is tested
  without waiting real seconds.
- **Guards outrank the storm signal, deliberately.** Suggesting a full rescan *during* a
  scan is nonsense, and mid-scan the pending set is about to be discarded wholesale.
- **Deferral never latches.** Each tick re-decides from current state, so whatever was
  pending applies as soon as the guard lifts — pinned by tests for the overlay and the
  heavy-task slot.
- The storm threshold is deliberately the same 5,000 as warm start's
  `unknownDirectoryCountBackstop`, with a test asserting they match: two different answers
  to "too many changed directories to splice" would be a bug waiting to happen.
- Pausing keeps WATCHING — it suppresses the automatic splice only, so the pending count
  still accumulates and manual Apply still works. Pausing is persisted; silently resuming
  next launch would be exactly the surprise pausing exists to prevent.
- Every pill state names its reason. A view that quietly stops updating is worse than one
  that never updated, because the user cannot tell the difference.
- `SearchView` re-runs its query on `liveRefreshGeneration`: an apply renumbers node
  indices, so cached result indices would otherwise describe a tree that no longer exists.
- Two self-inflicted bugs worth recording. A `ScrollView`-in-`ScrollView` (from the earlier
  duplicates work) and, here, a search-and-replace that rewrote `AppState()` *inside* the
  `stateWithTree()` helper itself, making it infinitely recursive — signal 11 on every test
  in the suite, with no message. When a whole suite dies at once, suspect the shared helper.

## Cache continuity (4.3, added after the first pass)

- `AppliedChangesTests.applyPersistsCacheForWarmStart` now asserts the whole chain: after an
  apply, `TreeCache.load` returns the SPLICED tree (the newly added file is present) and an
  event id that is `>=` the pre-splice id and `<=` now. A future id would make the next
  warm start replay nothing; an id captured after the splice would skip anything that
  landed during it.
