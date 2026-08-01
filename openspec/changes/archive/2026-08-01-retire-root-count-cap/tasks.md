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
for more than half of all staged items. Sections 2-5 were therefore deliberately not started
in that run. Follow-up observation confirmed that the temp-root churn was real and
distributed rather than attributable to DirWiz's scratch cache, so narrowing FSEvents
attribution would have been incorrect. `deferred-ephemeral-roots` subsequently isolated
that low-freshness work, and the `throttled-ephemeral-sweep` holdback measurements exposed
the root-cap ordering defect that resumed this change at task 1.6.

- [x] 1.6 Re-confirm the blocking evidence from `throttled-ephemeral-sweep`: collapsed roots of 84 at a 1-minute holdback, 99 at 5 minutes, 131 at 15, all against a cap of 48
- [x] 1.7 Confirm `maxPatchRoots` is evaluated before the item-fraction rule in `decide`, since the ordering is the defect rather than the value

The source evidence still matches the handoff at `bb583c0`: the holdback record reports
84/99/131 collapsed roots at 1/5/15 minutes, while `WarmStartPlanner.decide` defaults
`maxPatchRoots` to 48 and checks `roots.count` before it evaluates
`estimatedPatchItems / cachedTotalItemCount`. The ordering, not merely the constant, is
what prevents the item-cost rule from deciding those accumulated workloads.

## 2. Make the item gate trustworthy before moving the cap

The cap currently masks the item gate. Once it is raised, the item gate is the only thing
standing between a user and a patch that is slower than the cold scan it replaced.

- [x] 2.1 Characterisation tests FIRST, pinning today's `decide` outputs across the shapes
      that matter: few large roots, many tiny roots, one huge root, empty change set. Write
      these before changing any constant, per the repo's analyzer-refactor convention.
- [x] 2.2 Quantify `estimatedPatchItemCount`'s error against actual staged items using the 1.1
      data. It estimates from the cached tree, so a root that grew since the cache is
      underestimated.
- [x] 2.3 If the estimate can undershoot materially, bound it: either inflate the estimate for
      roots whose cached subtree is small (a small cached subtree is the case where growth is
      unbounded and invisible), or re-check the item budget mid-patch once real counts are
      known and abandon into a coherent cold fallback. Reuse `commitWarmStart`'s existing
      mid-patch abandonment path and its reason threading, do not invent a second one.
- [x] 2.4 Assert the protective case explicitly: a many-root patch covering a large item
      fraction must still fall back cold, with the reason naming the fraction and not the
      root count.

The three stable real-volume workloads were estimated at 359,824 vs 359,827 actual
(-3, -0.000834%), 359,878 vs 359,876 (+2, +0.000556%), and 292,853 vs 292,853
(exact). Aggregate error was -1 across 1,012,556 actual items; maximum absolute error
was three items. That validates using the cached estimate when the subtree is stable,
but does not bound post-cache growth. The synthetic growth characterization starts
from a two-item cached subtree and stages 202 live items, proving that this error shape
is material and has no finite up-front multiplier.

The bound therefore uses Phase A's exact staged counts, after enumeration but before
`onWillCommit` and the transactional Phase B splice. An over-budget report leaves the
cached tree untouched and is threaded through `commitWarmStart`'s existing abandonment
path. Interactive and trailing tiers subtract from one shared integer budget; the
two-tier regression proves that 3 + 3 staged items exceeds a four-item budget rather
than receiving two separate allowances. Cancellation remains distinct, and exact
boundary counts still commit.

## 3. Move the constants

- [x] 3.1 Derive the item threshold from the model in the proposal, showing the arithmetic in
      the doc comment. Record what fraction was chosen and why. If 0.25 survives on the
      evidence, say so and keep it; an unchanged constant with a stated reason is a valid
      outcome and better than a churned one.
- [x] 3.2 Raise `maxPatchRoots` to a backstop level, replacing the doc comment's now-void
      "until a batched single-pass splice lands (043)" rationale with the measured post-splice
      numbers. State plainly that per-root splice cost is no longer the reason for the cap.
- [x] 3.3 Fix the stale claim in `decide`'s doc comment that no call site supplies
      `estimatedPatchItems`/`cachedTotalItemCount`.
- [x] 3.4 Update the boundary tests in `WarmStartTests.swift` (the 48 boundary, one-past, and
      custom-value tests) deliberately, and the fixture comments in `ScanSupervisionTests.swift`
      that reference the old default. These are intentional pins, so change them with intent
      rather than adjusting numbers until green.

