# Tasks — Firmlink-Aware Traversal

## 1. Firmlink table (DirWizCore)

- [x] 1.1 Add `FirmlinkTable`: parse `/usr/share/firmlinks` (tab-separated `<system path>\t<data-relative path>`), expose the set of absolute Data-side paths to skip; missing/unreadable/malformed → empty set (fail open)
- [x] 1.2 Only include a target when its `/`-side path is statable, so an unreadable system-side path never causes content to be dropped on both sides
- [x] 1.3 Honor a `DIRWIZ_NO_FIRMLINK_DEDUP=1` kill switch, matching the repo's other `DIRWIZ_*` escape hatches
- [x] 1.4 Unit tests with an injected table (do not depend on the host's real `/usr/share/firmlinks`): well-formed parse, missing file, malformed lines, blank lines, CRLF

## 2. Wire into traversal (DirWizCore)

- [x] 2.1 Build the skip set once per scan alongside the existing per-scan setup; pass it down with `visited` to both the raw and deferred enumeration paths
- [x] 2.2 Skip enqueueing a directory whose absolute path is in the skip set; leave `VisitedDirectories` untouched as the loop guard
- [x] 2.3 Guard on the scan root: only active when the root contains both sides (whole-volume `/` scans); a scan rooted at `/System/Volumes/Data` or at a firmlinked path enumerates everything

## 3. Tests

- [x] 3.1 Fixture-based single-count test using an injected table over a synthetic tree with a simulated duplicate branch — must assert BOTH the total and the per-path attribution, since a total-only assertion passes intermittently against the racy unfixed code
- [x] 3.2 Determinism test: scan the same fixture repeatedly, assert identical per-path sizes every run
- [x] 3.3 Non-firmlinked Data content survives (a path under the Data root that is not in the table keeps its bytes)
- [x] 3.4 Subtree scan unaffected: scanning the Data root directly enumerates everything
- [x] 3.5 Fail-open test: empty/absent table reproduces pre-change behavior exactly
- [x] 3.6 Warm-start equivalence gates still pass (`SubtreeRescanTests`, `WarmStartTests`) — the patched tree must still equal a fresh cold scan under the new traversal

## 4. Verification and docs

- [x] 4.1 Before/after on a real `/` scan: record root total, `/Applications`, `/Library`, `/System/Library/AssetsV2`, and the `statfs` figure; confirm the duplicate is gone and previously-stranded directories report their real sizes
- [x] 4.2 Confirm scan wall time is unchanged (the table is 19 rows read once)
- [x] 4.3 Full suite green; CLAUDE.md scanner section records why `(dev, inode)` cannot catch firmlinks (synthetic id vs real inode, identical `dev`) so the mechanism isn't rediscovered
- [x] 4.4 Release note: root-volume totals drop, and this is a correction — the previous total exceeded the volume's physical capacity

## Implementation notes (as built)

- Deduplication is folded into `VisitedDirectories.shouldTraverse(path:dev:inode:)` rather than threaded as a new parameter through eight enumeration signatures. It deliberately does NOT mark the inode visited when skipping, so the `/`-side copy stays free to claim it — marking it would trade a double count for a silent omission.
- `FileScanner.resolveFirmlinkDuplicates(forScanRoot:)` is the single resolution point, used by both `scan` and `rescanSubtrees`; a test-only initializer injects the set because APFS has no directory hard links, so real firmlinks cannot be reproduced in a fixture.
- Verified on the live volume: root total 1065.1 GB → 1019.3 GB, `/Library` 0.0 GB → 92.6 GB, `/System/Library/AssetsV2` 0.0 GB → 47.8 GB, all three Data-side duplicates skipped. Full suite 507 tests green including the warm-start equivalence gates.
- A test caught a latent CRLF parsing bug: `split(separator: "\n")` never splits at `\r\n` because Swift treats it as one grapheme, so the second field silently absorbed the following line. Fixed with `whereSeparator: { $0.isNewline }`.
- Remaining gap to `statfs` (~193 GB) is the out-of-scope clone/hardlink block sharing documented in the proposal, not a traversal defect.
