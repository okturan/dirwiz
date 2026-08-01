# Design - Skipped Directories Honesty

## Context

`FileScanner` calls `progress.incrementSkippedDirectories()` at two permission-denied sites (legacy and raw paths); `ScanProgress` keeps counters in a mutex-guarded hot struct published to the main actor in batches (`publishCounters`). The sidebar (`ContentView.scanSummary`) renders the orange line whenever `skippedDirectories > 0`, with a tooltip that unconditionally recommends enabling FDA. A separate FDA banner already handles the FDA-missing case. `hasFullDiskAccess` lives on AppState, refreshed on activation.

## Goals / Non-Goals

**Goals:**
- Paths, not just a number - capped, cheap, race-free via the existing hot-counter pattern.
- Styling that matches fixability: quiet when unfixable, actionable when fixable.

**Non-Goals:**
- Attempting to classify *why* each dir was denied beyond the FDA-state heuristic (macOS gives no reliable per-path signal).
- CLI output changes (its printed count is already proportionate; may inherit paths later).
- Retrying or elevating access.

## Decisions

1. **Recording**: `incrementSkippedDirectories(path:)` appends into a `[String]` inside the existing hot mutex struct while under the cap (100), always incrementing the exact count. `publishCounters` copies list + count out like other fields; `reset()` clears both. The rescan/splice path (`rescanSubtrees`) uses the same call, so warm starts and live applies feed the same surface.
2. **Presentation logic as a pure helper** (`SkippedDirsPresentation.style(fdaGranted:count:) -> quiet | fdaWarning | hidden`) so the styling rule is unit-testable, mirroring the `ScanSummaryComposer` pattern in the same file family.
3. **Quiet state UI**: secondary-color line with an `info.circle` glyph (no orange, no triangle), `.popover` listing paths in a scrollable monospaced list (home-abbreviated like other path displays) under a one-paragraph explanation. Wording: "macOS protects these locations even from apps with Full Disk Access. Every disk utility skips them; their contents are not included in totals."
4. **FDA-missing state**: the skip count folds into the existing `fullDiskAccessBanner` as its detail line ("Results will be incomplete - N folders couldn't be read"), keeping the single Grant action; the standalone orange line disappears entirely.
5. **Cap choice (100)**: FDA-granted skips are typically <30; FDA-missing skips can be thousands but the banner state only needs the count. 100 keeps the popover useful without unbounded memory.

## Risks / Trade-offs

- [Path list adds mutex traffic on pathological permission-denied storms] → append is cap-bounded; beyond cap only the integer increments (today's cost).
- [FDA detection heuristic wrong (hasFullDiskAccess false-positive)] → worst case is quiet styling for a fixable problem; the popover still shows the paths, and the FDA banner logic is unchanged as the primary signal.
- [Popover width/overflow with long paths] → middle truncation + copyable text, consistent with footer path rendering.

## Migration Plan

Pure addition + presentation swap; no persisted formats. Rollback = revert.

## Open Questions

None - scope is deliberately small.
