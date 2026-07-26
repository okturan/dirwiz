# Warm Start Observability

## Why

Warm start can silently decline and fall back to a full cold scan with no way for anyone — user or developer — to see why, before or after the fact. This isn't hypothetical: a real regression (missing `kFSEventStreamCreateFlagFileEvents` on the journal-replay stream, fixed separately) caused warm start to cold-fallback on nearly every root-volume launch, and confirming it required writing throwaway diagnostic tests against the live app, because the only trace was an `os_log(.info)` line that isn't even persisted to the system log store. A cache-load failure (corrupt file, version mismatch) is currently indistinguishable from "never scanned before" — both cold-scan with zero explanation. The one reason string that does exist today (`ScanSummaryComposer.coldWithReason`) is a single line that the next scan immediately overwrites, so a recurring pattern across launches is invisible.

## What Changes

- `TreeCache.load` failures (corrupt file, version mismatch, checksum failure, structural invalidity) surface a human-readable reason instead of collapsing to the same silent `nil` as "no cache exists yet" — reusing the existing `coldFallbackReason` plumbing that already threads through to `lastScanSummary`.
- A small, capped, on-disk history of the last ~20 warm-start decisions (warm or cold, with reason, timestamp, item/dir counts, elapsed time) persists per volume, so a *pattern* across launches ("cold-scanned 4 of the last 5 times, always citing the same reason") is visible, not just the most recent one-line summary.
- The decision log line is elevated from `.info` (not persisted by the system log store) to a level that actually shows up in `log show` after the fact.
- A quiet, discoverable UI affordance (in the spirit of the skipped-dirs-honesty popover) shows the warm-start history without requiring log access or code changes to inspect.
- Out of scope: rearchitecting the warm-start decision thresholds themselves (a separate, already-deferred proposal); CLI surface (CLI scans are cold-only per CLAUDE.md, no warm-start concept applies there).

## Capabilities

### New Capabilities
- `warm-start-diagnostics`: cache-load failure reason propagation, the capped on-disk decision history, its retention, the log-level fix, and the UI surface for inspecting it.

### Modified Capabilities
None — no baseline specs exist yet for warm start's decision flow.

## Impact

- **DirWizCore**: `TreeCache.load` (or a new sibling entry point) exposes the specific rejection reason instead of discarding it; new small history-store type (append-only, capped, JSON — not the binary tree format) alongside `TreeCache`/`TemporalSnapshot`'s existing per-volume Application Support storage pattern.
- **DirWizUI**: `AppState+Scan.swift` records a history entry at every warm/cold decision point (including the previously-silent "cache existed but failed to load" path) and elevates the log call; a new small popover/detail view surfaces the history, likely anchored near the existing scan summary/stale badge.
- **Tests**: history store round-trip + cap/retention tests (fail-closed like `TreeCache`); a regression-shaped test asserting a cache-load failure produces a non-nil reason distinct from "no cache" (this is exactly the gap that made today's real regression hard to diagnose).
