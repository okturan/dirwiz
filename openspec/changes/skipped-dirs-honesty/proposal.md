# Skipped Directories Honesty

## Why

Even with Full Disk Access granted, macOS always denies a handful of SIP-protected directories — so every user permanently sees an alarming orange "N directories unreadable" warning whose tooltip tells them to enable FDA they already have. Only a count is kept; the actual paths vanish into os_log. An unfixable warning erodes trust; an explained one builds it.

## What Changes

- `ScanProgress` records the skipped directory paths (capped list of 100; the count stays exact beyond the cap) alongside the existing counter, reset per scan; splice/warm paths feed the same recording.
- Presentation becomes FDA-aware:
  - **FDA granted** → quiet secondary styling: "N system-protected folders skipped", clickable → popover listing the paths with the explanation that macOS protects these even from Full Disk Access apps and every disk tool skips them. No FDA call-to-action.
  - **FDA missing** → warning styling folded together with the existing FDA banner (one alarm, one action), not a second independent warning.
- The misleading always-suggest-FDA tooltip is removed.

## Capabilities

### New Capabilities
- `skipped-directories-reporting`: path recording semantics and the FDA-aware presentation rules.

### Modified Capabilities
None — no baseline specs exist yet.

## Impact

- **DirWizCore**: `ScanProgress` hot-counter struct gains the capped path list (mutex-guarded, published like other counters); both `incrementSkippedDirectories` call sites pass the path.
- **DirWizUI**: `ContentView.scanSummary` block replaced with the two-styling presentation + popover; FDA banner integration.
- **Tests**: recording/cap/reset tests; presentation logic extracted testably (which style for which FDA state).
