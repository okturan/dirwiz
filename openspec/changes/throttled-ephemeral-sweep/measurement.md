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

### Initially derived policy

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

### Production planner conflict - STOP

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

### Total-work gate

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
