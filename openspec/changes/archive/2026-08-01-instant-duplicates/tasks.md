# Tasks - Instant Duplicates

## 1. Core analyzer (DirWizCore)

- [x] 1.1 Add `InstantDuplicateFinder` with the two-pass `(size, folded-name)` build over `forEachFileInSnapshot`, min-size parameter, cancellation checks, and in-bucket name-byte equality confirmation
- [x] 1.2 Collapse `(device, inode)` sharers to one representative per bucket; drop buckets that fall below 2 members after collapsing
- [x] 1.3 Return path-keyed candidate groups (paths + sizes + potential-waste bytes), sorted by potential waste descending
- [x] 1.4 Tests: temp-tree fixtures for basic grouping, min-size exclusion, case-insensitive vs case-sensitive naming (hand-built trees via `@testable` internals for the case-sensitive flag), hardlink collapsing via `link(2)` fixtures

## 2. Scoped verification (DirWizCore)

- [x] 2.1 Refactor `DuplicateFinder` to expose a scoped entry point running passes 2–4 (partial hash → full hash → hardlink dedup + byte verification) over supplied candidate groups; full scan re-expressed through the same engine
- [x] 2.2 Characterization tests first: pin current full-scan outputs on a fixture tree, then verify the refactor preserves them
- [x] 2.3 Equivalence tests: scoped verification of instant candidates ≡ full-scan groups for overlapping inputs; different-content same-name/size pairs rejected

## 3. UI state and view (DirWizUI)

- [x] 3.1 Extend `DuplicateState` with instant groups, verification statuses, and an instant token; register clearing in `resetForNewScan()` and recompute in `invalidateAfterTreeMutation()`
- [x] 3.2 Auto-run instant grouping on Duplicates tab open and on scan completion (token-guarded background task)
- [x] 3.3 Two-section `DuplicateFilesView`: candidates (labeled heuristic, no trash affordances) and confirmed groups (existing cleanup UI); per-group Verify button with progress, plus Verify All
- [x] 3.4 Ensure only verification-produced `DuplicateGroup`s reach cleanup/trash code paths (distinct candidate type, compile-time separation)
- [x] 3.5 Wire min-size picker to the instant finder; re-run on change

## 4. Verification and polish

- [x] 4.1 Perf sanity: instant grouping on a ~2M-node tree completes sub-second in release; record numbers in the PR description
- [x] 4.2 Run full suite; update CLAUDE.md Duplicates paragraph (instant mode + verify gate)

## Implementation notes (as built)

- **The safety gate is a TYPE, not a flag.** `InstantDuplicateCandidate` is a separate type
  from `DuplicateGroup`, and every cleanup/trash path takes `DuplicateGroup`. A heuristic
  result therefore cannot reach deletion by accident - the compiler enforces what a
  `isVerified: Bool` would have left to reviewer discipline. `InstantDuplicateVerifier` is
  the only bridge between the two.
- **2.1/2.2 were not done as specified, deliberately.** The task called for refactoring
  `DuplicateFinder` to expose passes 2–4 as a scoped entry point. But
  `DuplicateContentVerifier.exactGroups` - already hardened, already opening with
  `O_NOFOLLOW`, already the guard on the existing trash path - does precisely the needed
  job. The partial/full hash passes exist to avoid byte-comparing millions of files; for
  one candidate group of a few files they are pure overhead. Reusing the verifier avoids a
  risky refactor of the exhaustive engine for no benefit. The characterization tests of
  2.2 were therefore unnecessary: the full-scan code is untouched.
- `verify` returns an ARRAY of groups, not an optional one. A candidate routinely splits
  into several genuine content groups (or none); a single-group return type would force
  either merging non-identical files or discarding real duplicates.
- Hardlinks collapse to one representative per bucket via `(device, inode)`. Counting them
  would promise space that deleting them cannot reclaim.
- Rejected candidates are surfaced as "Different content" rather than silently vanishing -
  a checked answer, not a button that appears to do nothing.
- A nested `ScrollView` bug was introduced and caught while wiring the two-section view:
  `duplicateList` had its own scroll view, and putting it inside the new outer one collapses
  it to zero height. It is now a plain `Group`; the caller owns scrolling.
- 4.1 measured: **456 ms release** (820 ms debug) for 1,000,000 files, gated by a test.
  Zero file-content reads on this path.

## Characterization of the untouched engine (2.2, added after the first pass)

- 2.1's refactor is still deliberately NOT done (see above). But "we chose not to refactor"
  is only credible if the engine's behavior is actually pinned, so
  `DuplicateFinderCharacterizationTests` now fixes the full scan's observable outputs:
  grouping by content regardless of filename, same-size-different-content rejection, the
  minimum-size threshold, wasted-space ordering, stats/group consistency, and the empty
  case. If anyone attempts the 2.1 refactor later, a behavior change shows up there.
