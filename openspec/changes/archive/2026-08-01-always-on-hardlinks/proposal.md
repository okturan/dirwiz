# Always-On Hardlinks via Scan-Time Link Counts

## Why

Hardlink detection is already a pure in-memory group-by over scan-time `(device, inode)` - the "scan" button is theater. Capturing the file link count in the same `getattrlistbulk` call (it lives in the same catalog record; effectively free) shrinks the work to grouping only the few flagged files, making hardlinks an always-fresh, zero-cost fact that never needs a button.

## What Changes

- The bulk enumeration requests `ATTR_FILE_LINKCOUNT`; files with link count > 1 get a new `FileNode` flag bit (`hasMultipleHardlinks`). Directories never set it (their link count means something else).
- **BREAKING (cache format)**: `FileNode`'s stored layout changes → `TreeCache.formatVersion` bump; existing caches are rejected fail-closed and the next scan runs cold once (per CLAUDE.md rule).
- `HardlinkFinder` gains a fast path: filter flagged files, group only those - milliseconds instead of a dictionary over every file. The full-scan fallback remains for synthetic/test trees without identity metadata.
- Hardlink groups auto-populate after every completed scan and recompute after tree mutations; the Hardlinks tab's run button is removed (results or an honest empty state are always shown).
- Warm-start spliced nodes get the flag through the same parse path (no special casing).

## Capabilities

### New Capabilities
- `hardlink-capture`: scan-time link-count capture, the flag's semantics, auto-population lifecycle, and fast-path/full-path equivalence.

### Modified Capabilities
None - no baseline specs exist yet.

## Impact

- **DirWizCore**: `FilesystemProvider` (attr request + raw-buffer parse - attribute order matters: `ATTR_FILE_LINKCOUNT` precedes the data/alloc-size attrs in the packed buffer), `FileNode` (flag bit), `TreeCache` (formatVersion bump), `FileScanner` (both materialization strategies set the flag), `HardlinkFinder` (fast path).
- **DirWizUI**: `HardlinkState`/`AppState` auto-run post-scan + mutation invalidation; `HardlinkView` loses the button.
- **Tests**: mock-provider parse tests, real-filesystem fixtures using `link(2)`, fast-path ≡ full-path equivalence gate, cache-rejection test for the version bump.
