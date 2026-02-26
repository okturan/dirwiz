# Spec: Add "Move to Trash" to Context Menus

## Goal

Add a "Move to Trash" menu item to the right-click context menus in two places:
1. `TreeTableView` — the hierarchical file list (tab panel, upper pane)
2. `InteractiveTreemapView` — the Metal cushion treemap (lower pane)

After trashing, immediately re-trigger the volume scan so the UI reflects the deletion.
Show a confirmation alert only when the file/folder is larger than 100 MB.

---

## Files to Modify

- `/Users/okan/code/mac-graph/Sources/Views/TreeTableView.swift`
- `/Users/okan/code/mac-graph/Sources/Treemap/TreemapInteraction.swift`

Do NOT modify any other files. Do NOT add any new files.

---

## Trash API — copy this exactly

The existing trash implementation lives in
`/Users/okan/code/mac-graph/Sources/Views/DuplicateFilesView.swift`
at the `moveCheckedToTrash()` function (lines 194–212).

The single-item trash call is:

```swift
try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
```

Use this API verbatim. Do not use `NSWorkspace.shared.recycle`, shell commands, or
any other approach. `FileManager.default.trashItem` moves the item to the macOS Trash
and is always available — no extra imports are required (Foundation is already imported
transitively through SwiftUI).

---

## Rescan After Trash

There is NO `appState.rescanCurrentVolume()` or similar convenience method. The rescan
must be triggered by posting a notification that `ContentView` already observes, or by
replicating the scan sequence. The cleanest approach available without modifying
`ContentView.swift` is to post a `Notification` on the default center with the name
`.trashDidOccur` — but that would require a new observer. Because both `TreeTableView`
and `InteractiveTreemapView` only hold `@Bindable var appState: AppState` and have no
reference to `activeScanner` or the `startScan()` closure defined in `ContentView`,
the correct approach is:

**Post a `Notification` named `"DirWiz.RescanRequested"` on `NotificationCenter.default`**
immediately after the `trashItem` call succeeds (i.e., does not throw). `ContentView`
already demonstrates this pattern for search with `.searchRequested`:

```swift
// From ContentView.swift line 84:
.onReceive(NotificationCenter.default.publisher(for: .searchRequested)) { _ in
    appState.activeTab = .search
}
```

Add an analogous observer in `ContentView.swift` **only if absolutely necessary**.
However, re-read the constraint: you must NOT modify `ContentView.swift`.

Therefore, use the following alternative: trigger rescan by setting
`appState.selectedVolume` to itself (which triggers the VolumePickerView's scan button
indirectly). That also does not work without modifying ContentView.

**Correct approach without touching ContentView.swift:**

Call `appState.startScan()` — but this method does not exist on `AppState`.

The actual scan sequence from `ContentView.startScan()` (lines 302–322 of
`/Users/okan/code/mac-graph/DirWiz/ContentView.swift`) is:

```swift
private func startScan() {
    guard let volumeURL = appState.selectedVolume else { return }
    let scanner = FileScanner()
    activeScanner = scanner
    let path = volumeURL.path

    let tree = FileTree()
    appState.fileTree = tree
    appState.resetForNewScan()
    appState.activeTab = .treeView

    Task {
        await scanner.scan(path: path, progress: appState.scanProgress, tree: tree)
        await MainActor.run {
            appState.setTreemapRoot(0, recordHistory: false)
            appState.computeExtensionStats()
            activeScanner = nil
        }
    }
}
```

`FileScanner` and `FileTree` are public types from the `DirWizLib` module (already
imported via `import SwiftUI` in both target files, which transitively imports
`DirWizLib` through the module graph). Replicate this sequence inline in the trash
action closures. There is no `activeScanner` reference available in the view structs,
so omit the `activeScanner` assignment — the scanner will be owned by the `Task`
closure and released when the task completes (acceptable, since cancel support is not
needed for post-trash rescans).

**Inline rescan snippet to use in both files:**

```swift
// Rescan the current volume after trash.
if let volumeURL = appState.selectedVolume {
    let scanner = FileScanner()
    let path = volumeURL.path
    let tree = FileTree()
    appState.fileTree = tree
    appState.resetForNewScan()
    appState.activeTab = .treeView
    Task {
        await scanner.scan(path: path, progress: appState.scanProgress, tree: tree)
        await MainActor.run {
            appState.setTreemapRoot(0, recordHistory: false)
            appState.computeExtensionStats()
        }
    }
}
```

