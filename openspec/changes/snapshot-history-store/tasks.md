# Tasks - Snapshot History Store

## 1. Store core (DirWizCore/Diff)

- [x] 1.1 Container format: LZFSE-compressed TDSN payload with magic/version header; encode/decode with fail-closed guards; round-trip + truncation/corruption/unknown-version tests
- [x] 1.2 Per-volume store module: directory layout, checkpoint file naming, `index.json` read/write, index rebuild-from-directory self-healing; tests incl. missing/corrupt index
- [x] 1.3 Checkpoint creation API (from a `TemporalSnapshot`), atomic temp-file + rename, off-main friendly; store size accounting
- [x] 1.4 Change-summary computation vs. predecessor (top grown/shrunk dirs, deleted count/bytes, total delta) stored in index; tests on hand-built maps
- [x] 1.5 Retention as a pure function (tiers + budget, pinned exemption) with injected-clock tests covering daily/weekly/monthly thinning and eviction order; wire to run post-creation
- [x] 1.6 Legacy single-file import (pinned "Legacy snapshot", original date, `.imported` rename); migration tests

## 2. App integration (DirWizUI)

- [x] 2.1 Auto-checkpoint at cold and warm scan-completion commit points with 6h/1% throttle (constants env-overridable); token-guarded background work
- [x] 2.2 Camera action → pin-with-name sheet creating a pinned checkpoint; `TemporalDiffState` gains selected-baseline checkpoint
- [x] 2.3 Compare-to picker in the diff banner/toolbar (newest-first, names + dates + summaries, default latest); diff overlay works against any selected checkpoint
- [x] 2.4 Store size shown in picker footer

## 3. CLI

- [x] 3.1 `snapshot` creates a store checkpoint (`--name` pins); `diff` uses latest baseline; new `snapshot list` output; help text updated
- [x] 3.2 CLI tests via `DIRWIZ_APP_SUPPORT_DIR` (suite `.serialized` per the env-var race warning); GUI/CLI store-sharing test

## 4. Verification and docs

- [x] 4.1 Compression ratio + write-time measurement on a synthetic 350k-dir map recorded in PR notes
- [x] 4.2 Full suite green; CLAUDE.md temporal-snapshots section rewritten for the store (multi-checkpoint, pinning, retention, migration)

## Implementation notes (as built)

- **A stored-uncompressed mode was required, not optional.** LZFSE expands tiny and
  high-entropy inputs, and `compression_encode_buffer` then returns 0 - so the first
  implementation could not write a small snapshot at all (every store test failed with
  `encodeFailed`). The container header now carries a mode byte, and encode falls back to
  storing the payload verbatim when compression does not actually help.
- **The index is a CACHE, never the truth.** It is rebuilt from the `.dwcp` files whenever
  it is missing or corrupt. Losing it costs names and summaries; it must never cost
  checkpoints. Recovered checkpoints are marked PINNED, because the store cannot tell which
  ones the user cared about and thinning them right after an index loss would compound the
  damage.
- **Ordering bug worth recording**: `createCheckpoint` originally listed existing
  checkpoints AFTER writing the new file. Because `list()` self-heals a missing index by
  adopting every `.dwcp` on disk, the very first checkpoint was adopted as a "Recovered"
  pin and then added again. Reading the timeline before the write fixes it.
- Retention never evicts a pin - not even to get under budget. Where a pinned store exceeds
  the budget the honest answer is to tell the user, not to delete the thing they named.
- `--name` had to be added to `CLIArguments.valueFlags`. Without it,
  `snapshot /path --name foo` parses "foo" as a second positional; a subcommand reading
  `positionals.first` would silently act on the wrong path. Pinned by a test.
- Legacy migration renames the old single-slot file to `.tdiff.imported` rather than
  deleting it, so a bad migration is recoverable, and imports as a PINNED "Legacy snapshot"
  because it is the user's only existing baseline and must survive retention's first run.
- 4.1 measured: a 350,000-directory map is **22 MB raw → 2 MB stored (12%), 211 ms** to
  write, gated by a test. Comfortably inside the 500 MB default store budget for a long
  timeline.

## Compare-to picker (2.3 / 2.4, added after the first pass)

- The diff banner's date is now a menu listing every checkpoint newest-first, each with its
  own delta and pin marker, with a footer giving the count and total bytes on disk.
  Selecting one calls `selectDiffBaseline`, which RECOMPUTES the overlay - the diff arrays
  are index-keyed to the current tree, so leaving them in place would paint one
  checkpoint's diff using another's numbers.
- A checkpoint that has since been thinned away drops the overlay rather than continuing to
  show the previous diff.
- The camera action now opens a small sheet: naming a moment pins it, "Save Unnamed"
  records an ordinary thinnable checkpoint. An all-whitespace name is treated as unnamed -
  pinning something the user cannot identify later is worse than not pinning.
- Still Phase B per the proposal: the full timeline scrubber UI (cards, scrubbing) is not
  built; this is a picker, not a scrubber.
