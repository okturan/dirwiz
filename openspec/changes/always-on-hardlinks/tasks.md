# Tasks - Always-On Hardlinks

## 1. Capture (DirWizCore)

- [x] 1.1 Add `ATTR_FILE_LINKCOUNT` to the requested file attrs; extend the raw-buffer parser (link count precedes size fields; handle attr-absent case); extend the mock provider
- [x] 1.2 Parse tests: field extraction with/without link count present; sizes unaffected (regression guard)
- [x] 1.3 Add `NodeFlags.hasMultipleHardlinks` set in the shared raw-entry classification for non-directories with count > 1; bump `TreeCache.formatVersion` in the same commit; cache-rejection test (old version → nil → cold path)
- [x] 1.4 Real-filesystem test: temp tree with `link(2)` pairs → flags present after scan; warm-start splice fixture inherits flags (extend SubtreeRescan/WarmStart equivalence fixtures)

## 2. Finder fast path (DirWizCore)

- [x] 2.1 `HardlinkFinder` fast path grouping only flagged nodes when identity metadata exists; full-path fallback preserved for synthetic trees
- [x] 2.2 Equivalence test: fast path ≡ full grouping on a scanned fixture with hardlinks; timing note in PR

## 3. Auto-population and UI (DirWizUI)

- [x] 3.1 Run the finder automatically post-scan (with other post-scan analyses) and from `invalidateAfterTreeMutation`; token-guarded; results path-keyed in `HardlinkState`
- [x] 3.2 Remove the run button from `HardlinkView`; add computing + explicit empty states

## 4. Verification

- [x] 4.1 Before/after scan benchmark on a large tree confirming no measurable rate cost; record numbers
- [x] 4.2 Full suite green; CLAUDE.md scanner/cache notes updated (new attr, flag bit, version bump)