---

## Confirmation Alert — 100 MB Threshold

Show an `NSAlert` (not SwiftUI `.alert`) only when `node.fileSize > 100_000_000`
(100 MB as a round decimal threshold, consistent with the picker options shown in
`DuplicateFilesView`: 1 KB / 100 KB / 1 MB / 10 MB / 100 MB).

Use `NSAlert` directly because both context menu actions run in a Button closure inside
a `.contextMenu` modifier — SwiftUI `@State`-driven `.alert` modifiers are awkward to
attach inside context menus and require additional `@State` vars per call site. The
`NSAlert` approach is synchronous, works from the main thread, and is already the
idiomatic AppKit pattern for this use case.

```swift
// Alert helper — call this inside the Button action closure.
func confirmTrash(name: String, size: UInt64, then action: @escaping () -> Void) {
    if size > 100_000_000 {
        let alert = NSAlert()
        alert.messageText = "Move \"\(name)\" to Trash?"
        alert.informativeText = "This item is \(SizeFormatter.shared.format(size)). It will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    } else {
        action()
    }
}
```

`SizeFormatter.shared.format(_:)` is already used throughout the codebase and is
available in both files.

---

## Change 1: TreeTableView.swift

**File:** `/Users/okan/code/mac-graph/Sources/Views/TreeTableView.swift`

**Location:** The `.contextMenu` modifier inside `treeRowContainer(_:tree:)`, starting
at line 144. The current context menu contains:

```swift
.contextMenu {
    if let tree = appState.fileTree {
        let path = tree.path(at: item.id)

        Button("Reveal in Finder") {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }

        Divider()

        Button("Show in Treemap") {
            appState.showNodeInTreemap(item.id)
        }

        if item.isDirectory {
            Button("Zoom Into \"\(item.name)\"") {
                appState.setTreemapRoot(item.id)
            }
        }
    }
}
```

**Insert** a "Move to Trash" button immediately after the `Button("Copy Path")` block
and before the `Divider()`. The divider stays in its current position (between
Trash and "Show in Treemap").

**Result after change:**

```swift
.contextMenu {
    if let tree = appState.fileTree {
        let path = tree.path(at: item.id)

        Button("Reveal in Finder") {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }

        Button("Move to Trash") {
            let url = URL(fileURLWithPath: path)
            let size = tree.node(at: item.id)?.fileSize ?? 0
            confirmTrash(name: item.name, size: size) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                if let volumeURL = appState.selectedVolume {
                    let scanner = FileScanner()
                    let scanPath = volumeURL.path
                    let newTree = FileTree()
                    appState.fileTree = newTree
                    appState.resetForNewScan()
                    appState.activeTab = .treeView
                    Task {
                        await scanner.scan(path: scanPath, progress: appState.scanProgress, tree: newTree)
                        await MainActor.run {
                            appState.setTreemapRoot(0, recordHistory: false)
                            appState.computeExtensionStats()
                        }
                    }
                }
            }
        }

        Divider()

        Button("Show in Treemap") {
            appState.showNodeInTreemap(item.id)
        }

        if item.isDirectory {
            Button("Zoom Into \"\(item.name)\"") {
                appState.setTreemapRoot(item.id)
            }
        }
    }
}
```

**Also add** the `confirmTrash` helper as a private method of `TreeTableView`.
Place it at the end of the `// MARK: - Helpers` section (after `parentSize(for:tree:)`,
around line 422):

```swift
private func confirmTrash(name: String, size: UInt64, then action: @escaping () -> Void) {
    if size > 100_000_000 {
        let alert = NSAlert()
        alert.messageText = "Move \"\(name)\" to Trash?"
        alert.informativeText = "This item is \(SizeFormatter.shared.format(size)). It will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    } else {
        action()
    }
}
```

---

## Change 2: TreemapInteraction.swift

**File:** `/Users/okan/code/mac-graph/Sources/Treemap/TreemapInteraction.swift`

**Location:** The `contextMenuItems` computed property starting at line 397. The current
implementation is:

