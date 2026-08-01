# Snapshot History Store (Disk Time Machine, Phase A)

## Why

Temporal snapshots are currently a single file per volume that every camera click **overwrites** - there is no history, only one manually-replaced baseline. The living-view direction makes continuous, automatic checkpointing the natural model: snapshots become named points on a recorded timeline. This change builds the storage/collection layer (auto-checkpoints, compression, retention, pinning); the timeline scrubber UI ships as a follow-up change (Phase B) on top of it.

## What Changes

- Multi-checkpoint store per volume replacing the single-slot file: a per-volume directory of compressed checkpoint files plus a small JSON index (metadata + per-checkpoint change summaries) for listing without decompression.
- Checkpoints compress with LZFSE via Apple's Compression framework (system framework - the zero-external-dependency rule holds); the ~108 MB uncompressed dir-map becomes an estimated 10–20 MB per checkpoint.
- Auto-checkpoint on scan completion (cold and warm), throttled by a minimum interval (6h) unless total-bytes growth exceeds a threshold (1%).
- The camera action becomes "Pin this moment": creates a named checkpoint that is permanently exempt from retention.
- Time-Machine-style retention thinning for unpinned checkpoints (dailies for 30 days, weeklies for 12 weeks, monthlies for 12 months) plus a total storage budget (default 500 MB) enforced oldest-unpinned-first.
- Each checkpoint stores a KB-sized change summary vs. the previous checkpoint (total delta, top grown/shrunk directories, deletion counts) computed at creation - the future timeline's card data, useful immediately in the picker.
- The diff UI gains a "Compare to…" checkpoint picker (existing `computeDiff` already works against any loaded snapshot).
- Migration: an existing single-slot `.tdiff` is imported as the first (pinned-as-"Legacy") checkpoint on first use.
- CLI parity: `snapshot` appends a checkpoint to the store, `diff` compares against the latest by default, new `snapshot list` prints the store's checkpoints.
- Fail-closed loading throughout, same discipline as `TreeCache`: any doubt about a checkpoint file skips that checkpoint, never crashes or half-loads.

## Capabilities

### New Capabilities
- `snapshot-history`: checkpoint accumulation, compression/format versioning, auto-checkpoint triggers, pinning, retention/budget, per-checkpoint summaries, compare-to-any-point, migration, and CLI store operations.

### Modified Capabilities
None - no baseline specs exist yet.

## Impact

- **DirWizCore/Diff**: new store module (container format wrapping the existing v2 binary payload, LZFSE, index management, retention engine, summaries); `TemporalSnapshot` load/save routed through the store; `TemporalDiffService` unchanged.
- **DirWizUI**: snapshot toolbar action becomes pin-with-name (sheet); diff banner gains the checkpoint picker; `TemporalDiffState` tracks the selected checkpoint.
- **CLI**: `snapshot`/`diff` subcommands updated; new `snapshot list`; shared store honors `DIRWIZ_APP_SUPPORT_DIR` (tests).
- **Tests**: store round-trip/corruption/fail-closed, retention with injected dates, migration, summary computation, CLI behaviors. `TemporalDiffTests`' serialized env-var discipline applies to new suites touching `DIRWIZ_APP_SUPPORT_DIR`.
