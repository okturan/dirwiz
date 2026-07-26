# Design - Snapshot History Store

## Context

`TemporalSnapshot` persists a directory-granularity map (`relative lowercase path → total bytes`) as an uncompressed binary ("TDSN" v2, with v1/legacy-JSON decode), one file per volume keyed by root-path hash - 108 MB observed for a 358k-dir volume, overwritten on every save. `TemporalDiffService.computeDiff(tree, snapshot)` renders now-vs-snapshot onto the current tree. `StorageTrends` separately records coarse per-scan aggregates. This change turns the single slot into a history store; the timeline UI (Phase B) and A-vs-B historical diffs (Phase C) build on it later.

## Goals / Non-Goals

**Goals:**
- Many checkpoints per volume at ~10–20 MB each (compressed), listable instantly, loadable individually.
- Automatic collection with sane throttling; user pins as durable named markers.
- Bounded disk usage with predictable, honest retention.
- GUI + CLI share one store; existing diff engine untouched.

**Non-Goals:**
- Timeline scrubber UI, cards deck (Phase B).
- Diff between two historical checkpoints (Phase C).
- Keyframe+delta encoding (later optimization if budgets demand it).
- Per-file granularity (dir-granularity is what makes this feasible).

## Decisions

1. **Compressed-full checkpoints, not delta chains.** Each checkpoint is independently decodable: corruption is isolated to one file, retention is plain deletion, and the loader stays simple. Delta chains (keyframe + P-frames) would shrink storage further but couple integrity across files; deferred until real budgets demand it.
2. **Container format**: new magic + version header wrapping an LZFSE-compressed existing v2 TDSN payload. The inner decoder is reused byte-for-byte; `formatVersion`-style discipline applies to the container (any doubt → skip file). Compression via the Compression framework's buffer API (system framework; zero-external-deps rule intact).
3. **Layout**: `…/DirWiz/Snapshots/<existing volume-hash key>/` directory containing `<ISO8601>-<shortid>.tdshx` checkpoint files plus `index.json`. The index holds `[CheckpointMeta]`: id, createdAt, totalBytes, dirCount, name?, pinned, fileSize, and the change summary vs. predecessor. Index is rebuildable by scanning the directory (self-healing if missing/corrupt; summaries recompute lazily where both neighbors still exist, else marked unavailable).
4. **Summaries at creation time**: after writing checkpoint N, diff `byPath` maps of N-1 and N (one dictionary walk) → top 10 grown, top 10 shrunk, deleted count/bytes, total delta. Stored in the index (~KB). This is the only moment both maps are naturally in memory.
5. **Auto-trigger placement**: at the two scan-completion commit points in `AppState+Scan.swift` (cold completion after bundle sizing hand-off; warm completion in `commitWarmStart`) - not on every live-view auto-apply (too chatty; the living-view change can revisit with its quiescence signal in Phase B). Throttle: skip if newest checkpoint < 6h old AND |Δ totalBytes| < 1%. Constants in one place, env-overridable for tests.
6. **Pinning UX**: camera button opens a one-field name sheet; pinned checkpoints get `pinned: true` + name. The diff banner's baseline picker lists checkpoints newest-first with names, dates, and summaries; default baseline = latest.
7. **Retention algorithm**: pure function `retain(metas, now, budget) -> [ids to delete]` - tiers (keep all <24h; then newest per day ≤30d; newest per week ≤12w; newest per month ≤12m; drop older) applied to unpinned only, then budget eviction oldest-unpinned-first. Runs post-creation; unit-tested with injected dates.
8. **Migration**: store-open checks for the legacy single file at the old path; imports it (compressing into the new container, pinned "Legacy snapshot", original `createdAt` preserved from its meta) and renames the legacy file to `.imported` (kept one release as rollback insurance).
9. **CLI**: `snapshot` = create checkpoint (with optional `--name` → pinned); `snapshot list` = table from index; `diff` = latest baseline. Store honors `DIRWIZ_APP_SUPPORT_DIR`; new test suites that set it follow the `.serialized` env-var discipline (CLAUDE.md flake warning).

## Risks / Trade-offs

- [Checkpoint write cost on scan completion (~1–2s compress of 100 MB)] → runs off-main after scan-complete publication, same slot as other post-scan work; cancellation-safe (temp file + atomic rename).
- [Compression ratio worse than estimated] → budget enforcement keeps totals bounded regardless; ratio measured in tests on a synthetic large map and recorded.
- [Index/file drift (crash between file write and index write)] → order: write checkpoint file → update index; rebuildable index tolerates orphans (picked up on next open).
- [Two snapshot representations in flight during migration window] → store-open migration is atomic per volume and one-way; legacy read path retained only inside the importer.
- [Disk pressure from the store itself on small disks] → budget default 500 MB; store size surfaced in the picker footer ("History uses 312 MB").

## Migration Plan

Ships with importer (decision 8). Rollback: previous builds ignore the new directory entirely; the `.imported` legacy file can be renamed back. No other persisted formats touched (`TreeCache` unaffected).

## Open Questions

- Should the storage budget be user-visible in a settings surface now, or constant-with-env-override until Phase B's UI? Default: constant + env override; Phase B adds the visible control.
