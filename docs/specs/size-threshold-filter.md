# Spec: Size Threshold Filter for Tree View

## Context for the Codex agent

This spec describes a single, self-contained feature to add to the macOS disk-space analyzer
app (DirWiz). The app is built with SPM (`swift build` / `swift run DirWiz`) — NOT Xcode.
The primary target is `Sources/Views/TreeTableView.swift`.

Do NOT modify any file other than `Sources/Views/TreeTableView.swift` unless explicitly stated.
Do NOT add new files. Do NOT reformat unrelated code. Do NOT change public API signatures.

---

## Feature summary

Add a segmented size-threshold filter to the tree-view navigation bar. The user can choose a
minimum size (All / >1 MB / >10 MB / >100 MB). Only nodes whose `fileSize` meets or exceeds
the threshold are shown; nodes that fall below the threshold — along with their entire subtrees
— are hidden from the flat list. SwiftUI state drives re-rendering automatically when the
picker selection changes.

---

## File to edit

```
Sources/Views/TreeTableView.swift
```

All three changes below are confined to this single file.

---

## Change 1 — Add `@State` property

### Where to insert

In `TreeTableView`, there is already a block of `@State` and `@FocusState` properties at the
top of the struct:

```swift
@State private var sortKey: TreeSortKey = .size
@State private var sortAscending: Bool = false
@State private var expandedFolders: Set<UInt32> = []
@State private var scrollGeneration: UInt64 = 0
@FocusState private var isFocused: Bool
```

### What to add

Append one new `@State` property directly after `scrollGeneration` and before `@FocusState`:

```swift
@State private var minSizeFilter: UInt64 = 0
```

Final ordering after the edit:

```swift
@State private var sortKey: TreeSortKey = .size
@State private var sortAscending: Bool = false
@State private var expandedFolders: Set<UInt32> = []
@State private var scrollGeneration: UInt64 = 0
@State private var minSizeFilter: UInt64 = 0
@FocusState private var isFocused: Bool
```

---

## Change 2 — Add the Picker to `treeNavigationBar`

### Existing function signature and body

```swift
private func treeNavigationBar(tree: FileTree, proxy: ScrollViewProxy) -> some View {
    let canGoUp = canGoUpInTree(tree: tree)

    return HStack(spacing: 6) {
        Button {
            goUpInTree(tree: tree, proxy: proxy)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                Text("Up")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canGoUp)
        .foregroundStyle(canGoUp ? .secondary : .quaternary)

        Divider()
            .frame(height: 14)

        Text(selectedNodeName(tree: tree))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

        Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(.bar)
}
```

### What to add

Insert a segmented `Picker` on the RIGHT side of the HStack — after `Spacer(minLength: 0)` and
before the closing brace of the HStack. The Spacer already pushes everything to the right of
the Up button, so the Picker will appear flush-right.

Replace the `Spacer(minLength: 0)` line and the closing `}` of the HStack with:

```swift
        Spacer(minLength: 0)

        Picker("Min Size", selection: $minSizeFilter) {
            Text("All").tag(UInt64(0))
            Text("> 1 MB").tag(UInt64(1_000_000))
            Text("> 10 MB").tag(UInt64(10_000_000))
            Text("> 100 MB").tag(UInt64(100_000_000))
        }
        .pickerStyle(.segmented)
        .frame(width: 210)
        .labelsHidden()
    }
```

The `.labelsHidden()` modifier suppresses the "Min Size" label; the segments themselves already
carry readable text. The `width: 210` gives comfortable room for four segments at the small
font size the nav bar uses (height is fixed at 28 pt).

### Full resulting function body (for verification)

```swift
private func treeNavigationBar(tree: FileTree, proxy: ScrollViewProxy) -> some View {
    let canGoUp = canGoUpInTree(tree: tree)

    return HStack(spacing: 6) {
        Button {
            goUpInTree(tree: tree, proxy: proxy)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                Text("Up")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canGoUp)
        .foregroundStyle(canGoUp ? .secondary : .quaternary)

        Divider()
            .frame(height: 14)

        Text(selectedNodeName(tree: tree))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

        Spacer(minLength: 0)

        Picker("Min Size", selection: $minSizeFilter) {
            Text("All").tag(UInt64(0))
            Text("> 1 MB").tag(UInt64(1_000_000))
            Text("> 10 MB").tag(UInt64(10_000_000))
            Text("> 100 MB").tag(UInt64(100_000_000))
        }
        .pickerStyle(.segmented)
        .frame(width: 210)
        .labelsHidden()
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(.bar)
}
```

---

## Change 3 — Apply the filter in `collectVisible`

