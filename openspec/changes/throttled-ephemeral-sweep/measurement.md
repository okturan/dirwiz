## Measurement record

Measured on 2026-07-31 on the implementation machine, before product-code changes.

### Idle gate

The Release harness was prebuilt before timing. Two samples taken 20 seconds apart
immediately before the replay run were:

- `vm.loadavg = { 2.19 2.18 2.52 }`, peak process CPU 22.6%
- `vm.loadavg = { 2.35 2.22 2.52 }`, peak process CPU 38.2%

Both satisfy the repository timing gate of load1 no greater than 3 and no process
above 50% CPU.

### Current cadence and work

- The Darwin user temp root contained 158,018 items; a Release CLI scan reported
  1.7 seconds of scanner time (2.19 seconds process wall time).
- Its mtime changed 15 times in a 60-second idle observation. The median interval
  between observed changes was 2 seconds and the mean was 4 seconds.
- `LiveRefreshPolicy.minimumIntervalSeconds` is 10 seconds, so the existing
  always-on live patch can enumerate the temp root at a ceiling of 6 sweeps/minute.
- At 158,018 items/sweep, that ceiling is 948,108 enumerated items/minute.

The live patch is the recurring path. Warm-start's trailing tier sweeps once per
warm launch; leaving `AppState+Analysis.applyAccumulatedChanges()` monolithic would
leave the dominant repeated work untouched.

### Journal holdback curve

`FSEventsGetLastEventIdForDeviceBeforeTime` is guaranteed only with
`FSEventStreamCreateRelativeToDevice`, so the zero-wait curve uses that matching
per-device stream rather than silently feeding device IDs to DirWiz's production
per-host stream. The opt-in Release harness runs the production flags, poison
conditions, file-to-parent target shaping, deduplication, and 10-second timeout.
It records three repeats in rotated age order.

| Holdback | Median | Range | Deduped directory targets | Collapsed roots | Poisoned |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 minute | 0.011064 s | 0.011056-0.011701 s | 177 | 84 | 0/3 |
| 5 minutes | 0.031350 s | 0.030822-0.031991 s | 302 | 99 | 0/3 |
| 15 minutes | 0.072174 s | 0.071187-0.072276 s | 404 | 131 | 0/3 |
| 30 minutes | 0.154315 s | 0.152232-0.385664 s | 761 | 18 | 0/3 |

The 30-minute first/cold sample was 0.385664 seconds. No measured window
approached the production 10-second timeout or emitted a poison flag.

### Initially derived policy (superseded)

- **Default interval: 15 minutes.**
- **Maximum held cache horizon: 30 minutes.**

The horizon is the longest measured non-poisoning window. The interval is half that
bound, leaving one full scheduled interval for a guard-delayed retry before the
horizon itself forces the next opportunity. At steady churn this changes the ceiling
from 6 sweeps/minute to `1 / 15 = 0.0667` sweeps/minute and from 948,108 to
`158,018 / 15 = 10,535` enumerated items/minute, a 98.89% reduction.

Four scheduled sweeps/hour plus navigation-triggered sweeps is still a throttle,
not the rejected skip design. The safe holdback is also long enough to win
materially at the journal layer.

### Production planner conflict - historical STOP

The journal curve is not the whole safety gate. `WarmStartPlanner.decide` still has
an always-on `maxPatchRoots` limit of 48, checked before its item and directory-fraction
budgets. The same measurements produced 84 collapsed roots after 1 minute, 99 after
5 minutes, and 131 at the proposed 15-minute interval. A scheduled sweep that replays
the held checkpoint therefore cold-falls back at each useful tested interval through
15 minutes, despite the replay itself being fast and unpoisoned.

The journal holdback remains safe and useful, so neither task 1.5 nor task 2.3 fires.
Instead this fails the end-to-end total-work gate at task 4.1: the shortest measured
holdback already exceeds the production planner's patchable root window, and the
derived default would turn scheduled sweeps into the full cold scan this change is
required never to cause. The 30-minute sample's 18 collapsed roots do not rescue the
design: root collapse is non-monotonic under ambient churn, using the maximum horizon
as the normal interval leaves no guard-delayed retry margin, and one passing sample is
not a safe default.

No interval or horizon is approved for production by this record. Either
`retire-root-count-cap` must land first, or this change needs a new design that can
prove an in-memory applied-through horizon without replaying the full held target set.

### Historical total-work gate

| Schedule | Patch execution throughput | Sweeps/minute | Enumerated items/minute | Time-averaged items/second |
| --- | ---: | ---: | ---: | ---: |
| Before, temp tier every live interval | 79,000-119,000 items/s across both tiers | up to 6 | up to 948,108 temp items | up to 15,802 temp items/s |
| Intended 15-minute throttle | same existing splice machinery | 0.0667 | 10,535 temp items | 176 temp items/s |
| Actual prototype with production planner | not a patch: cold fallback | 0.0667 scheduled attempts | full-tree enumeration per attempt | not accepted |

