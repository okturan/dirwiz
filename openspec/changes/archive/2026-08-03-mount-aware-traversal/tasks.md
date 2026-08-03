# Tasks - Mount-Aware Traversal and Explicit Combined View

## 1. Establish the baseline honestly

- [x] 1.1 Record the pooled `/` result: 6.27 TB and 5,889,027 cached items versus a
      995 GB selected root filesystem.
- [x] 1.2 Record live device identities for `/`, the Data volume, Update, and a mounted
      Simulator runtime; do not invent an external-drive device ID after it was unplugged.
- [x] 1.3 Confirm the product mechanism: `VisitedDirectories` deduplicates `(device, inode)`
      but never rejects a foreign device, and living refresh reuses the same unrestricted
      subtree staging path.

## 2. Specify the product decision

- [x] 2.1 Make individual-volume traversal the default and keep the mount point visible.
- [x] 2.2 Add an explicit combined choice only when two or more eligible local volumes exist.
- [x] 2.3 Pin hot-plug behavior: refresh availability without changing selection or scope.
- [x] 2.4 Make combined selection session-only so relaunch cannot silently pool drives.
- [x] 2.5 Include scope in displayed-tree ownership and cache identity.

## 3. Core traversal and persistence

- [x] 3.1 Add a sendable mount-traversal scope and store it on `FileTree` before nodes are added.
- [x] 3.2 Capture the scan-root device once and fold the relative-device decision into
      `VisitedDirectories`, preserving firmlink-first and no-mark-on-skip behavior.
- [x] 3.3 Apply the gate to provider and raw cold-scan paths, including opaque bundle roots.
- [x] 3.4 Apply the tree-owned gate to warm and living subtree rescans, including when the
      excluded mount is itself a changed root.
- [x] 3.5 Preserve `DIRWIZ_CROSS_MOUNTS=1` and fail open when root identity is unavailable.
- [x] 3.6 Add separate skipped-mount counters and sampled paths to `ScanProgress`.
- [x] 3.7 Bump TreeCache to v3, encode/decode scope, and key cache files by root plus scope.
- [x] 3.8 Scope-qualify checkpoints, session navigation, and scan diagnostics; do not record a
      combined tree as the boot volume's single-volume capacity trend.

## 4. Product UI

- [x] 4.1 Add an **All Volumes** row with friendly count/explanation, shown only for 2+ volumes.
- [x] 4.2 Selecting an individual row clears combined mode; selecting **All Volumes** uses `/`
      with combined traversal.
- [x] 4.3 Refresh the list on mount/unmount without changing a still-valid selection.
- [x] 4.4 Show aggregate capacity for the combined selection and fall back safely when the
      combined option disappears.
- [x] 4.5 Extend the one state-driven scan control so path plus scope decide normal scan versus
      Full Rescan, with explicit **Scan All Volumes** copy.
- [x] 4.6 Surface excluded mounts separately from Full Disk Access skips and point to the
      combined option when available.

## 5. Tests

- [x] 5.1 Same-device traversal, including a Data-volume stand-in, is unchanged.
- [x] 5.2 A foreign device is retained as an empty mount point, excluded from totals, and reported.
- [x] 5.3 Scanning at the foreign device root includes its contents.
- [x] 5.4 Combined and diagnostic unrestricted modes include foreign contents.
- [x] 5.5 Unknown root device fails open.
- [x] 5.6 A foreign changed root cannot bypass the warm/living gate, and warm equals cold.
- [x] 5.7 Scope round-trips in TreeCache; wrong-scope lookup and v2 cache reuse fail closed.
- [x] 5.8 Volume-control tests pin combined availability, ownership, action copy, and callbacks.
- [x] 5.9 Existing ScanSupervisionTests remain green without weakening named assertions.

## 6. Repository workflow and verification

- [x] 6.1 Add the CLAUDE.md rule: finish user-facing work with a local app build/install and
      verify it, while never publishing that local artifact without separate release authority.
- [x] 6.2 Record why same-device mount filtering and firmlink deduplication are complementary.
- [x] 6.3 Run `openspec validate mount-aware-traversal --strict`.
- [x] 6.4 Run focused mount/cache/UI tests, the full suite, and `CI=true` parity.
- [x] 6.5 Build the local app bundle, install/relaunch it for this user, and verify the running
      executable is the just-built binary. Do not upload or modify a GitHub release.
- [x] 6.6 With a second physical volume attached, verify individual totals stay isolated and
      **All Volumes** combines only after explicit selection. If no second volume is available,
      leave this manual hardware gate open rather than claiming it.

## 7. Reproduce the disconnect lifecycle defect

- [x] 7.1 Confirm the mount-refresh path changes `selectedVolume` without reconciling `fileTree`
      or starting work for the fallback owner.
- [x] 7.2 Confirm launch restore returns early for a remembered path that is no longer mounted,
      after which volume discovery can select another row while the graph stays empty.
- [x] 7.3 Record the current hardware boundary: no external physical disk is mounted, so use
      deterministic availability inputs rather than claiming a live hot-unplug reproduction.

## 8. Specify availability recovery

- [x] 8.1 Keep a valid individual selection unchanged across unrelated mount-list changes.
- [x] 8.2 Prefer `/`, then stable normalized-path order, for an individual fallback.
- [x] 8.3 Restore only the fallback's exact individual cache; otherwise start a visible scan.
- [x] 8.4 Never relabel a missing-volume or combined tree as the fallback, and do not persist
      fallback ownership until its scan succeeds.

## 9. Implement one recovery transition

- [x] 9.1 Extract a pure availability policy covering valid selection, missing individual,
      unavailable combined choice, remembered missing path, and zero-volume defense.
- [x] 9.2 Route initial, manual, mount, and unmount volume-list refreshes through `AppState`.
- [x] 9.3 Publish an exact fallback cache and auto-refresh it, or automatically start the
      fallback's individual scan when no valid cache exists.
- [x] 9.4 Supersede unavailable-target scan work, defer behind an already-committing living splice,
      and never change a still-valid target on hot-plug.

## 10. Regression tests and delivery

- [x] 10.1 Pin the pure fallback order and every no-recovery/recovery decision.
- [x] 10.2 Pin launch with a remembered missing volume and a cached fallback.
- [x] 10.3 Pin hot-unplug recovery for both an individual selection and a disappearing combined
      choice, including the no-cache automatic-scan path.
- [x] 10.4 Run strict OpenSpec validation, focused tests, the full suite, and `CI=true` parity.
- [x] 10.5 Build, install, relaunch, and verify the local app from the final clean tracked source;
      do not publish or alter the public release.
- [x] 10.6 Make fallback ownership persistence precede the AppState-visible cold-scan completion
      boundary, with a deterministic scanner-level gate and full-suite coverage.

### Closure (2026-08-03)
6.6's hardware gate was satisfied in production use: the Samsung8TB volume was scanned repeatedly on Aug 1-2 with its own isolated cache, history, and totals (WarmStartHistory per-volume files), individual scans report mounted filesystems kept separate in the sidebar, and combined selection remains an explicit All Volumes action pinned by MountAwareTraversalTests.
