# Design — Always-On Hardlinks

## Context

`kRequestedFileAttrs` currently asks for `ATTR_FILE_DATALENGTH | ATTR_FILE_ALLOCSIZE`; the raw parser walks the packed reply buffer in attribute-bit order. `FileNode.flags` is a UInt8 with two bits used (`isDirectory`, `isBundle`). `HardlinkFinder` builds a `[DevIno: members]` dictionary over every file node. `TreeCache` has an explicit rule: any change to `FileNode`'s stored layout MUST bump `formatVersion` (fail-closed load).

## Goals / Non-Goals

**Goals:**
- Link-count knowledge at scan time with zero added syscalls and no measurable scan-rate cost.
- Hardlinks as an always-current, button-free fact.
- Equivalence with today's results, pinned by tests.

**Non-Goals:**
- Storing the full link count (the boolean bit is sufficient for grouping; count is derivable from group size).
- Changing hardlink presentation/semantics (extraLinkBytes stays "not reclaimable space").
- CLI behavior changes beyond inheriting the faster finder.

## Decisions

1. **Attr request + parse order**: add `ATTR_FILE_LINKCOUNT` to `kRequestedFileAttrs`. In the packed reply, file attributes appear in bit order — `ATTR_FILE_LINKCOUNT` (bit 0) precedes `ATTR_FILE_TOTALSIZE`/`ALLOCSIZE`/`DATALENGTH` — so the parser reads the UInt32 link count *before* the size fields. Both the returned-attrs bitmap check and the advance logic must handle its absence (`FSOPT_PACK_INVAL_ATTRS` semantics), defaulting to flag-unset. Mock provider grows the field for parse tests.
2. **Flag bit**: `NodeFlags.hasMultipleHardlinks = 4` (bit 2). Set only for non-directories with linkCount > 1, in the shared raw-entry classification (`processRawEntry`), so both immediate and deferred materialization and warm-start splices inherit it from one code path.
3. **Cache bump**: `formatVersion` increment in the same commit that changes the stored layout — even though `flags` is an existing byte, its *meaning* changes and old caches must not present stale flag semantics. One cold scan per user post-update; warm start resumes after.
4. **Finder fast path**: `HardlinkFinder` first checks whether any node carries the flag (O(n) scan of the flags byte, trivially fast). If the tree has identity metadata: group only flagged nodes (typically thousands, not millions). Fallback (no identity metadata → synthetic trees) keeps today's full grouping + lstat path. Equivalence test runs both on the same scanned fixture.
5. **Auto-population**: `AppState` runs the finder after scan completion (post bundle-sizing hand-off, alongside other post-scan analyses) and from `invalidateAfterTreeMutation` (cheap enough to just recompute). `HardlinkState` results remain path-based (`HardlinkGroup.paths`), surviving index renumbering. Token-guarded as with other analyses.
6. **UI**: `HardlinkView` drops the run button; shows results, an explicit empty state ("No hardlinked files on this volume"), or a brief computing state.

## Risks / Trade-offs

- [Parser regression corrupting size fields (order bug)] → mock-provider tests assert exact field extraction with and without the link-count attr present; real-fs fixture with `link(2)` verifies end-to-end.
- [Filesystems not returning ATTR_FILE_LINKCOUNT (SMB, exotic FS)] → absence → flag unset → finder sees no flags → returns empty for scanned trees; acceptable (matches "no hardlinks detectable") and the fallback grouping can be forced via the identity-metadata check if this proves wrong in practice.
- [Scan-rate cost of the extra attr] → expected nil; verified by before/after benchmark on a large tree in the PR.
- [One-time cold scan complaints] → release note; warm start re-establishes immediately after.

## Migration Plan

Single commit ships attr + flag + version bump together (a split would produce caches with ambiguous flag semantics). Rollback = revert (old builds reject the newer cache version by the same fail-closed rule).

## Open Questions

- Keep Hardlinks as a tab vs. fold into Insights as a card? Out of scope here (tab stays); revisit after the Insights restructure lands.
