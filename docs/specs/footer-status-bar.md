# Spec: Footer Status Bar

Implement a thin footer status bar at the bottom of the main window in the DirWiz macOS disk analyzer app.

## Overview

Add a 22pt-tall footer bar below the entire `NavigationSplitView` in `ContentView.swift`. The bar shows:
- Left side: full path of the currently selected node (truncated from the head if long)
- Right side: scan duration in seconds and total item count

This requires two new properties on `AppState` to track scan duration, and a small layout change in `ContentView`.

---

## Files to modify

1. `/Users/okan/code/mac-graph/Sources/Models/AppState.swift`
2. `/Users/okan/code/mac-graph/DirWiz/ContentView.swift`

Do NOT modify any other files.

---

## Change 1: AppState.swift — add scan timing properties

### Context

`AppState` is an `@Observable` class defined in `/Users/okan/code/mac-graph/Sources/Models/AppState.swift`.

The scan is initiated from `ContentView.startScan()` (in `ContentView.swift`, not in `AppState.swift`). Inside `startScan()`, `appState.resetForNewScan()` is called before the `Task` block, and then `scanner.scan(path:progress:tree:)` is awaited. When the `await` returns, the scan is complete and the main-actor block runs `appState.setTreemapRoot(0, recordHistory: false)` and `appState.computeExtensionStats()`.

The scan duration is currently tracked only inside `FileScanner.scan()` as a local variable (`totalElapsed`) and written into `ScanProgress.elapsedTime`. We want to also store the final elapsed time directly on `AppState` so the footer can read it without going through `scanProgress`.

### What to add

Add two new public stored properties to `AppState`. Insert them directly after the `isSnapshotBuilding` property declaration (line 66 in the current file). The surrounding context at the insertion point is:

```swift
    /// Whether a snapshot save/build is in progress.
    public var isSnapshotBuilding: Bool = false

    /// Bumped each time diff results are applied (GPU change detection).
    public var temporalDiffGeneration: UInt64 = 0
```

Insert the two new properties between `isSnapshotBuilding` and `temporalDiffGeneration`:

```swift
    /// Whether a snapshot save/build is in progress.
    public var isSnapshotBuilding: Bool = false

    // MARK: - Scan Timing

    /// Wall-clock time when the most recent scan started (CFAbsoluteTime).
    public var scanStartTime: CFAbsoluteTime = 0

    /// Total elapsed seconds for the last completed scan. Zero if no scan has finished yet.
    public var scanDuration: TimeInterval = 0

    /// Bumped each time diff results are applied (GPU change detection).
    public var temporalDiffGeneration: UInt64 = 0
```

Also add `scanDuration = 0` and `scanStartTime = 0` to the `resetForNewScan()` method. The current body of `resetForNewScan()` ends with:

```swift
        temporalDiffToken &+= 1
    }
```

Insert the two resets just before the closing brace of `resetForNewScan()`:

```swift
        temporalDiffToken &+= 1
        scanStartTime = 0
        scanDuration = 0
    }
```

---

## Change 2: ContentView.swift — record timing and add footer

### Context

`ContentView` is defined in `/Users/okan/code/mac-graph/DirWiz/ContentView.swift`.

The `body` property currently returns a bare `NavigationSplitView` with a toolbar attached. There is NO wrapping `VStack` at the top level of `body`. The full current `body` is:

```swift
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
        } detail: {
            detailContent
        }
        .navigationTitle("")
        .toolbar {
            // ... toolbar items ...
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchRequested)) { _ in
            appState.activeTab = .search
        }
    }
```

### Step 2a: Record scan timing in `startScan()`

The `startScan()` method is at the bottom of `ContentView.swift`. Its current body is:

```swift
    private func startScan() {
        guard let volumeURL = appState.selectedVolume else { return }
        let scanner = FileScanner()
        activeScanner = scanner
        let path = volumeURL.path

        // Create tree upfront so the UI can observe it growing during scan.
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

Replace it with:

```swift
    private func startScan() {
        guard let volumeURL = appState.selectedVolume else { return }
        let scanner = FileScanner()
        activeScanner = scanner
        let path = volumeURL.path

        // Create tree upfront so the UI can observe it growing during scan.
        let tree = FileTree()
        appState.fileTree = tree
        appState.resetForNewScan()
        appState.activeTab = .treeView
        appState.scanStartTime = CFAbsoluteTimeGetCurrent()

        Task {
            await scanner.scan(path: path, progress: appState.scanProgress, tree: tree)
            await MainActor.run {
                appState.scanDuration = CFAbsoluteTimeGetCurrent() - appState.scanStartTime
                appState.setTreemapRoot(0, recordHistory: false)
                appState.computeExtensionStats()
                activeScanner = nil
            }
        }
    }