The intended schedule would reduce repeated temp enumeration by 98.89%, but it is not
the observed end state. At the 15-minute default the 131-root replay hits the 48-root
gate before the item budget, so there is no valid post-change combined patch throughput
to report. Substituting cold-scan throughput would hide the failure rather than measure
the requested throttle. The real-volume latency and full-suite gates were not run after
this STOP.

## Post-cap production-path remeasurement

Measured on 2026-07-31 after `retire-root-count-cap` landed on master as `9431689`.
Every run started from a fresh cold `/` cache; later samples within a multi-refresh
run loaded the cache saved by the preceding successful refresh. All used production
per-host `FSEventsJournal.replay`, path collapse, `WarmStartPlanner.decide`, the exact
post-Phase-A staged-item guard, the two-tier splice, and cache persistence. The red
`wip/throttled-ephemeral-sweep` branch was not used.

Journal replay never timed out or poisoned. Root count also never approached the new
512-root sanity backstop. The binding constraint was the primary 25% item fraction:

| Holdback | Replay | Collapsed roots | Estimated items | Exact staged items | Decision | Patch/fallback |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| 1 minute | 0.020741 s | 8 | 335,797 (7.0%) | 335,801 | warm | 3.792838 s |
| 5 minutes | 0.019937 s | 27 | 415,710 (8.7%) | 415,682 | warm | 4.200718 s |
| 15 minutes | 0.030087 s | 13 | 3,657,243 (76%) | n/a | cold | 19.043020 s |
| 30 minutes | 0.261236 s | 73 | 3,960,562 (82%) | n/a | cold | 20.077519 s |
| 10 minutes | 0.032102 s | 19 | 3,816,289 (79%) | n/a | cold | 21.775126 s |
| 5-minute repeat | 0.044139 s | 10 | 3,817,865 (79%) | n/a | cold | 20.288934 s |
| 1-minute repeat A | 0.040673 s | 42 | 356,398 (7.4%) | 356,199 | warm | 3.777860 s |
| 1-minute repeat B | 0.014135 s | 91 | 370,894 (7.7%) | 370,840 | warm | 4.000122 s |
| 1-minute repeat C | 0.022823 s | 71 | 547,284 (11.4%) | 547,225 | warm | 4.375849 s |
| 30-second repeat A | 0.017660 s | 22 | 503,464 (10.5%) | 503,441 | warm | 3.796861 s |
| 30-second repeat B | 0.018040 s | 7 | 3,813,950 (79%) | n/a | cold | 21.034151 s |
| 30-second repeat C | 0.027483 s | 59 | 394,971 (8.2%) | 394,855 | warm | 3.752027 s |

Operator-recorded shell load1 samples were at or below 3 before every run. Harness
samples were 1.67 for the initial 1/5/15-minute run, 2.34 for 30 minutes, 2.28 for
10 minutes, 2.36 for the independent 5-minute repeat, and 2.07 for the direct
30-second repeats. The three one-minute repeat decisions are behavioral evidence
rather than absolute timing evidence: that harness's own post-launch sample ticked
from the operator-recorded 2.93 to 3.17.

### Decision - STOP; no policy approved

The first re-derivation tentatively treated four green one-minute samples as a
60-second horizon and divided it by two for one guard-delayed retry. The direct
30-second run disproved that boundary: one of three samples produced a seven-root
change set estimated at 79% of the cached tree and correctly fell back cold.

The result is non-monotonic because FSEvents reports changed paths, not a stable amount
of work per elapsed second. A shorter window can still contain a high-level changed
path whose cached subtree exceeds the 25% budget. Fast, unpoisoned replay therefore
does not establish that the resulting patch is safe.

Had the 30-second candidate survived, its automatic scheduled cadence (excluding
navigation-triggered sweeps) would have fallen from at most six to two sweeps per
minute: `6 * 159,415 = 956,490` versus `2 * 159,415 = 318,830` enumerated temp items,
a 66.7% reduction. It did not survive. The warm samples themselves took
3.752027-3.796861 seconds of patch work, approximately 12.5% of a 30-second period
before cache load/save overhead.

Preserving one guard-delayed retry after this failure would require a measured-safe
horizon below 30 seconds and a default below 15 seconds. That is too close to the
existing 10-second cadence to justify the scheduling machinery, and no measured
boundary provides safety margin. Task 1.5 fires. No default interval or forced-sweep
horizon is approved, and sections 2 and 3 must not be implemented under the current
scheduling-only design.

The next design must avoid replaying already-applied high-level interactive roots into
the ephemeral sweep decision, or provide an equivalent independently-applied horizon.
That is a design change, not an interval adjustment, and is outside this measurement
record.
