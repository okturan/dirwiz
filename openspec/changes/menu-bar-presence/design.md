# Design

## One state, one pipeline

The menu bar shares the SAME `@MainActor @Observable AppState` the window uses - the
`MenuBarExtra` scene sits beside the `WindowGroup` and `Settings` scenes in `DirWizApp` and
receives the identical instance. There is no second scanner, no polling loop, and no
menu-bar-owned refresh: the panel renders whatever the living view has already produced.
Opening the panel MUST cost zero filesystem work beyond one `volumeStats` statfs call.

Panel data comes from a pure composer, `MenuBarSnapshotComposer` (DirWizCore), so contents
are deterministic and testable without AppKit:

- **Gauge**: used/available/total for the displayed volume (`volumeStats`).
- **Trend**: free-space sparkline from `StorageTrends`.
- **Since last checkpoint**: the latest `CheckpointChangeSummary` from `SnapshotStore`'s
  index - already computed at checkpoint time, so reading it is free. Top growers named
  with sizes.
- **Changing now**: the top `DirectoryChangeSummary` accumulations from `FSEventsMonitor`
  (path, change count, creations/deletions flags) - the living view's raw feed, finally
  user-visible.
- **Status line**: the Live pill reason verbatim, plus scan progress when one is running.

Actions are the existing verbs, no new semantics: Open DirWiz, Full Rescan, Take Checkpoint
(pins, like the camera), pause/resume watching, Quit. Every action already exists on
AppState; the panel calls the same methods the window does.

## Icon

A template rendering of the gauge-folder mark (regenerated from `docs/assets/dirwiz-logo.svg`
per the logo pipeline), with three states: idle, scanning (SF Symbol progress overlay),
and low-space (exclamation variant). An optional text label shows free space ("104 GB"),
off by default - `MenuBarExtra`'s label view re-renders from AppState, so the number stays
live via the existing publish path. State selection is a pure function
(`MenuBarIconState.forAppState`) with tests.

## Residency and lifecycle

- New setting "Keep DirWiz in the menu bar" (default on once shipped) and "Quit closes the
  window only" behavior: when the LAST window closes and residency is on, call
  `NSApp.setActivationPolicy(.accessory)` - Dock icon and Cmd+Tab entry disappear, the
  menu bar item, FSEvents monitor, live applies, and cache writes continue. "Open DirWiz"
  in the panel restores `.regular` and opens the window via the `openWindow` action.
- Same executable, same bundle identity, no `LSUIElement` in Info.plist (the policy is
  dynamic) - Full Disk Access grants are untouched. This matters because macOS ties privacy
  grants to code identity (see CLAUDE.md's release notes).
- Termination honesty: with residency off, closing the window quits as today. Quit in the
  panel always quits. `applicationShouldTerminateAfterLastWindowClosed` reflects the setting.
- **Launch at login**: `SMAppService.mainApp.register()`/`unregister()` behind a Settings
  toggle. Surface `status` truthfully (`.requiresApproval` links to Login Items settings).
  Dev caveat recorded: registration is meaningful for the installed `/Applications` copy;
  `.build` runs may report failure - the toggle shows status rather than pretending.

## Notification policy

`LowSpacePolicy` (DirWizCore, pure, clock-injected - same pattern as `LiveRefreshPolicy` and
`WarmStartPlanner`): input is (available, total, threshold config, last-fired state, now);
output is fire/hold plus the re-arm state. Rules: fire once when available crosses below
the threshold (default 10% or 25 GB, whichever is smaller, configurable); re-arm only after
recovery above threshold + margin; never more than one notification per volume per 24h;
optional growth alert ("one folder grew more than X GB since the last checkpoint") is
off by default. Notifications are actionable (Open DirWiz) via UserNotifications; requesting
authorization happens lazily on first enable, never at launch. All persisted knobs go
through the injected defaults.

## Automation surfaces

- **App Intents** (in-app, no extension needed on macOS): `GetFreeSpaceIntent`,
  `LargestFilesIntent(count:volume:)` answered from the CACHED tree (read-only, instant,
  and honest about staleness by reporting the cache timestamp), `ScanVolumeIntent`, and
  `TakeCheckpointIntent`. Shortcuts and Spotlight surfacing; results use proper entities so
  files flow into other actions. Query logic lives in DirWizCore beside the CLI's, sharing
  its vocabulary.
- **Dock menu**: recent volumes ("Scan Macintosh HD") + Take Checkpoint, via the app
  delegate's `applicationDockMenu`.
- **Services**: "Scan in DirWiz" for folder selections in Finder (`NSServices` +
  `NSUpdateDynamicServices`), driving the existing `startScan(path:)` flow.

## Explicitly rejected / deferred

- **WidgetKit, FinderSync, Quick Look**: require embedded app-extension bundles. The repo is
  pure SwiftPM with a hand-rolled `package-release.sh`; building, embedding, signing, and
  notarizing extension bundles is real machinery and its own change. Deferred with eyes open.
- **Menu-bar-triggered background scans on a timer**: the living view already keeps data
  fresh; a timer would duplicate it and cost energy. The panel never initiates filesystem
  work by itself.
- **NSStatusItem/AppKit hand-rolling**: `MenuBarExtra(.window)` covers the need inside the
  existing SwiftUI scene lifecycle; dropping to AppKit is only justified if the label needs
  drawing the extra cannot do (revisit only with evidence).

## Testing

- `MenuBarSnapshotComposer`, `MenuBarIconState`, `LowSpacePolicy`, intent queries: pure
  DirWizCore tests, including hysteresis boundary cases with an injected clock.
- Defaults keys: wired in `AppState` init, asserted isolated from `.standard` (existing
  discipline).
- Activation-policy switching: the decision function is pure
  (`ResidencyPolicy.policyAfterLastWindowClosed(residencyEnabled:)`) and tested; the AppKit
  call is a thin shell.
- Panel and Settings views: construction + vocabulary pins, offscreen renders during
  development (cacheDisplay works - no Metal in these views).