```

Note: `CFAbsoluteTimeGetCurrent()` is available without any import in Swift on Apple platforms (it comes from `CoreFoundation` which is implicitly bridged). No new import is needed.

### Step 2b: Wrap `body` in a `VStack` and add the footer

Replace the entire `body` computed property. The new `body` wraps everything in a `VStack(spacing: 0)` so the footer can sit below the `NavigationSplitView`.

Current `body`:

```swift
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
        } detail: {
            detailContent
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    // Recency heatmap spinner + toggle
                    if appState.isRecencyQueryRunning {
                        ProgressView()
                            .controlSize(.small)
                            .help("Querying Spotlight for file recency…")
                    }
                    Toggle(isOn: Binding(
                        get: { appState.isRecencyOverlayEnabled },
                        set: { enabled in
                            appState.isRecencyOverlayEnabled = enabled
                            if enabled { appState.startRecencyQueryIfNeeded() }
                        }
                    )) {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .help("Recency Heatmap — dim files unused for 2+ years (Cmd+Opt+R)")
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(!appState.scanProgress.scanComplete)

                    Divider().frame(height: 16)

                    // Take Snapshot
                    if appState.isSnapshotBuilding {
                        ProgressView()
                            .controlSize(.small)
                            .help("Saving snapshot…")
                    } else {
                        Button {
                            appState.takeSnapshot()
                        } label: {
                            Image(systemName: "camera")
                        }
                        .help("Take Snapshot for Temporal Diff (Cmd+Opt+S)")
                        .keyboardShortcut("s", modifiers: [.command, .option])
                        .disabled(!appState.scanProgress.scanComplete)
                    }

                    // Temporal Diff toggle
                    Toggle(isOn: Binding(
                        get: { appState.isTemporalDiffEnabled },
                        set: { enabled in
                            appState.isTemporalDiffEnabled = enabled
                            if enabled { appState.startTemporalDiff() }
                        }
                    )) {
                        Image(systemName: "timelapse")
                    }
                    .help("Temporal Diff — highlight changes since snapshot (Cmd+Opt+D)")
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(!appState.scanProgress.scanComplete || appState.temporalSnapshot == nil)
                }
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showLegend) {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Toggle Legend (Cmd+Opt+L)")
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchRequested)) { _ in
            appState.activeTab = .search
        }
    }
```

Replace with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
            } detail: {
                detailContent
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 6) {
                        // Recency heatmap spinner + toggle
                        if appState.isRecencyQueryRunning {
                            ProgressView()
                                .controlSize(.small)
                                .help("Querying Spotlight for file recency…")
                        }
                        Toggle(isOn: Binding(
                            get: { appState.isRecencyOverlayEnabled },
                            set: { enabled in
                                appState.isRecencyOverlayEnabled = enabled
                                if enabled { appState.startRecencyQueryIfNeeded() }
                            }
                        )) {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .help("Recency Heatmap — dim files unused for 2+ years (Cmd+Opt+R)")
                        .keyboardShortcut("r", modifiers: [.command, .option])
                        .disabled(!appState.scanProgress.scanComplete)

                        Divider().frame(height: 16)

                        // Take Snapshot
                        if appState.isSnapshotBuilding {
                            ProgressView()
                                .controlSize(.small)
                                .help("Saving snapshot…")
                        } else {
                            Button {
                                appState.takeSnapshot()
                            } label: {
                                Image(systemName: "camera")
                            }
                            .help("Take Snapshot for Temporal Diff (Cmd+Opt+S)")
                            .keyboardShortcut("s", modifiers: [.command, .option])
                            .disabled(!appState.scanProgress.scanComplete)
                        }

                        // Temporal Diff toggle
                        Toggle(isOn: Binding(
                            get: { appState.isTemporalDiffEnabled },
                            set: { enabled in
                                appState.isTemporalDiffEnabled = enabled
                                if enabled { appState.startTemporalDiff() }
                            }
                        )) {
                            Image(systemName: "timelapse")
                        }
                        .help("Temporal Diff — highlight changes since snapshot (Cmd+Opt+D)")
                        .keyboardShortcut("d", modifiers: [.command, .option])
                        .disabled(!appState.scanProgress.scanComplete || appState.temporalSnapshot == nil)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $showLegend) {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help("Toggle Legend (Cmd+Opt+L)")
                    .keyboardShortcut("l", modifiers: [.command, .option])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchRequested)) { _ in
                appState.activeTab = .search
            }

            Divider()

            footerBar
        }
    }
```

