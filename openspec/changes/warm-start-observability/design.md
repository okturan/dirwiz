# Design — Warm Start Observability

## Context

Today's warm/cold decision flow has THREE points where a scan can go cold, and the reason is only fully threaded through at one of them:

```
restoreOnLaunch()                                                             ⓪ SILENT
  └─ no cached Payload (TreeCache.load returns nil) ──► return, empty launch state
       (runs on EVERY cold app launch — usually the FIRST and, because a
        rejection invalidates the file as a side effect, often the ONLY
        code that ever sees a corrupted cache before the evidence is gone)

startScan()
  ├─ no cached Payload  ──────────────────────────► beginColdScan(coldFallbackReason: nil)   ① SILENT
  │    (TreeCache.load returns nil for BOTH
  │     "never scanned" and "cache exists but
  │     failed to load" — indistinguishable)
  │
  ├─ WarmStartPlanner.decide → .coldFallback(reason) ► beginColdScan(coldFallbackReason: reason) ✅ WORKS
  │
  └─ WarmStartPlanner.decide → .warm(targets)
        └─ commitWarmStart() → patch abandoned
             (unresolved paths / root-level rescan) ► beginColdScan(coldFallbackReason: nil)   ② SILENT
```

> **Found during implementation, not at design time:** site ⓪ wasn't in the original
> three-site count below — it surfaced only once end-to-end testing actually drove
> `restoreOnLaunch` (not just `startScan`) against a corrupted cache. It turned out to be
> the MOST IMPORTANT site, not a minor addition: `restoreOnLaunch` is the first thing
> that runs on every cold launch, and because its cache lookup invalidates a
> structurally-corrupt file as a side effect, whichever call gets there first is usually
> the ONLY call that will ever see the real reason — every later lookup for the same path
> just sees `.noCacheFile`, indistinguishable from "never scanned." Decision 2 below
> covers the fix; this is exactly the failure mode the Risks section's closing bullet
> (unchanged from the original draft) predicted, just already present rather than added
> later.

Sites ① and ② already have the true reason available as a `log.info(...)` string right next to the call that drops it — this isn't new plumbing, it's finishing plumbing that's two-thirds built. `beginColdScan`'s `coldFallbackReason` parameter and `ScanSummaryComposer.coldWithReason` already exist and already work correctly for the middle case; sites ① and ② just don't use them. Site ⓪ has no such call to piggyback on — `restoreOnLaunch` doesn't scan at all when it bails here, so there's no `beginColdScan` to thread a reason through; it needs its own small, honest message instead (decision 2).

Separately: even the ONE working case only shows up as a single line (`lastScanSummary`) that the next scan overwrites — there's no way to see "this has happened 4 of the last 5 launches" — and the `log.info` calls at all three sites use a log level (`.info`) the system log store doesn't persist, which is exactly why confirming today's real regression required writing throwaway `swift test` diagnostics instead of `log show`.

## Goals / Non-Goals

**Goals:**
- Every cold fallback — planner-declined, cache-load-failed, or patch-abandoned — carries a real reason to the same places.
- A pattern across launches is visible, not just the latest single line.
- `log show` can retrieve past decisions without a live debug session.
- Discoverable in the UI without reading logs or writing code.

**Non-Goals:**
- Changing `WarmStartPlanner`'s thresholds/constants (deferred; a distinct proposal your earlier answer explicitly separated from this one).
- Telemetry that leaves the device, or analytics aggregation.
- CLI surface — CLI scans are cold-only, no warm-start decision exists there (CLAUDE.md).
- Rearchitecting `TreeCache`'s binary format or fail-closed discipline.

## Decisions

