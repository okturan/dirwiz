> **UNBLOCKS `throttled-ephemeral-sweep` (2026-07-31).** That change is stopped
> because `maxPatchRoots` (48) is checked before the item budget and its scheduled
> sweeps collapse to 84/99/131 roots at 1/5/15-minute holdbacks, so every sweep
> would cold-fall back. Section 1 here is already complete; its STOP evidence is
> recorded below and stands.

# Tasks - Retire the Root-Count Cap in Favour of the Item Budget

## 1. Diagnose before tuning

- [x] 1.1 Log per-root staged item counts during a real `/` warm patch: root path, estimated
      items, actual items staged. Use the existing phase instrumentation from
      `SubtreeRescanMetricsTests`/`RealVolumeWarmStartBenchmarkTests` rather than adding a
      third harness.
- [x] 1.2 Report the distribution for at least three real patches. Specifically: does one root
      account for most of the staged items?
- [x] 1.3 DECISION POINT: if a single root dominates (say one root is over half the staged
      items), STOP and report. Narrowing attribution for that root is then a better change
      than raising the cap, and it should be specced separately rather than folded in here.
- [x] 1.4 Measure on an idle machine. `sysctl -n vm.loadavg` must be low. Load already
      invalidated one full round of scan timings in this repo, and it is the first thing to
      check when a number looks wrong.

### Diagnostic result - STOP (2026-07-30)

The Release harness was prebuilt and then run with `--skip-build` at production worker
defaults. Immediately before the run, `vm.loadavg` was `{ 1.59 2.06 6.08 }` on a 10-core
machine, sampled CPU idle was 87-89%, and disk traffic was 0.02-0.60 MB/s. The initial cold
scan took 19.606 s for 4,778,117 items.

The harness collected three distinct, non-empty, production-planner warm decisions. Each
workload was replayed three times from the same pre-patch scratch cache; all three repetitions
agreed on the item distribution:

| Workload | Roots | Estimated items | Actual staged items | Largest root | Share | Patch timing |
| --- | ---: | ---: | ---: | --- | ---: | ---: |
| 1 | 6 | 359,824 | 359,827 | `/private/var/folders/.../T` (151,609) | 42.13% | 1.907-2.644 s; median 2.034 s |
| 2 | 19 | 359,878 | 359,876 | `/private/var/folders/.../T` (151,609) | 42.13% | 2.015-2.068 s; median 2.020 s |
| 3 | 7 | 292,853 | 292,853 | `/private/var/folders/.../T` (151,609) | **51.77%** | 1.637-1.675 s; median refused because the live tree drifted |

The estimator was exact or within three items at aggregate level, so this is not an
item-estimation failure. Workload 3's item counts and root shares agreed across all three
repetitions despite that timing drift, and it crossed the decision point: one root accounted
for more than half of all staged items. Sections 2-5 are therefore deliberately not started.
Narrowing FSEvents attribution for the oversized temp root - which contains the benchmark's
isolated scratch cache - needs a separate spec before reconsidering the root cap.

- [ ] 1.6 Re-confirm the blocking evidence from `throttled-ephemeral-sweep`: collapsed roots of 84 at a 1-minute holdback, 99 at 5 minutes, 131 at 15, all against a cap of 48
- [ ] 1.7 Confirm `maxPatchRoots` is evaluated before the item-fraction rule in `decide`, since the ordering is the defect rather than the value

## 2. Make the item gate trustworthy before moving the cap

The cap currently masks the item gate. Once it is raised, the item gate is the only thing
standing between a user and a patch that is slower than the cold scan it replaced.

- [ ] 2.1 Characterisation tests FIRST, pinning today's `decide` outputs across the shapes
      that matter: few large roots, many tiny roots, one huge root, empty change set. Write
      these before changing any constant, per the repo's analyzer-refactor convention.
- [ ] 2.2 Quantify `estimatedPatchItemCount`'s error against actual staged items using the 1.1
      data. It estimates from the cached tree, so a root that grew since the cache is
      underestimated.
- [ ] 2.3 If the estimate can undershoot materially, bound it: either inflate the estimate for
      roots whose cached subtree is small (a small cached subtree is the case where growth is
      unbounded and invisible), or re-check the item budget mid-patch once real counts are
      known and abandon into a coherent cold fallback. Reuse `commitWarmStart`'s existing
      mid-patch abandonment path and its reason threading, do not invent a second one.
- [ ] 2.4 Assert the protective case explicitly: a many-root patch covering a large item
      fraction must still fall back cold, with the reason naming the fraction and not the
      root count.

## 3. Move the constants

- [ ] 3.1 Derive the item threshold from the model in the proposal, showing the arithmetic in
      the doc comment. Record what fraction was chosen and why. If 0.25 survives on the
      evidence, say so and keep it; an unchanged constant with a stated reason is a valid
      outcome and better than a churned one.
- [ ] 3.2 Raise `maxPatchRoots` to a backstop level, replacing the doc comment's now-void
      "until a batched single-pass splice lands (043)" rationale with the measured post-splice
      numbers. State plainly that per-root splice cost is no longer the reason for the cap.
- [ ] 3.3 Fix the stale claim in `decide`'s doc comment that no call site supplies
      `estimatedPatchItems`/`cachedTotalItemCount`.
- [ ] 3.4 Update the boundary tests in `WarmStartTests.swift` (the 48 boundary, one-past, and
      custom-value tests) deliberately, and the fixture comments in `ScanSupervisionTests.swift`
      that reference the old default. These are intentional pins, so change them with intent
      rather than adjusting numbers until green.

## 4. Verify

- [ ] 4.1 Focused gates green: warm-start equivalence, subtree-rescan equivalence, planner
      decision tests, cancellation coverage. Patched tree must still equal a fresh cold scan.
      A failure here is a STOP, not a test to adjust.
- [ ] 4.2 THE ACTUAL GATE, and it is a behaviour change rather than a time: re-run the
      three-refresh sequence on `/` and confirm the refreshes that previously fell back cold
      now stay warm. Report each refresh's decision, root count, staged items and duration.
      Do not gate on an absolute patch time. The last spec's `<1s` target was arithmetically
      impossible (it demanded 3.0x to 3.6x the scanner's peak throughput) and that mistake
      cost a full implementation cycle.
- [ ] 4.3 Confirm no refresh that SHOULD go cold now goes warm. Report the fraction at which
      each fell back.
- [ ] 4.4 Full suite, plus a `CI=true` parity run. If `ScanSupervisionTests` fails, stash the
      change and confirm master fails identically before attributing it: there is a known
      load-induced FSEvents flake there that reproduces only under full-suite parallel load
      and is documented in CLAUDE.md.

## 5. Documentation

- [ ] 5.1 CLAUDE.md: record that the warm-patch gate is now the item fraction and that root
      count is only a backstop, and why (per-root splice cost went constant). The existing
      warm-start section already explains the cap, so correct it rather than appending.
