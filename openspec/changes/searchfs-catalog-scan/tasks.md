# Tasks - searchfs Catalog Scan

## 1. The gate: decide on numbers, on an idle machine

- [ ] 1.1 Establish an idle baseline. Confirm load average is near zero and no unrelated job
      is saturating cores, because the exploratory timings drifted 26.9 s to 54.6 s on load
      alone and every conclusion below depends on this.
- [ ] 1.2 Best-of-N, idle: full `/` coverage via searchfs (System + Data) versus the existing
      cold scan. Record wall clock, total CPU time, peak memory and thread count for both.
- [ ] 1.3 STOP CONDITION: adopt only if searchfs wins wall clock, OR ties while using
      dramatically less CPU. If it loses on both, report the numbers and stop; the exploratory
      work already proved the mechanism, so a negative result here is a real answer and closes
      the question permanently.
- [ ] 1.4 Record the same comparison on a spinning-rust or network volume if one is available,
      since a driver-side catalog walk and a traversal may diverge sharply there.

## 2. Prove the record set is trustworthy

- [ ] 2.1 Explain the ~981,000-item delta against traversal. Categorise the extra records by
      reconstructed path: inside the 358 protected directories, snapshot-only records,
      duplicate link entries, or something else. Do not proceed on the assumption that it is
      the flattering explanation.
- [ ] 2.2 Prove totals match: for a subtree both methods can see fully, assert identical file
      counts, directory counts and allocated-size totals. Any divergence is a STOP.
- [ ] 2.3 Confirm inode-shared blocks are counted once. The 50,289 duplicate file IDs are
      hardlinks; summing every record would over-report, exactly the class of bug the firmlink
      work already fixed once.
- [ ] 2.4 Confirm size attributes are reliable for both files and directories, including the
      variable-length record layout that appears when `ATTR_FILE_*` attributes are requested
      alongside directories.

## 3. Implementation (DirWizCore)

- [ ] 3.1 A `CatalogScanner` beside `FileScanner`: batch `searchfs` calls with resumable
      state, growable record storage, and the same cancellation cadence as traversal.
- [ ] 3.2 Volume discovery for the scan root, handling the System/Data pair, and skipping the
      mounts that `mount-aware-traversal` establishes are not ours to count.
- [ ] 3.3 Build `FileTree` from parent IDs: sort or bucket records so parents precede children,
      because the flat array's ordering invariant (parent index < child index) is load-bearing
      for everything downstream.
- [ ] 3.4 Preserve every downstream contract, or explain why it does not apply: firmlink
      deduplication, skipped-directory honesty, `linkCountsCaptured`, bundle deferral, live
      progressive materialisation.
- [ ] 3.5 Runtime capability check, `DIRWIZ_NO_SEARCHFS=1` escape hatch, and fallback to
      traversal on any error or implausible result.

## 4. Tests

- [ ] 4.1 Equivalence on a fixture: catalog-built tree ≡ traversal-built tree in paths, sizes,
      counts and hardlink groups.
- [ ] 4.2 Capability absent, or the syscall failing mid-batch, falls back to traversal and
      says so in the scan summary, following the warm-start reason-surfacing discipline.
- [ ] 4.3 A folder-scoped scan still uses traversal and is unaffected.
- [ ] 4.4 Mutation during the search does not corrupt the result. The exploratory run survived
      40 s of continuous create/delete with no `EBUSY`, so pin that rather than trusting it.
- [ ] 4.5 Warm-start equivalence gates still green when the cold tree came from the catalog
      path, since `TreeCache` and FSEvents replay must not care which scanner produced it.

## 5. Documentation

- [ ] 5.1 CLAUDE.md: record that APFS DOES implement `searchfs` despite the common belief,
      that it is per-volume rather than per-path, that path reconstruction from parent IDs was
      verified against `lstat`, and whichever way the gate in 1.3 resolved. A negative result
      is worth writing down permanently so it is not re-explored.