1. **`TreeCache` gains a richer sibling entry point, `load(for:)` stays exactly as-is.** New `TreeCache.loadResult(for:) -> LoadOutcome` (`.success(Payload)` / `.noCacheFile` / `.rejected(reason: String)`) shares ONE internal decode pass with the existing `load`; `load(for:)` becomes a thin wrapper (`if case .success(let p) = loadResult(for: path) { p } else { nil }`) so its behavior and every OTHER existing call site (e.g. `hasCachedTree`-adjacent checks) are byte-for-byte unchanged. **Correction from the original draft**: this bullet originally listed `restoreOnLaunch` among the call sites staying on plain `load` — that was wrong (see the Context section's ⓪ addendum). Both `startScan`'s cache-lookup and `restoreOnLaunch`'s switch to `loadResult`.
   - *Alternative considered*: decode twice (once via `load`, once via a new diagnostic-only re-decode on failure) — rejected: on a large cache (hundreds of MB), re-reading and re-parsing the whole file a second time just to explain a failure is wasteful for something that's supposed to be a lightweight diagnostic.
   - `.rootPathMismatch`/`.volumeMismatch` map to `.noCacheFile`, not `.rejected` — per `TreeCache`'s own doc comment these mean "may still be valid for its actual owner," not a failure of this lookup; manufacturing a "rejected" reason for a non-anomaly would be dishonest labeling.
   - The four structural `DecodeError` cases map to short human reasons in the same style as `WarmStartPlanner.userFacingPoisonReason` (e.g. `.invalidHeader` → "cache format outdated", `.checksumMismatch` → "cache file was corrupted").
2. **Fix site ⓪** (`restoreOnLaunch`'s `guard let cached = TreeCache.load(for: path) else { return }`): switch to `loadResult`; on `.rejected(reason)`, still bail out exactly as before (no auto-scan-on-launch — that's a behavior change outside this proposal's scope) but set `lastScanSummary` via a new `ScanSummaryComposer.cacheRejectedAtLaunch(reason:)` ("Previous cache unavailable: \(reason). Click Scan Volume to start fresh.") and record a `WarmStartHistory` entry (`itemCount`/`elapsedSeconds` both 0 — nothing was scanned, there's nothing else honest to put there). Deliberately NOT `coldWithReason`/`beginColdScan`'s pipeline: no scan runs here at all, so claiming "Scanned 0 items" would be dishonest.
3. **Fix site ①** (`startScan`'s `guard let cached else { ... }`): switch to `loadResult`; on `.rejected(reason)`, pass it as `coldFallbackReason`; on `.noCacheFile`, pass `nil` exactly as today (first-ever scan reads as a first scan, not a failure — pinned by its own scenario in the spec).
4. **Fix site ②** (`commitWarmStart`'s abandon-mid-patch branch): the existing `log.info` message already names the reason ("unresolved paths" vs. "would need full rescan of root") — extract that into a short string and pass it through `beginColdScan(coldFallbackReason:)`, mirroring what already happens at the planner-declined site.
5. **History store: separate, simple, low-stakes — not another `TreeCache`.** New small type (`WarmStartHistory`, alongside `TreeCache`/`TemporalSnapshot` in `Sources/DirWizCore/Diff` or `Scanner`) persists a capped array (20 entries, oldest evicted) per volume as plain JSON — not the binary fail-closed format. A malformed or missing history file just means an empty history; there's no functional cost to losing it (unlike losing a multi-hundred-MB tree cache), so the paranoid fail-closed discipline `TreeCache` needs is deliberately NOT applied here — proportionate engineering, not reused ceremony.
   - Entry: `{ date, wasWarm: Bool, reason: String?, itemCount: Int, elapsedSeconds: Double }`.
   - Written at the same point `lastScanSummary` is set: warm completion in `commitWarmStart`, cold completion in `beginColdScan`, AND (added for site ⓪) the rejection point inside `restoreOnLaunch` itself, since that path never reaches either of the other two.
6. **Log level**: `log.info(...)` → `log.notice(...)` at every reason site (⓪ through ②, all now fixed). `.notice` is the lowest Swift `Logger` level the unified log store actually persists by default (`.debug`/`.info` don't; `.notice`/`.error`/`.fault` do) — a cold fallback is noteworthy, not necessarily an error, so `.notice` fits better than escalating to `.error`.
7. **UI**: reuse the skipped-dirs-honesty popover pattern exactly — a quiet secondary-styled affordance near the existing scan summary/stale badge, opening a popover listing history entries (date, warm/cold, reason, item count, elapsed). No new visual language to design; the pattern already shipped once this week.

## Risks / Trade-offs

- [History write on every scan adds disk I/O] → tiny JSON, capped at 20 entries, written once per scan completion — negligible next to the scan itself.
- [Divergence between the reason strings' wording styles across sites] → route all of them through one small formatting helper so "cache format outdated" / "unresolved paths" / "~76% of files changed" read consistently in both `lastScanSummary` and the history popover.
- [Someone adds a fourth silent cold-fallback site later and reintroduces the gap] → **this risk was not hypothetical: it was already true of `restoreOnLaunch` at design time, just not yet discovered — found only once implementation drove the real end-to-end scenario (see the Context section's ⓪ addendum) rather than trusting the original three-site inventory.** `beginColdScan`'s `coldFallbackReason` parameter has no default in spirit even though it's optional; note this explicitly in its doc comment so future call sites don't quietly drop it. Lesson for next time: when inventorying "every place X can silently happen," grep for every caller of the SHARED primitive (here, `TreeCache.load`), not just the ones already suspected.

## Migration Plan

Pure addition; `TreeCache.load`'s public contract is unchanged. History file is new, empty until the first scan after this ships. Rollback = revert.

## Open Questions

- Per-volume history vs. one unified file across all volumes? Design above assumes per-volume (matches `TreeCache`/`TemporalSnapshot` convention); revisit only if the UI ends up wanting a single cross-volume view.