### Key facts about the data model

- `TreeNodeItem` is defined in `Sources/Views/TreeNodeItem.swift`.
- `item.node` returns a `FileNode` value (`var node: FileNode { tree.node(at: id) ?? FileNode() }`).
- `item.node.fileSize` is a `UInt64` representing the on-disk size of the node. For
  directories, this is the cumulative size of all descendants (the tree stores rolled-up sizes).
  This means: if a directory's `fileSize` is below the threshold, ALL of its children are
  necessarily also below the threshold — so the entire subtree can be skipped without recursing.
- `item.isDirectory` is a Bool computed from `node.isDirectory`.

### Existing `collectVisible` function

```swift
private func collectVisible(_ item: TreeNodeItem, into result: inout [TreeNodeItem]) {
    result.append(item)
    guard item.isDirectory, expandedFolders.contains(item.id) else { return }
    for child in item.children {
        collectVisible(child, into: &result)
    }
}
```

### What to change

Add an early-return guard at the very top of `collectVisible` — before `result.append(item)` —
that skips nodes (and their entire subtrees) when the filter is active and the node is too small:

```swift
private func collectVisible(_ item: TreeNodeItem, into result: inout [TreeNodeItem]) {
    // Size threshold filter: skip this node and its entire subtree if it falls below the
    // minimum. Because directory fileSize equals the sum of all descendants, if a directory
    // is below the threshold none of its children can exceed it either — so skipping the
    // subtree is both correct and efficient.
    if minSizeFilter > 0, item.node.fileSize < minSizeFilter {
        return
    }

    result.append(item)
    guard item.isDirectory, expandedFolders.contains(item.id) else { return }
    for child in item.children {
        collectVisible(child, into: &result)
    }
}
```

### Why this placement is correct

`collectVisible` is the single recursive function that both appends visible items and recurses
into expanded children. Inserting the guard at the top means:

1. The node itself is not appended when filtered out.
2. The recursion into children is never reached (because we return early), so the entire
   subtree is pruned in one O(1) check per skipped subtree root.
3. `flattenedVisibleItems` does not need any changes — it already calls `collectVisible` for
   each root, and the filter propagates naturally through recursion.

No other callers of `collectVisible` exist in the file.

---

## Reset behavior

No explicit reset action is required. `minSizeFilter` is a SwiftUI `@State` property. When it
changes (via the Picker binding `$minSizeFilter`), SwiftUI invalidates the view and
re-evaluates `flattenedVisibleItems`, which re-runs `collectVisible` with the new threshold.

The filter is local to the tree view and does not need to be persisted in `AppState` — it is a
transient UI state similar to `sortKey` and `expandedFolders`.

---

## What NOT to change

- `flattenedVisibleItems` — no changes needed there.
- `rootChildren` — it builds the top-level items; the filter is applied downstream in
  `collectVisible`.
- `TreeNodeItem.swift`, `TreeRow.swift`, `AppState.swift` — do not touch these files.
- The keyboard navigation functions (`moveSelection`, `collapseOrGoParent`,
  `expandOrGoFirstChild`) — they call `flattenedVisibleItems` themselves, so they will
  automatically respect the filter once `collectVisible` is updated. No changes needed.
- `revealAndScroll` — no changes needed. If a node is filtered out it simply won't be in the
  list, and the scroll-to call will be a no-op (ScrollViewProxy silently ignores unknown IDs).

---

## Verification checklist (for the agent to confirm after implementation)

1. `swift build` with no errors or warnings introduced by this change.
2. Selecting "> 100 MB" hides all files and directories smaller than 100 MB from the list.
3. Selecting "All" restores the full list.
4. The segmented control appears on the right side of the navigation bar, horizontally after
   the Spacer, and does not crowd the Up button or the selected-node name.
5. Keyboard navigation (arrow keys) continues to work correctly — it iterates over the
   filtered list, not the full list.
6. Expanding a filtered-out directory is not possible (because it isn't shown), which is the
   correct behavior.

---

## Summary of all edits (diff overview)

| Location | Kind | Details |
|---|---|---|
| `TreeTableView` — property block | Insert 1 line | `@State private var minSizeFilter: UInt64 = 0` after `scrollGeneration` |
| `treeNavigationBar` — HStack body | Insert after `Spacer(minLength: 0)` | `Picker` with 4 tagged options, `.pickerStyle(.segmented)`, `.frame(width: 210)`, `.labelsHidden()` |
| `collectVisible` — top of function | Insert guard | `if minSizeFilter > 0, item.node.fileSize < minSizeFilter { return }` |
