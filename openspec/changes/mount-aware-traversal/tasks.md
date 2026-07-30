# Tasks - Mount-Aware Traversal

## 1. Establish the baseline honestly

- [ ] 1.1 Record, on this machine, the current `/` scan total against the volume's real
      capacity from `statfs`, and the item count. The gap is what this change closes; it must
      be a recorded number, not a claim.
- [ ] 1.2 Enumerate the mounts currently under `/` with their device numbers, and note which
      the rule will exclude. Re-check with Simulator runtimes mounted, since that is the case
      the 477,845-entry measurement came from.

## 2. The rule (DirWizCore)

- [ ] 2.1 Capture the scan root's device once per scan, beside the existing per-scan setup
      (where `resolveFirmlinkDuplicates` already runs).
- [ ] 2.2 Skip enqueueing a directory whose device differs. Fold it into
      `VisitedDirectories.shouldTraverse(path:dev:inode:)`, which already owns exactly this
      kind of decision, rather than threading a new parameter through every enumeration
      signature.
- [ ] 2.3 Do NOT mark a skipped mount's inode as visited, mirroring the firmlink decision:
      marking it would trade a double count for a silent omission if the same inode is
      reachable another way.
- [ ] 2.4 Honour `DIRWIZ_CROSS_MOUNTS=1`, and fail open when the root device is unknown.
- [ ] 2.5 Apply it in BOTH `scan` and `rescanSubtrees`. A rule present in one and absent from
      the other breaks the warm-start equivalence gate the moment a mount changes, which is
      exactly the trap the firmlink change documented.

## 3. Surfacing (DirWizCore + DirWizUI)

- [ ] 3.1 Count skipped mounts and their paths in `ScanProgress`, alongside the existing
      skipped-directory bookkeeping.
- [ ] 3.2 Report them in the sidebar in the same quiet register as the protected-folders
      line, naming what was not descended into and why. Wording must make clear this is a
      deliberate exclusion, not a permission failure, because those are different problems
      with different fixes.

## 4. Tests

- [ ] 4.1 Same-device traversal is unchanged: a fixture scan with no mounts produces
      byte-identical totals and paths before and after.
- [ ] 4.2 A foreign device is skipped and reported. Use an injection seam for the device
      number rather than requiring a real mount, following the `firmlinkDuplicates` test seam
      precedent (a real mount cannot be created in a unit test).
- [ ] 4.3 Rooting the scan AT the foreign device scans it fully: the rule is relative to the
      scan root.
- [ ] 4.4 The volume group survives: a fixture standing in for `/` plus a same-device
      `/System/Volumes/Data` still traverses both.
- [ ] 4.5 `DIRWIZ_CROSS_MOUNTS=1` reproduces pre-change behaviour exactly.
- [ ] 4.6 Warm-start equivalence gates still green: patched tree ≡ fresh cold scan under the
      new rule.

## 5. Verification

- [ ] 5.1 Re-run 1.1 and report the before/after totals against `statfs`. The remaining gap
      should be only the documented clone/hardlink block sharing.
- [ ] 5.2 Report the cold-scan time change, both with and without Simulator runtimes
      mounted, so the conditional saving is stated rather than averaged into a single figure.
- [ ] 5.3 CLAUDE.md: record why same-device works here while it cannot catch firmlinks, so
      the two mechanisms are not later mistaken for redundant.
