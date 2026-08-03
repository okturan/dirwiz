## 1. Foundations (pure, tested, no UI)

- [x] 1.1 `MenuBarSnapshotComposer` in DirWizCore: gauge, trend, latest checkpoint summary,
  top changing-now accumulations, and status line from injected inputs; deterministic tests.
- [x] 1.2 `MenuBarIconState.forAppState`: idle/scanning/low-space selection as a pure
  function with tests.
- [x] 1.3 `LowSpacePolicy`: clock-injected hysteresis (threshold, re-arm margin, per-volume
  daily cap) with boundary tests, following the `LiveRefreshPolicy` pattern.
- [x] 1.4 `ResidencyPolicy.policyAfterLastWindowClosed` plus new defaults keys wired through
  `AppState` init, with the isolated-suite persistence test extended.

## 2. Menu bar item and panel

- [x] 2.1 Add the `MenuBarExtra(.window)` scene sharing the existing `AppState`; template
  glyph regenerated from the logo pipeline; optional free-space label behind its setting.
- [x] 2.2 Panel UI: gauge, trend sparkline, since-last-checkpoint growers, changing-now list,
  Live status line, and the action row (Open DirWiz, Scan Now, Take Checkpoint,
  pause/resume, Quit) calling existing AppState verbs only.
- [x] 2.3 Offscreen renders of the panel states (idle, scanning, low-space) reviewed before
  install; vocabulary and construction pins in tests.

## 3. Residency and login

- [x] 3.1 Activation-policy switching on last-window-close per `ResidencyPolicy`; Open DirWiz
  restores `.regular` and the window; Quit always terminates; verify FDA is untouched by
  mode changes on the installed app.
- [x] 3.2 Launch-at-login toggle via `SMAppService.mainApp` with truthful status display,
  including the approval-required path.
- [x] 3.3 Settings gains the "Menu Bar" section: show item, free-space label, residency,
  login item, alert threshold.

## 4. Notifications

- [x] 4.1 UserNotifications integration behind `LowSpacePolicy`: lazy authorization on first
  enable, actionable Open DirWiz, per-volume re-arm state persisted via injected defaults.
- [x] 4.2 Optional growth alert (off by default) fed by checkpoint summaries.

## 5. Automation surfaces

- [x] 5.1 App Intents: Get Free Space, Largest Files (cached-tree query with cache-age in
  the result), Scan Volume, Take Checkpoint; query logic in DirWizCore with tests; verify
  Shortcuts and Spotlight surfacing on the installed app.
- [x] 5.2 Dock menu with recent volumes and Take Checkpoint.
- [x] 5.3 Finder Services entry ("Scan in DirWiz") driving `startScan(path:)`; Info.plist
  NSServices registration.

## 6. Delivery

- [x] 6.1 Run focused, full, `CI=true`, strict OpenSpec, and diff hygiene verification.
- [ ] 6.2 Commit, install, relaunch, and exercise natively: panel contents against the real
  living view, accessory-mode residency across a window close, a real low-space simulation,
  and at least one intent from Shortcuts.
- [x] 6.3 Update CLAUDE.md with the residency/notification landmines learned during
  implementation.
