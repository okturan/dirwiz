# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
swift build                          # debug build
swift test                           # full suite (swift-testing, ~260 tests, sub-second after build)
swift test --filter "TreeActions"    # one suite; also --filter "SuiteName/testFunctionName"
./scripts/package-release.sh         # release .app bundle + zip → dist/ (version from DirWiz/Info.plist)
.build/debug/dirwiz-cli scan <path> [--json] [--min-size N] [--max-depth N] [-q]
.build/debug/dirwiz-cli duplicates|info|benchmark|snapshot|diff <path>
```

CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on `macos-15` for pushes to master and PRs.

Release script notes: signs with the first local Apple identity found, else ad-hoc (`DIRWIZ_CODESIGN_IDENTITY` overrides; `DIRWIZ_DIST_DIR` overrides output dir). Grant Full Disk Access to the installed `/Applications/DirWiz.app`, never to `.build` binaries — ad-hoc rebuilds can lose FDA because macOS ties privacy grants to code identity.

## Targets and layering

SwiftPM, swift-tools 6.0, **all targets pinned to Swift 5 language mode** (the test target is not pinned and compiles under Swift 6). macOS 15+. Zero external dependencies — keep it that way.

- `Sources/DirWizCore` — scanner, file tree, duplicate/hardlink detection, analyzers, temporal diff, CLI argument parsing. No UI imports.
- `Sources/DirWizUI` — `AppState` + SwiftUI views + Metal cushion treemap.
- `DirWiz/` (app) and `CLI/` (dirwiz-cli) are executable targets. **The test target can only import DirWizCore and DirWizUI** — logic that needs tests must live in DirWizCore, not the executables (pattern: `CLIArguments.swift`, `TemporalDiffSummary.swift`).

## The file tree — core invariants

`FileTree` (Sources/DirWizCore/Scanner/FileNode.swift) is a flat array of packed `FileNode` structs plus a shared string pool. Everything depends on these rules:

- Nodes reference each other by index (`parentIndex`, `firstChildIndex` + `childCount` = one contiguous child slice). Parent index < child index for any real scan.
- Nodes are appended, never removed — **except `removeSubtree`, which compacts the array and renumbers every index**. Any index held across that call is garbage. That is why:
  - `TreeActions.batchTrash(paths:tree:)` re-resolves each path against the current tree immediately before trashing it; the index-based `batchTrash(nodeIndices:)` is only safe for a single index.
  - After any mutating action, `AppState.invalidateAfterTreeMutation()` (AppState+Analysis.swift) is the single reset point: it clears all index-keyed state (search results, recency factors, temporal-diff arrays) and bumps the treemap layout revision via `scanProgress.publishCounters(forceLayoutRevision: true)`. The treemap only relayouts on tree identity / root index / revision changes — forget the bump and it silently renders stale rects with wrong node indices.
- `FileTree` is `@unchecked Sendable` guarded by an internal mutex. Read through `node(at:)`, `nodesSnapshot()`, `pathBuildingSnapshot()` — do not read `.nodes` directly from concurrent contexts.
- Post-scan analyzers walk snapshots via `FileTree.forEachFileInSnapshot` (single blessed walk with a uniform cancellation cadence) and locate nodes by path components via `FileTree.descendPath`. Do not hand-roll a new whole-tree loop in an analyzer.

## Scanner

`getattrlistbulk` raw-buffer parsing with unsafe pointers (`FilesystemProvider.swift`, hot paths in `FileScanner.swift`). Symlinks are intentionally skipped. The app path defers bundle sizing to a background pass so first paint is fast; the CLI sizes bundles inline. Env knobs: `DIRWIZ_SCAN_WORKERS`, `DIRWIZ_DEFER_TREE`, `DIRWIZ_SKIP_BUNDLE_SIZES`, `DIRWIZ_BUNDLE_WORKERS`, `DIRWIZ_BULK_BUFFER_BYTES`, `DIRWIZ_NO_WARM_START`.

**Warm start** (GUI only; CLI scans stay cold): completed scans persist the tree + FSEvents event id via `TreeCache` (fail-closed binary format — ANY doubt on load returns nil and falls back to a cold scan; any change to `FileNode`'s stored layout MUST bump the cache `formatVersion`). On the next scan, `WarmStart.swift` replays the FSEvents journal since the saved id and `FileScanner.rescanSubtrees` splices only the changed directories into the loaded tree (`removeChildren(of:)` + immediate-mode re-enumeration + `recomputeAggregates()`, which resets non-bundle dir totals then re-sums — never call `propagateSizes()` on an already-propagated tree, it double-counts). Poison flags (MustScanSubDirs/IdsWrapped/RootChanged/Mount), replay timeout, unresolvable paths, or >5k changed dirs all abandon warm and run the unchanged cold path. Equivalence tests (`Tests/SubtreeRescanTests.swift`, `Tests/WarmStartTests.swift`) pin patched-tree ≡ fresh-cold-scan; keep that gate when touching any of this.

## UI state model

`AppState` and its sub-models (`DuplicateState`, `SearchState`, `NavigationState`, `TemporalDiffState`) are all `@MainActor @Observable`. Background work runs in `Task.detached` and hops back via `MainActor.run` guarded by token counters (`scanToken`, `duplicateToken`, …) — always check the token before writing results so a stale task can't clobber a newer scan. `resetForNewScan()` is the canonical list of per-scan state; new state must be added there.

Tree-table column geometry comes from the shared `TreeTableColumns` constants (TreeRow.swift) — header and rows must consume the same values or columns drift per row.

## Destructive actions

Everything goes to Trash via `TreeActions` → `FileManager.trashItem` — never delete. Duplicate cleanup byte-verifies before trashing (`DuplicateContentVerifier`, opens with `O_NOFOLLOW`) and only proceeds when an unselected byte-identical copy survives. `applyPreset` fails closed: `[]` means "do nothing", and callers must treat it that way. When touching `trashItem` bridging: use the compiler-managed `&nsurlVar` writeback in a synchronous helper — a hand-built `AutoreleasingUnsafeMutablePointer` over strong storage over-releases at pool pop in async contexts (this crashed in production once already; see `performTrash`).

## Temporal snapshots

Binary `.tdiff` (v2, with v1/legacy-JSON decode support) under Application Support `DirWiz/Snapshots`, keyed by exact root-path string; `DIRWIZ_APP_SUPPORT_DIR` overrides the location (used by tests). GUI and CLI (`snapshot`/`diff` subcommands) share the same files.

## Testing conventions

swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`/`#require`) — not XCTest. Real-filesystem fixtures via `createTempTree` (Tests/TestHelpers.swift); tree shapes a real scan can't produce are hand-built through `@testable` internals (`setRootPath`/`addNode`/`addChildren`). Tests run in parallel; `TemporalDiffTests` mutates the process-global `DIRWIZ_APP_SUPPORT_DIR` via `setenv` — the first suspect if CI flakes intermittently (fix: `.serialized` on that suite). When refactoring an analyzer or scan path, write characterization tests pinning current outputs *before* the refactor (pattern: `Tests/AnalyzerWalkTests.swift`).