```swift
@ViewBuilder
private var contextMenuItems: some View {
    if let nodeIndex = hoveredNodeIndex ?? appState.selectedNodeIndex,
       let tree = appState.fileTree,
       let node = tree.node(at: nodeIndex) {
        let path = tree.path(at: nodeIndex)

        Button("Reveal in Finder") {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }

        if canNavigate {
            Divider()
            // ... navigation buttons ...
        }

        Divider()

        Text("\(tree.name(at: nodeIndex)) — \(SizeFormatter.shared.format(node.fileSize))")
    }
}
```

**Insert** a "Move to Trash" button immediately after the `Button("Copy Path")` block
and before the `if canNavigate {` block. The existing dividers remain in place.

**Result after change:**

```swift
@ViewBuilder
private var contextMenuItems: some View {
    if let nodeIndex = hoveredNodeIndex ?? appState.selectedNodeIndex,
       let tree = appState.fileTree,
       let node = tree.node(at: nodeIndex) {
        let path = tree.path(at: nodeIndex)

        Button("Reveal in Finder") {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }

        Button("Move to Trash") {
            let url = URL(fileURLWithPath: path)
            confirmTrash(name: tree.name(at: nodeIndex), size: node.fileSize) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                if let volumeURL = appState.selectedVolume {
                    let scanner = FileScanner()
                    let scanPath = volumeURL.path
                    let newTree = FileTree()
                    appState.fileTree = newTree
                    appState.resetForNewScan()
                    appState.activeTab = .treeView
                    Task {
                        await scanner.scan(path: scanPath, progress: appState.scanProgress, tree: newTree)
                        await MainActor.run {
                            appState.setTreemapRoot(0, recordHistory: false)
                            appState.computeExtensionStats()
                        }
                    }
                }
            }
        }

        if canNavigate {
            Divider()

            if node.isDirectory {
                Button("Zoom Into \"\(tree.name(at: nodeIndex))\"") {
                    appState.setTreemapRoot(nodeIndex)
                }
            } else if node.parentIndex != FileNode.invalid {
                Button("Zoom Into Parent Directory") {
                    if let target = progressiveZoomTarget(for: nodeIndex, tree: tree) {
                        appState.setTreemapRoot(target)
                    }
                }
            }

            if appState.canNavigateUp {
                Button("Navigate Up (Esc)") {
                    appState.navigateUp()
                }
            }

            if appState.treemapRootIndex != 0 {
                Button("Go to Root") {
                    appState.navigateHome()
                }
            }

            if appState.canNavigateBack {
                Button("Back (Cmd+[)") {
                    appState.navigateBack()
                }
            }
        }

        Divider()

        Text("\(tree.name(at: nodeIndex)) — \(SizeFormatter.shared.format(node.fileSize))")
    }
}
```

**Also add** the `confirmTrash` helper as a private method of `InteractiveTreemapView`.
Place it after the `tooltipPosition(for:in:)` method and before the
`// MARK: - Context Menu` section (around line 394):

```swift
private func confirmTrash(name: String, size: UInt64, then action: @escaping () -> Void) {
    if size > 100_000_000 {
        let alert = NSAlert()
        alert.messageText = "Move \"\(name)\" to Trash?"
        alert.informativeText = "This item is \(SizeFormatter.shared.format(size)). It will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    } else {
        action()
    }
}
```

---

## Swift Imports

No new imports are needed in either file.

- `FileManager` is in `Foundation`, already imported transitively via `SwiftUI`.
- `NSAlert` is in `AppKit`, already available on macOS when `SwiftUI` is imported
  (SwiftUI imports AppKit on macOS targets automatically).
- `FileScanner`, `FileTree`, and `SizeFormatter` are in `DirWizLib`, which is already
  the module being compiled (both files are part of the library target).
- `FileNode` is in the same module; `FileNode.invalid` is used elsewhere in both files.

---

## Verification Checklist

After implementing, verify:

1. Right-clicking any row in the Tree View shows "Move to Trash" between "Copy Path"
   and the divider before "Show in Treemap".
2. Right-clicking any rectangle in the treemap shows "Move to Trash" between "Copy Path"
   and the divider before the navigation group.
3. Right-clicking a file smaller than 100 MB and choosing "Move to Trash" trashes it
   immediately with no dialog, then rescans.
4. Right-clicking a file or folder larger than 100 MB shows the NSAlert; clicking
   "Cancel" does nothing; clicking "Move to Trash" trashes and rescans.
5. The rescan lands on the Tree View tab, treemap resets to root (index 0), and the
   new scan reflects the deletion.
6. `swift build` completes with zero errors and zero warnings.