The 0.25 item fraction is retained. With cold `26.42s` and warm modelled as
`26.42f + 0.15`, `f = 0.25` predicts `6.755s` warm versus `26.42s` cold, a
`19.665s` saving; crossover is approximately `0.9943`. The measured 6.13-7.53%
workloads are further below the boundary, so lowering it is unsupported.

`maxPatchRoots` is now 512 and is checked after the item gate. That is 3.91x the
largest measured accumulated workload (131 roots), yet still 9.77x below the
unchanged 5,000 unknown-directory defensive backstop. The boundary tests pin
512/513, a 131-root tiny patch stays warm, and an 84-root 30% patch names the
item fraction when it falls back.

## 4. Verify

- [x] 4.1 Focused gates green: warm-start equivalence, subtree-rescan equivalence, planner
      decision tests, cancellation coverage. Patched tree must still equal a fresh cold scan.
      A failure here is a STOP, not a test to adjust.
- [x] 4.2 THE ACTUAL GATE, and it is a behaviour change rather than a time: re-run the
      three-refresh sequence on `/` and confirm the refreshes that previously fell back cold
      now stay warm. Report each refresh's decision, root count, staged items and duration.
      Do not gate on an absolute patch time. The last spec's `<1s` target was arithmetically
      impossible (it demanded 3.0x to 3.6x the scanner's peak throughput) and that mistake
      cost a full implementation cycle.
- [x] 4.3 Confirm with deterministic protective cases that patches which SHOULD go cold
      still do. Report the fraction at which each fell back.
- [x] 4.4 Full suite, plus a `CI=true` parity run. If `ScanSupervisionTests` fails, stash the
      change and confirm master fails identically before attributing it: there is a known
      load-induced FSEvents flake there that reproduces only under full-suite parallel load
      and is documented in CLAUDE.md.

## 5. Documentation

- [x] 5.1 CLAUDE.md: record that the warm-patch gate is now the item fraction and that root
      count is only a backstop, and why (per-root splice cost went constant). The existing
      warm-start section already explains the cap, so correct it rather than appending.

Focused Release verification ran 93 warm-start, subtree-rescan, cancellation, metrics,
and equivalence tests; all passed, including the 50k-file changed-root fixture and both-tier
patched-tree equivalence.

The real `/` sequence ran at pre-test `vm.loadavg={ 1.57 1.83 2.56 }` (the harness
reported `{ 1.84 1.88 2.57 }`) against a 4,800,864-item cache. All three planner
decisions stayed warm:

| Refresh | Collapsed roots | Actual staged items | Warm patch duration |
| --- | ---: | ---: | ---: |
| 1 | 10 | 335,051 | 3.946586 s |
| 2 | 6 | 345,110 | 3.750127 s |
| 3 | 3 | 254,819 | 1.397438 s |

Ambient churn in this particular sequence produced fewer roots than the former cap,
so it is supporting evidence only and does not close task 4.2. The recorded
84/99/131 holdback envelope was then covered with a bounded controlled fixture inside
the real `/` harness. The fixture was present in the initial cold cache; production
FSEvents replay and collapse had to preserve every changed child as an independent
root, the production planner had to choose warm, the exact-budget rescan had to
complete, and every marker had to survive both the cache save and a fresh reload.
At `vm.loadavg={ 2.78 1.92 1.83 }`, all three passed:

| Refresh | Forced roots | Collapsed roots | Actual staged items | Decision | Warm patch duration |
| --- | ---: | ---: | ---: | --- | ---: |
| 1 | 84 | 95 | 400,878 | warm | 4.526010 s |
| 2 | 99 | 167 | 534,894 | warm | 5.079690 s |
| 3 | 131 | 143 | 347,327 | warm | 2.897049 s |

Every patch reported `requested == rescanned`, zero unresolved paths, and no
cancellation. The scratch cache saved after each refresh, reloaded with the new event
horizon and every marker, and the self-owned fixture was removed. These are controlled
production-path gate results, not ambient holdback timings; no absolute time threshold
was applied.

Protective cold
cases fell back at 25.001%, 30%, 42%, 75%, and 90% up front, all naming the item
fraction. The exact post-Phase-A guard also forced a coherent cold fallback at
6/19 cached items (about 32%) across two tiers, with the reason in summary and history.

The final Release suite passed 702 tests in 101 suites. Its first invocation had one
non-reproducible FSEvents timing miss in the deferred-ephemeral navigation gate; the
unchanged test passed immediately in isolation and the complete suite then passed on
rerun. `ScanSupervisionTests` passed in both complete runs, so the master-comparison
exception was not invoked. The required `CI=true` Release parity run also passed all
702 tests in 101 suites (with the documented heavy benchmark skips).