### Step 2c: Add the `footerBar` computed property

Add this new private computed property to `ContentView`. Place it immediately after the `scanSummary` computed property (which ends around line 137) and before the `// MARK: - Detail` comment. The surrounding context is:

```swift
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Detail
```

Insert after the closing brace of `scanSummary`:

```swift
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            // Left: full path of the selected node
            if let idx = appState.selectedNodeIndex,
               let tree = appState.fileTree {
                let path = tree.path(at: idx)
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            // Right: scan duration and item count
            if appState.scanDuration > 0 {
                Text(String(format: "Scanned in %.1fs", appState.scanDuration))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let tree = appState.fileTree {
                Text("\(SizeFormatter.shared.formatCount(tree.count)) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.bar)
    }

    // MARK: - Detail
```

---

## Key facts discovered during research

### `FileTree.count`
`FileTree` has a thread-safe `public var count: Int` property (line 63–67 of `FileNode.swift`). It acquires `lock` and returns `nodes.count`. Safe to call from the main thread.

### `FileTree.path(at:)`
`FileTree.path(at: UInt32) -> String` exists (line 140 of `FileNode.swift`). It walks the parent chain and builds a full Unix path starting with `/`. Safe to call from the main thread (acquires internal lock).

### `appState.selectedNodeIndex` type
`selectedNodeIndex` is `UInt32?` (declared in `AppState.swift` line 13). Pass it directly to `tree.path(at:)` — no casting needed.

### `SizeFormatter.shared.formatCount(_:)`
Already used in `ContentView.scanSummary` (line 124) and `ContentView.scanningPlaceholder` (line 292) as `SizeFormatter.shared.formatCount(tree.count)` and `SizeFormatter.shared.formatCount(appState.scanProgress.totalItems)`. Use the same pattern for the item count in the footer.

### Scan timing: why `AppState` not `ScanProgress`
`ScanProgress.elapsedTime` is set to `totalElapsed` at the end of `FileScanner.scan()` before `scanComplete` is set to `true`. However, `ScanProgress` is designed to track live scan state and is reset on every new scan via `progress.reset()` inside `FileScanner.scan()`. Storing `scanDuration` directly on `AppState` avoids coupling the footer to scanner internals and persists the value cleanly across re-renders.

### Where `scanComplete` is set
`ScanProgress.scanComplete = true` is set inside `FileScanner.scan()` in the final `await MainActor.run` block (line 207 of `FileScanner.swift`), AFTER `progress.elapsedTime = totalElapsed`. In `ContentView.startScan()`, the `await MainActor.run` block runs immediately after `scanner.scan()` returns, which is after `scanComplete` is already `true`. Setting `appState.scanDuration` in that same `MainActor.run` block is therefore safe and correctly ordered.

### No `CFAbsoluteTime` import needed
`CFAbsoluteTimeGetCurrent()` is available without explicit import in Swift files on Apple platforms. `ContentView.swift` already imports only `SwiftUI` and `DirWizLib` — no change needed.

---

## Build and test

After making changes, build with:

```
swift build
```

Then run with:

```
swift run DirWiz
```

Verify:
1. Scan a volume. The footer should appear below the window content.
2. After scan completes, the right side should show "Scanned in X.Xs" and "N items".
3. Click a file or directory in the tree or treemap. The left side should show its full path, truncated from the head if long.
4. The footer should be exactly 22pt tall with `.bar` background (matches the macOS window chrome style).
5. Starting a new scan should clear `scanDuration` and `selectedNodeIndex` (both reset in `resetForNewScan()`).
