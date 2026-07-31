## 1. Reproduce and characterise before changing anything

- [ ] 1.1 Reproduce the CI failure locally, noting it is intermittent under load and reliable on GitHub's runner
- [ ] 1.2 Confirm the mechanism: the reference fixture stages ~4,000 newly created files against a ~4,340-item cached tree, exceeding the 1,085-item budget
- [ ] 1.3 Confirm the up-front gate admitted the patch and only the mid-patch guard rejected it, so the defect is in the guard rather than the gate
- [ ] 1.4 Record whether the abandoned patch was already cheaper to finish than the cold scan it fell back to, with both measured

## 2. Characterisation tests first

- [ ] 2.1 Pin the guard's current behaviour across shapes: patch well under budget, patch slightly over near completion, patch massively over early
- [ ] 2.2 Add a deterministic protective case with a subtree grown far beyond its cached size, asserting a coherent cold fallback with a recorded reason
- [ ] 2.3 Confirm both tiers accumulate into the guard correctly, since the interactive and trailing tiers share one cumulative count

## 3. Correct the guard

- [ ] 3.1 Change the guard to compare projected remaining work against the cost of a cold fallback, not staged work against a cached-tree fraction
- [ ] 3.2 Make the approximation fail toward continuing, so an uncertain estimate never discards completed work
- [ ] 3.3 Give the mid-patch threshold its own constant and rationale, separate from `maxChangedItemFraction`
- [ ] 3.4 Keep the abandonment path routed through `commitWarmStart`'s existing mechanism and reason threading, without inventing a second one

## 4. Resolve the fixture question

- [ ] 4.1 Decide whether the CLAUDE.md reference fixture is a valid warm-patch shape the guard should permit, or a genuinely oversized patch needing more padding
- [ ] 4.2 Apply that decision to the fixture and update CLAUDE.md's description of it to match
- [ ] 4.3 Do NOT relax the `ScanSupervisionTests` warm-patch status assertion; it must pass because a warm patch happened, not because the assertion was widened

## 5. Verify

- [ ] 5.1 Run the full suite at least five times, since the failure is intermittent locally at roughly a fifty percent rate
- [ ] 5.2 Run a `CI=true` parity run, and check `sysctl -n vm.loadavg` first because this machine has produced misleading results at load
- [ ] 5.3 Confirm GitHub CI is green on the pushed commit, which is the authoritative signal here since the local failure rate is load-dependent
- [ ] 5.4 Confirm warm-start and subtree-rescan equivalence gates still hold
- [ ] 5.5 Confirm the protective case from 2.2 still refuses an oversized patch

## 6. Documentation

- [ ] 6.1 Record in CLAUDE.md that the mid-patch guard judges remaining work rather than completed work, and why abandoning after staging is worse than finishing
