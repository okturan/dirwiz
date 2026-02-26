# Spec: Quick Look (Space Bar) Integration

## Goal

Implement macOS Quick Look preview triggered by pressing Space when a file or directory is selected in DirWiz. Pressing Space again (or closing the QL panel) dismisses it. This mirrors standard Finder behavior.

---

## Architecture Decision: Where QL Logic Lives

### Problem: SwiftUI App lifecycle has no AppDelegate

`DirWizApp.swift` uses the SwiftUI `@main struct DirWizApp: App` lifecycle — there is no `NSApplicationDelegate` class. The `QLPreviewPanel` APIs on macOS require an object that implements two Objective-C protocols: `QLPreviewPanelDataSource` and `QLPreviewPanelController`. These cannot be placed on a SwiftUI `View` struct directly.

### Solution: A dedicated `QLPreviewCoordinator` NSObject

Create a new file `Sources/QuickLook/QLPreviewCoordinator.swift` that is an `NSObject` subclass conforming to both `QLPreviewPanelDataSource` and `QLPreviewPanelController`. This coordinator holds a weak or strong reference to whatever path should currently be previewed, and is stored as a property on `AppState` so both `TreeTableView` and `InteractiveTreemapView` can reach it via `appState`.

Do NOT use `NSViewRepresentable` as a shim for this — it is unnecessary complexity. The coordinator pattern is clean and idiomatic.

---

## New Files to Create

### 1. `Sources/QuickLook/QLPreviewCoordinator.swift`

```swift
import Quartz
import AppKit

/// Hosts the QLPreviewPanel data source / controller for the application.
/// Stored on AppState so any view can call openQuickLook() / closeQuickLook().
public final class QLPreviewCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelController {

    /// The file-system path to preview. Set this before calling openQuickLook().
    public var previewPath: String?

    // MARK: - Public API

    /// Open (or refresh) the Quick Look panel for the current previewPath.
    public func openQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.reloadData()
        } else {
            panel.dataSource = self
            panel.delegate = nil   // optional: set to self if you want delegate callbacks
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Toggle: if the panel is visible, close it; otherwise open it.
    public func toggleQuickLook(for path: String?) {
        guard let path else { return }
        previewPath = path
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            openQuickLook()
        }
    }

    // MARK: - QLPreviewPanelDataSource

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewPath != nil ? 1 : 0
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let path = previewPath else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    // MARK: - QLPreviewPanelController
    // These two methods let the panel ask the responder chain who owns it.
    // Because we are not in the responder chain, the panel is opened imperatively
    // via makeKeyAndOrderFront — no responder chain integration is needed.
    // Implement them anyway so the type fully conforms.

    public func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    public func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // nothing to tear down
    }
}
```

**Notes on the API:**

- `QLPreviewPanel.shared()` returns an optional on Swift side; always guard it.
- `QLPreviewPanel.sharedPreviewPanelExists()` is a cheap check; use it before calling `shared()` to avoid creating the panel unnecessarily.
- `NSURL` bridged from `URL` is the canonical `QLPreviewItem` for local files. Do NOT pass `URL` directly — cast to `NSURL`.
- The `delegate` can be left `nil` unless you need `QLPreviewPanelDelegate` callbacks (e.g., zoom animation source rect). Leave it `nil` for the initial implementation.

---

## Changes to Existing Files

### 2. `Sources/Models/AppState.swift`

Add an import and a new stored property for the coordinator.

**Add at top of file** (after `import SwiftUI`):
```swift
import Quartz
```

**Add one property** inside `AppState`, near the top of the public properties section (after `selectedNodeIndex` is a natural grouping since QL is selection-driven):
```swift
/// Coordinator for Quick Look panel — holds data source / controller conformance.
public let quickLookCoordinator = QLPreviewCoordinator()
```

This is a `let` because the coordinator object is stable for the app lifetime; only `previewPath` inside it changes.

**No changes needed** to `resetForNewScan()` — clearing the QL panel on new scan is not required and would be surprising UX.

### 3. `Sources/Treemap/TreemapInteraction.swift` — `InteractiveTreemapView`

The existing `onKeyPress` block at the bottom of `body` in `InteractiveTreemapView` already handles `.escape`, `.return`, `[`, `]`. Add Space directly after the `.return` handler.

**Exact insertion point** — after this block (lines 37–41 in the file as read):

```swift
        .onKeyPress(.return) {
            guard canNavigate, let sel = appState.selectedNodeIndex else { return .ignored }
            appState.setTreemapRoot(sel)
            return .handled
        }
```

**Insert immediately after:**

```swift
        .onKeyPress(.space) {
            guard let sel = appState.selectedNodeIndex,
                  let tree = appState.fileTree else { return .ignored }
            let path = tree.path(at: sel)
            appState.quickLookCoordinator.toggleQuickLook(for: path)
            return .handled
        }
```

No additional imports are needed in this file — `QLPreviewCoordinator` is accessed through `appState` which already imports Quartz in AppState.swift.

### 4. `Sources/Views/TreeTableView.swift` — `TreeTableView`

The keyboard handlers in `TreeTableView` are attached to the `ScrollView` inside `treeContent(tree:)` via a chain of `.onKeyPress` modifiers (lines 55–70 in the file as read). The `ScrollView` is already `.focusable()` and managed by `@FocusState private var isFocused`.

