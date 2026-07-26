# Tasks — Warm Start Observability

## 1. Cache-load failure reasons (DirWizCore)

- [x] 1.1 Add `TreeCache.LoadOutcome` (`.success(Payload)` / `.noCacheFile` / `.rejected(reason: String)`) and `TreeCache.loadResult(for:)`, sharing one internal decode pass; reduce existing `load(for:)` to a thin wrapper over it (behavior unchanged for all existing callers)
- [x] 1.2 Map the four structural `DecodeError` cases to short human reasons (style-matched to `WarmStartPlanner.userFacingPoisonReason`); map `.rootPathMismatch`/`.volumeMismatch` to `.noCacheFile`
- [x] 1.3 Tests: `.success` on a valid cache, `.noCacheFile` on a missing file AND on a path/volume mismatch, `.rejected` with the right reason for each structural corruption case (truncated, checksum mismatch, version mismatch, structural-invalid) — extend `TreeCacheTests.swift`'s existing corruption fixtures rather than duplicating them

## 2. Thread reasons through the two silent sites (DirWizUI)

- [x] 2.1 `startScan`'s no-cache branch: switch to `loadResult`; pass `.rejected`'s reason as `coldFallbackReason`; `.noCacheFile` passes `nil` exactly as today
- [x] 2.2 `commitWarmStart`'s abandon-mid-patch branch: extract the existing `log.info` message's reason into a short string; pass it via `beginColdScan(coldFallbackReason:)`
- [x] 2.3 Route all three reason sites (planner-declined, cache-load-failed, patch-abandoned) through one small formatting helper so wording stays consistent across `lastScanSummary` and the new history entries
- [x] 2.4 Tests: a cache-load failure and a mid-patch abandonment each produce a distinct, non-nil reason reaching `lastScanSummary` — regression-shaped, pinning exactly the gap that made today's real bug hard to diagnose
- [x] 2.5 **(discovered during implementation, not in the original design)** `restoreOnLaunch` ALSO calls into the cache lookup, via plain `load(for:)` — and since it runs on every cold launch, it's usually the FIRST and (because a rejection invalidates the file as a side effect) often the ONLY code that ever sees a corrupted cache before the evidence is gone. Fixed: switched to `loadResult`; on `.rejected`, surfaces the reason via a new `ScanSummaryComposer.cacheRejectedAtLaunch` message and a `WarmStartHistory` entry, without changing the existing no-auto-scan-on-launch behavior. New end-to-end test in `LaunchRestoreTests.swift` (driving `restoreOnLaunch` directly, not `startSelectedVolumeScan`) — the original 2.4 test alone would have passed even with this gap present, since it bypassed `restoreOnLaunch` entirely.

## 3. Decision history store (DirWizCore)

- [x] 3.1 `WarmStartHistory` type: capped (20 entries, oldest evicted), per-volume, plain JSON — explicitly NOT the fail-closed binary discipline `TreeCache` uses; a malformed/missing file just means empty history, no cold-scan consequence
- [x] 3.2 Append entry (`date`, `wasWarm`, `reason?`, `itemCount`, `elapsedSeconds`) at the same points `lastScanSummary` is set today (cold completion in `beginColdScan`, warm completion in `commitWarmStart`)
- [x] 3.3 Tests: round-trip, cap/eviction (oldest-first), malformed-file-degrades-to-empty (not a crash), per-volume isolation

## 4. Log level (DirWizUI)

- [x] 4.1 `log.info` → `log.notice` at all reason sites (including `restoreOnLaunch`'s, added in 2.5)
- [x] 4.2 Manual verification: confirmed via a real built app + `/usr/bin/log show` that a `.notice`-level `com.dirwiz` log entry persists and is retrievable after the process exits. Important correction to the ORIGINAL investigation: `log`/`log show` invoked bare in this shell resolves to a **zsh shell builtin**, not `/usr/bin/log` — it silently no-ops (confirmed: it returns nothing for `--last 1m` with no predicate at all, i.e. for literally any subsystem, Apple's included). The earlier "`.info` doesn't persist" diagnosis was directionally right (`.info`/`.debug` genuinely don't persist per Apple's docs) but the EMPIRICAL "zero results" evidence gathered for it was an artifact of this shadowing, not proof on its own. Always invoke `/usr/bin/log show`/`/usr/bin/log stream` explicitly in this environment.

## 5. UI surface (DirWizUI)

- [x] 5.1 Quiet affordance near the scan summary/stale badge (reusing the skipped-dirs-honesty popover pattern: secondary styling, no alarm color) opening a popover listing history entries
- [x] 5.2 Empty state (no history yet) and entries render with consistent reason wording (per 2.3's shared formatter)

## 6. Verification

- [x] 6.1 Full suite green
- [x] 6.2 CLAUDE.md warm-start paragraph updated: note the three reason sites now all thread through, and the history store's existence
