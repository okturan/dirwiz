# Design — Instant Duplicates

## Context

`DuplicateFinder` (Sources/DirWizCore/Scanner/DuplicateFinder.swift) is a proven 4-pass pipeline: size grouping → partial hash (4KB head/tail; small files fully digested inline) → full 128-bit streaming hash → hardlink dedup + `DuplicateContentVerifier` byte comparison. Everything after pass 1 is I/O. Meanwhile the tree snapshot already carries `fileSize`, name bytes (string pool), a lazily built lowercase name pool (search index), `isCaseSensitive`, and `(device, inode)` per node. The instant mode is pass 1 plus a name dimension, promoted to a first-class user-facing result.

## Goals / Non-Goals

**Goals:**
- Sub-second candidate groups on multi-million-file trees, zero content I/O.
- Verification path that reuses (not re-implements) the existing hash/byte-verify machinery, scoped to one group.
- Absolute safety: unverified groups can never reach `TreeActions`.

**Non-Goals:**
- Persistent hash cache across runs (separate proposal P7).
- APFS clone detection (no supported API; documented limitation).
- Replacing the exhaustive content scan.

## Decisions

1. **Group key = (fileSize, folded-name hash) with a two-pass build.** Pass A counts sizes into `[UInt64: UInt32]`; only files whose size bucket has ≥2 members enter pass B, which groups by `(size, nameKey)`. This keeps the second dictionary small (size-unique files — the vast majority — never touch it). Name key: FNV-1a over the lowercase pool slice when the volume is case-insensitive, over the raw string-pool slice otherwise; verify actual name-byte equality within a bucket to guard against hash collisions before surfacing a group.
   - *Alternative considered*: single-pass `(size, name)` dictionary — simpler but allocates entries for every file; rejected for memory churn at 2.5M files.
2. **Walk via `forEachFileInSnapshot`** (CLAUDE.md: the single blessed whole-tree walk with uniform cancellation cadence). No hand-rolled loop.
3. **Results store paths, not indices** — mirrors `DuplicateGroup.paths`. `removeSubtree` renumbers indices; path-keyed results survive, and `invalidateAfterTreeMutation` triggers a cheap recompute (the analyzer is fast enough to just re-run).
4. **Scoped verification = refactored `DuplicateFinder` entry point.** Extract a `verify(candidates: [[UInt32]], …)` path that runs passes 2–4 on supplied index groups instead of the whole tree, returning `DuplicateGroup`s. The full scan becomes "size-group the tree, then call the same entry point" — one engine, two front doors. Equivalence pinned by tests.
5. **Hardlink collapsing inside the instant finder** reuses the `(device, inode)` fields already on `FileNode` — same `DevIno` approach as `DuplicateFinder`'s finalize pass, no `lstat` fallback needed for scanned trees.
6. **UI model**: `DuplicateState` gains `instantGroups`, `instantToken`, and per-group verification status (`unverified / verifying / confirmed(subgroups) / rejected`). Auto-run on tab open and on scan completion; guarded by the token-counter pattern (stale task can't clobber newer results). Min-size shares the existing `lastDuplicateScanMinimumSize` control.
7. **Trash gating is structural, not cosmetic**: only `DuplicateGroup` values produced by the verification path are handed to the existing cleanup UI. Instant candidates use a distinct type that has no path into `TreeActions`.

## Risks / Trade-offs

- [Heuristic false positives mislead users] → explicit labeling + verification gate; no destructive affordance pre-verification.
- [Dictionary memory on pathological trees (millions of same-size files)] → two-pass build plus min-size filter; candidates cap with "showing top N groups by potential waste" if needed.
- [Verification results diverge from full scan] → equivalence test: for a fixture tree, full scan groups ≡ union of scoped verifications over instant candidates that are true duplicates.
- [Lowercase pool not built yet when tab opens] → `searchIndexSnapshot()` builds lazily; the analyzer triggers the same build path (one-time cost, already paid if search was used).

## Migration Plan

Pure addition; no persisted formats change. Ship dark behind the tab (auto-run replaces the empty state; the "Find Duplicates" button remains as the exhaustive mode). Rollback = revert.

## Open Questions

- Should verify-all be offered (runs scoped verification across all candidates, effectively a prioritized content scan)? Default: yes, as a secondary button — it subsumes most uses of the old full scan for interactive sessions.