**Exact insertion point** — after the existing `.onKeyPress(.rightArrow)` block (currently the last key handler on the ScrollView):

```swift
                .onKeyPress(.rightArrow) {
                    expandOrGoFirstChild(tree: tree, proxy: proxy)
                    return .handled
                }
```

**Insert immediately after:**

```swift
                .onKeyPress(.space) {
                    guard let sel = appState.selectedNodeIndex,
                          let tree = appState.fileTree else { return .ignored }
                    let path = tree.path(at: sel)
                    appState.quickLookCoordinator.toggleQuickLook(for: path)
                    return .handled
                }
```

The `tree` local in `treeContent(tree:)` is the same tree, but use `appState.fileTree` via the optional chain above for consistency with how the coordinator retrieves the path (avoids a subtle bug if tree becomes nil between the guard and path resolution).

---

## Package.swift Changes

### Does Quartz need to be added?

**Yes, for `DirWizLib`.** Quartz is a system framework on macOS (it is part of the SDK, not a third-party package), but SPM requires it to be declared explicitly in `linkerSettings` to be linked.

`QLPreviewCoordinator.swift` lives in `Sources/` which compiles into the `DirWizLib` target. The `DirWizLib` target in `Package.swift` already has a `linkerSettings` block:

```swift
linkerSettings: [
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("AppKit"),
]
```

**Add `Quartz` to that list:**

```swift
linkerSettings: [
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("AppKit"),
    .linkedFramework("Quartz"),
]
```

The `DirWiz` executable target does not need a separate `linkerSettings` entry because it links `DirWizLib` which already pulls in Quartz.

---

## File Layout Summary

```
Sources/
  QuickLook/
    QLPreviewCoordinator.swift      <- NEW
  Models/
    AppState.swift                  <- add `import Quartz`, add `quickLookCoordinator` property
  Treemap/
    TreemapInteraction.swift        <- add .onKeyPress(.space) handler
  Views/
    TreeTableView.swift             <- add .onKeyPress(.space) handler
Package.swift                       <- add .linkedFramework("Quartz") to DirWizLib linkerSettings
```

---

## Behavior Spec

| Condition | Result |
|---|---|
| No selection (`appState.selectedNodeIndex == nil`) | Space is ignored (`.ignored` returned) |
| Selection set, QL panel closed | Panel opens, previews selected item |
| Space pressed again while panel is open | Panel closes |
| User clicks X to close QL panel | Panel closes normally (no extra handling needed) |
| Selection changes while panel is open | Panel does NOT auto-update — user must re-press Space. This is acceptable for v1. |
| Selected node is a directory | QL shows the folder preview (Finder-style icon/contents grid) — this works natively with `QLPreviewPanel` |
| Node index is out of bounds | `tree.path(at: sel)` returns empty string or crashes — guard: if `path.isEmpty { return .ignored }` |

**Edge case guard:** In `toggleQuickLook`, before calling `openQuickLook`, add:
```swift
guard !path.isEmpty else { return }
```
This is already handled by the `guard let path` in the public function, but add an explicit check for empty string as well, since `FileTree.path(at:)` could theoretically return `""` for an invalid index rather than crashing.

---

## Known Risk: QLPreviewPanelController Responder Chain

`QLPreviewPanelController` is normally adopted by an object in the NSResponder chain (e.g., a window controller or view). When the QL panel is opened via `makeKeyAndOrderFront`, it walks the responder chain looking for an object that returns `true` from `acceptsPreviewPanelControl`. Because `QLPreviewCoordinator` is NOT in the responder chain, the panel may fall back to a default data source (empty preview) on some macOS versions.

**Mitigation already in the spec:** We set `panel.dataSource = self` explicitly on the coordinator *before* calling `makeKeyAndOrderFront`. This bypasses the responder chain entirely for our use case. On macOS 13+, this is well-established and reliable. On older versions there may be edge cases where the panel resets its data source after display — if that occurs, implement `acceptsPreviewPanelControl` on the window via `NSWindow` subclass or `NSWindowController` instead.

For the initial implementation, the imperative `panel.dataSource = self` approach is sufficient and should be tried first before adding responder chain complexity.

---

## Explicit Non-Goals (do NOT implement)

- Do NOT integrate with the NSResponder chain (`acceptsPreviewPanelControl` / `beginPreviewPanelControl` on the window). The imperative `makeKeyAndOrderFront` approach is sufficient and avoids AppKit complexity in a SwiftUI app.
- Do NOT add a toolbar button for Quick Look. Space bar is the standard macOS convention.
- Do NOT auto-refresh the QL panel when `appState.selectedNodeIndex` changes. The user controls the panel explicitly.
- Do NOT add a menu item for Quick Look in this pass.

---

## Verification Steps After Implementation

1. `swift build` must succeed with no errors — confirm `import Quartz` resolves and `QLPreviewPanel`, `QLPreviewItem` are found.
2. `swift run DirWiz` — scan any directory, click a file in TreeTableView, press Space — QL panel opens.
3. Press Space again — QL panel closes.
4. Click a file in the treemap (InteractiveTreemapView), press Space — QL panel opens.
5. Press Escape (navigate up) while QL is open — navigation works, QL stays open (they are independent).
6. QL panel for a directory — should show a folder preview grid, not crash.
7. No selection + Space — nothing happens, no crash.
