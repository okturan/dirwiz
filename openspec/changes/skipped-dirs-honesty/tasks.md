# Tasks - Skipped Directories Honesty

## 1. Recording (DirWizCore)

- [x] 1.1 Extend `ScanProgress` hot struct with capped skipped-path list; `incrementSkippedDirectories(path:)`; publish + reset wiring
- [x] 1.2 Update both scanner call sites (legacy + raw) and the rescan/splice path to pass the path
- [x] 1.3 Tests: recording, cap-with-exact-count, reset per scan, concurrent increments under the mutex

## 2. Presentation (DirWizUI)

- [x] 2.1 `SkippedDirsPresentation` pure styling rule (fdaGranted × count → quiet/fdaWarning/hidden) with unit tests
- [x] 2.2 Quiet state: secondary-styled line + popover (path list, explanation copy, middle truncation, copyable); remove the old orange line and misleading tooltip
- [x] 2.3 FDA-missing state: fold skip count into the existing FDA banner detail line
- [x] 2.4 Screenshot pass of both states (per design-taste memory: iterate on real screenshots)

## 3. Verification

- [x] 3.1 Full suite green; CLAUDE.md untouched (no invariant changes) - confirm
