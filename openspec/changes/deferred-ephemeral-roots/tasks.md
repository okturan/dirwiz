# Tasks - Defer Ephemeral Roots in the Warm Patch

## 1. Get the ephemeral path set right before anything depends on it

- [ ] 1.1 An `EphemeralPaths` type in DirWizCore, pure and injectable like `WarmStartPlanner`
      and `LiveRefreshPolicy`, resolving `_CS_DARWIN_USER_TEMP_DIR` and
      `_CS_DARWIN_USER_CACHE_DIR` via `confstr`. Fail OPEN: if resolution fails, treat nothing
      as ephemeral and patch exactly as today. A missing table must never drop content.
- [ ] 1.2 Handle both path-form landmines explicitly, with tests: the trailing slash `confstr`
      returns, and the `/var` versus `/private/var` firmlink difference against what FSEvents
      reports. A silent non-match makes this whole change a no-op that still looks implemented,
      so assert a real FSEvents-shaped path matches.
- [ ] 1.3 Decide and document whether `~/Library/Caches` joins the set. Argument for: same
      churn-to-value ratio. Argument against: users genuinely hunt for cache bloat there and
      may expect it fresh. Pick one, write down why, do not leave it implicit.
- [ ] 1.4 `DIRWIZ_NO_EPHEMERAL_DEFER=1` escape hatch, matching the repo's habit of shipping one
      beside every scanner behaviour change.

## 2. The cache-horizon problem, FIRST, because it is the silent-corruption risk

- [ ] 2.1 Write the failing test before the fix: defer a subtree, persist the cache, warm start
      again, and assert the deferred subtree is NOT permanently stale. This is the bug that
      would ship invisibly, so it needs a test that fails today's naive implementation.
- [ ] 2.2 Implement the horizon rule: the persisted `lastEventId` must never be newer than the
      data actually patched. Either hold it back to the deferred work's horizon, or do not
      persist until the trailing pass completes. State which and why in the doc comment.
- [ ] 2.3 STOP CONDITION: if the horizon cannot be held correctly, stop and report. Shipping a
      cache that claims to be current as of an id whose changes it never applied is worse than
      a slower patch, and worse than not doing this change at all.
- [ ] 2.4 Cover the interrupted case: app quits, or the patch is cancelled, mid-deferral.

## 3. Two-tier patch

- [ ] 3.1 Partition the planner's target list into interactive and ephemeral roots. Keep the
      partition in DirWizCore so it is testable without the app.
- [ ] 3.2 Splice the interactive roots as one batched compaction (unchanged path), publish, then
      sweep the ephemeral roots on a trailing lower-priority pass and splice again.
- [ ] 3.3 The trailing pass must be cancellable, must respect the existing token-counter
      discipline so a stale pass cannot clobber a newer scan, and must not fight
      `LiveRefreshPolicy`. A deferred sweep must not itself trigger another refresh cycle.
- [ ] 3.4 Represent the deferred-stale state rather than presenting it as fresh. Reuse the
      existing staleness vocabulary (`staleViewAsOf`, skipped-directory honesty) instead of
      inventing a parallel one.
- [ ] 3.5 Run `invalidateAfterTreeMutation()` correctly for BOTH splices. The trailing splice
      renumbers indices exactly like the first, so every index-keyed consumer must be
      invalidated again and the treemap layout revision bumped, or the map renders stale rects
      against wrong node indices.

## 4. Verify

- [ ] 4.1 THE GATE, non-negotiable: `patched-tree ≡ fresh-cold-scan` still holds once the
      trailing pass completes. This is the whole reason deferral was chosen over skipping. A
      failure here is a STOP, not a test to rescope.
- [ ] 4.2 Cold-scan totals are byte-identical to before this change. Only patch scheduling
      moved.
- [ ] 4.3 Real-volume run on an idle machine (check `vm.loadavg` first; load already invalidated
      one round of timings in this repo). Report interactive-tier time, trailing-tier time,
      staged items per tier, and the temp root's share. Expected from the diagnostic: staged
      items in the interactive tier drop 42-52%.
- [ ] 4.4 Gate on the interactive tier landing materially faster, and report the number. Do NOT
      set an absolute sub-second target: `batched-subtree-splice`'s `<1s` gate demanded 2x to
      3.6x the scanner's measured throughput and cost a full implementation cycle before anyone
      checked the arithmetic.
- [ ] 4.5 Full suite plus a `CI=true` parity run. If `ScanSupervisionTests` fails, stash and
      confirm master fails identically before attributing it: known load-induced FSEvents flake,
      documented in CLAUDE.md.

## 5. Documentation

- [ ] 5.1 CLAUDE.md, in the existing warm-start section rather than appended: the per-user
      Darwin temp directory is a permanently-changed root holding ~151,600 items and was 42-52%
      of every warm patch; patches defer it and cold scans still count it; and the cache
      horizon rule, which is the part a future change is most likely to break silently.
