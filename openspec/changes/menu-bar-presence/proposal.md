## Why

DirWiz is already resident-grade software with no resident surface. The living view watches
every volume continuously, warm start refreshes 4.5M items in about a second, checkpoints
record growth history, and `StorageTrends`/`WarmStartHistory` know what changed - but all of
it is only visible when the user opens a 1200×800 window. Disk fullness is ambient
information: the moments that matter ("Downloads just ate 8 GB", "under 20 GB free") happen
while the window is closed. A menu bar presence turns the machinery DirWiz already runs into
something the user glances at daily, and it is the natural home for the "keep watching after
I close the window" behavior the living view implies.

## What Changes

- A **menu bar item** (SwiftUI `MenuBarExtra`, window style) with a template glyph derived
  from the app mark, optional free-space text label, and state variants (idle, scanning,
  low-space warning). Its panel is read-only over existing state: volume gauge, free-space
  trend, top growers since the last checkpoint, the live "changing now" list from the
  monitor's accumulations, the Live pill state, and explicit actions (Open DirWiz, Scan Now,
  Take Checkpoint, pause/resume watching).
- **Residency**: closing the last window with "Keep in menu bar" enabled switches the app to
  accessory activation policy - Dock icon gone, menu bar and living view alive, caches
  advancing. Opening from the menu bar restores a regular app. Same binary and bundle
  identity, so Full Disk Access is unaffected.
- **Launch at login** via `SMAppService.mainApp`, with status surfaced honestly (approval
  states included).
- **Low-space and growth notifications** driven by a pure, clock-injected policy with
  hysteresis - one actionable notification per event, never a nag stream.
- **Automation surfaces**: App Intents (Get Free Space, Largest Files, Scan Volume, Take
  Checkpoint) exposed to Shortcuts and Spotlight; a Dock menu with recent volumes; a Finder
  Services entry ("Scan in DirWiz") for folders.
- **Settings** gains a "Menu Bar" section with named toggles wired through the injected
  defaults store.
- Explicitly OUT for this change: WidgetKit widgets, FinderSync badges, and Quick Look
  previews. All three require app-extension bundles, which the pure-SwiftPM layout and
  `package-release.sh` cannot produce today; adopting them is its own change with embedding
  and signing machinery, recorded here so the omission is a decision rather than an oversight.

## Capabilities

### New Capabilities
- `menu-bar-presence`: the resident surface - menu bar item and panel, accessory-mode
  lifecycle, login item, notification policy, and the automation surfaces (intents, Dock
  menu, Services).

### Modified Capabilities
<!-- None. The panel and intents read existing scan/monitor/checkpoint state; scanning,
warm start, and the living view are consumed, not altered. -->

## Impact

- Affected code: `DirWiz/DirWizApp.swift` (MenuBarExtra scene, activation-policy switching,
  dock menu, services registration), `Sources/DirWizUI` (panel views, Settings section),
  `Sources/DirWizCore` (pure composers and policies: menu stats snapshot, low-space
  hysteresis, intent queries over the cached tree), `DirWiz/Info.plist` (NSServices,
  usage strings).
- New frameworks, all system: ServiceManagement, UserNotifications, AppIntents. The
  zero-external-dependency rule holds.
- Tests: composers, policies, intent queries, and defaults wiring are DirWizCore/UI logic
  and get deterministic suites; UI shells stay thin. No changes to scan or splice paths.
