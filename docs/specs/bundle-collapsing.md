# Spec: Bundle / .app Collapsing

## Goal

Treat macOS bundles (.app, .framework, .xcarchive, etc.) as opaque leaf nodes throughout the
application. A bundle directory must not be recursed into during scanning, must appear as a leaf
in the treemap (single solid rect, no children), and must show no disclosure arrow in the tree
table view.

---

## 1. Bundle Extension List

Detect by checking whether the directory name, lowercased, ends with one of:

```
.app
.framework
.xcarchive
.xcodeproj
.xcworkspace
.kext
.plugin
.bundle
.docset
.xpc
.qlgenerator
.mdimporter
.prefPane
.driver
```

The check must be case-insensitive because APFS is case-insensitive and names like `MyApp.APP`
are valid. Use `name.lowercased().hasSuffix(ext)` or compare against the lowercased name.

---

## 2. Marking Bundles — Approach

### Option A: bit flag on FileNode.flags (RECOMMENDED)

`FileNode.flags` is a `UInt8`. Currently only bit 0 is used (`isDirectory`). Bits 1–7 are free.
Using bit 1 costs zero extra memory and keeps the struct at its current 48 bytes. The struct is
not `@frozen` and the flag is set only during scanning (single-threaded per-batch), so there is
no thread-safety concern beyond what already exists.

Add `isBundle` as bit 1:

```swift
// In FileNode.swift, alongside the existing isDirectory computed property:

public var isBundle: Bool {
    get { flags & 2 != 0 }
    set {
        if newValue { flags |= 2 } else { flags &= ~2 }
    }
}
```

This is strictly better than a separate `Set<UInt32>` on AppState because:
- No cross-module state to thread through every call site.
- `nodesSnapshot()` already carries the flag to SquarifyLayout, which works off the snapshot array.
- No set membership lookup needed; it is a single bitwise AND.

### Option B: Set<UInt32> on AppState (not recommended)

Would require passing the set into `SquarifyLayout.layout()`, `TreeNodeItem`, and
`TreeTableView`. Avoids touching the packed struct but adds 3–4 API-surface changes for no
benefit. Reject.

---

## 3. Changes by File

### 3.1 Sources/Scanner/FileNode.swift

**Where:** After the existing `isDirectory` computed property (line 20–25).

**Add:**

```swift
public var isBundle: Bool {
    get { flags & 2 != 0 }
    set {
        if newValue { flags |= 2 } else { flags &= ~2 }
    }
}
```

Full surrounding context (replace the block that ends at line 25):

```swift
    public var isDirectory: Bool {
        get { flags & 1 != 0 }
        set {
            if newValue { flags |= 1 } else { flags &= ~1 }
        }
    }

    // Bit 1: node is a bundle (.app, .framework, etc.) — treated as opaque leaf.
    public var isBundle: Bool {
        get { flags & 2 != 0 }
        set {
            if newValue { flags |= 2 } else { flags &= ~2 }
        }
    }
```

No other changes to FileNode are needed. Size remains 48 bytes.

---

### 3.2 Sources/Scanner/FileScanner.swift

Two changes are needed in `scanDirectory`:

#### Change 1 — Add bundle-detection helper (top of file, file-private)

Add a file-private constant and helper after the `kBufferSize` constant (around line 29):

```swift
private let kBundleExtensions: Set<String> = [
    ".app", ".framework", ".xcarchive", ".xcodeproj", ".xcworkspace",
    ".kext", ".plugin", ".bundle", ".docset", ".xpc",
    ".qlgenerator", ".mdimporter", ".prefpane", ".driver"
]

private func isBundleName(_ name: String) -> Bool {
    let lower = name.lowercased()
    return kBundleExtensions.contains(where: { lower.hasSuffix($0) })
}
```

Note: `.prefpane` is lowercased in the constant so the `hasSuffix` comparison on the lowercased
name works correctly.

#### Change 2 — Mark bundle node and skip recursion

Inside `scanDirectory`, the relevant section builds a `FileNode` for a directory entry and then
appends to `subdirs`. Currently (lines 312–332):

```swift
                // Build FileNode
                var node = FileNode()
                node.isDirectory = isDir
                node.fileSize = isDir ? 0 : dataLength
                node.allocatedSize = isDir ? 0 : allocSize
                node.modifiedDate = modDate
                if !isDir {
                    node.extensionHash = extensionHash(entryName)
                }

                let childLocalIndex = children.count
                children.append((node: node, name: entryName))

                if isDir {
                    subdirs.append((name: entryName, childIndex: childLocalIndex, dev: devID, inode: fileID))
                    dirCount += 1
                } else {
                    totalFileSize += dataLength
                    totalAllocatedSize += allocSize
                    fileCount += 1
                }
```

Replace with:

```swift
                // Build FileNode
                var node = FileNode()
                node.isDirectory = isDir
                node.fileSize = isDir ? 0 : dataLength
                node.allocatedSize = isDir ? 0 : allocSize
                node.modifiedDate = modDate
                if !isDir {
                    node.extensionHash = extensionHash(entryName)
                }

                // Detect bundles: mark as opaque leaf, do not recurse.
                let isBundle = isDir && isBundleName(entryName)
                if isBundle {
                    node.isBundle = true
                }

                let childLocalIndex = children.count
                children.append((node: node, name: entryName))

                if isDir {
                    // Only enqueue for recursion if it is not a bundle.
                    if !isBundle {
                        subdirs.append((name: entryName, childIndex: childLocalIndex, dev: devID, inode: fileID))
                    }
                    dirCount += 1
                } else {
                    totalFileSize += dataLength
                    totalAllocatedSize += allocSize
                    fileCount += 1
                }
```

**Why this placement:** The `subdirs` array is what drives the `enqueue` calls at the bottom of
`scanDirectory` (lines 356–363). By simply not appending to `subdirs`, the bundle directory is
added to the tree as a child node (with its `isBundle` flag set) but never recursed into. Its
size will remain 0 (directories start at 0 and are accumulated bottom-up). This is acceptable:
the bundle appears in the treemap proportional to its accumulated children size. Since no
children are ever scanned, size will be 0. To give bundles a meaningful size, see Section 4
(Size of Bundle Nodes) below.

---

### 3.3 Sources/Treemap/SquarifyLayout.swift

**Where:** In `layoutNode`, after the leaf-file check and before the depth/size guards. Currently
around line 104–118:

```swift
        // Leaf file: emit rect directly.
        if !node.isDirectory {
            if rect.w >= minPixelSize && rect.h >= minPixelSize {
                result.append(TreemapRect(
                    nodeIndex: index,
                    x: rect.x,
                    y: rect.y,
                    width: rect.w,
                    height: rect.h,
                    depth: depth,
                    ancestors: ancestors
                ))
            }
            return
        }

        // Directory at max depth or too small: emit as a single rect.
        if depth >= maxDepth || rect.w < minPixelSize || rect.h < minPixelSize {
```

Replace with:

```swift
        // Leaf file: emit rect directly.
        if !node.isDirectory {
            if rect.w >= minPixelSize && rect.h >= minPixelSize {
                result.append(TreemapRect(
                    nodeIndex: index,
                    x: rect.x,
                    y: rect.y,
                    width: rect.w,
                    height: rect.h,
                    depth: depth,
                    ancestors: ancestors
                ))
            }
            return
        }

        // Bundle: treat as opaque leaf — emit single rect, do not recurse into children.
        if node.isBundle {
            if rect.w >= minPixelSize && rect.h >= minPixelSize {
                result.append(TreemapRect(
                    nodeIndex: index,
                    x: rect.x,
                    y: rect.y,
                    width: rect.w,
                    height: rect.h,
                    depth: depth,
                    ancestors: ancestors
                ))
            }
            return
        }

        // Directory at max depth or too small: emit as a single rect.
        if depth >= maxDepth || rect.w < minPixelSize || rect.h < minPixelSize {
```

The guard must come after the `!node.isDirectory` check because `isBundle` is only set on
directories; if somehow a file had bit 1 set, we never reach this path. Order: file leaf →
bundle leaf → depth guard → recurse.

---

### 3.4 Sources/Views/TreeNodeItem.swift

**Where:** The `hasChildren` computed property (lines 49–52):

```swift
    /// Whether this directory has any children (cheap check — no sorting).
    var hasChildren: Bool {
        guard isDirectory else { return false }
        return !tree.children(of: id).isEmpty
    }
```

Replace with:

```swift
    /// Whether this directory has any children (cheap check — no sorting).
    /// Bundle directories are treated as leaves even if they were scanned with children.
    var hasChildren: Bool {
        guard isDirectory else { return false }
        guard !node.isBundle else { return false }
        return !tree.children(of: id).isEmpty
    }
```

**Why:** `hasChildren` is used in `TreeTableView.treeRowContainer` (line 103) as the sole gate
for rendering the disclosure arrow. Setting it to `false` for bundles suppresses the arrow
without any changes needed in `TreeTableView` itself.

It is also used in `collectVisible` (TreeTableView line 88):

```swift
    private func collectVisible(_ item: TreeNodeItem, into result: inout [TreeNodeItem]) {
        result.append(item)
        guard item.isDirectory, expandedFolders.contains(item.id) else { return }
        for child in item.children {
            collectVisible(child, into: &result)
        }
    }
```

Since `collectVisible` checks `item.isDirectory` (not `item.hasChildren`), a bundle could still
be expanded via keyboard if `expandedFolders` somehow contains its id. To fully block expansion,
also guard `isDirectory && !node.isBundle` in `collectVisible`, or rely on the fact that no
disclosure arrow means no user-visible way to insert the bundle into `expandedFolders`. The
keyboard right-arrow handler in `expandOrGoFirstChild` checks `nodes[i].isDirectory` but not
`isBundle`, so it could technically insert a bundle id into `expandedFolders`. Fix this by
adding an `isBundle` guard in `expandOrGoFirstChild` in TreeTableView:

```swift
    /// Right arrow: expand collapsed directory, or move to its first child.
    private func expandOrGoFirstChild(tree: FileTree, proxy: ScrollViewProxy) {
        guard let selected = appState.selectedNodeIndex else { return }
        let nodes = tree.nodesSnapshot()
        let i = Int(selected)
        guard i < nodes.count, nodes[i].isDirectory else { return }
        // Do not expand bundle directories — they are opaque leaves.
        guard !nodes[i].isBundle else { return }
        if !expandedFolders.contains(selected) {
```

This is the only keyboard path that could expand a bundle; the disclosure button is gated on
`item.hasChildren` which already returns `false` for bundles.

---

### 3.5 Sources/Views/TreeTableView.swift — Summary

No structural changes are needed beyond the `expandOrGoFirstChild` guard described in 3.4. The
disclosure arrow is already gated on `item.hasChildren` (line 103), which will return `false`
for bundles after the `TreeNodeItem` change.

---

## 4. Size of Bundle Nodes

Because the scanner does not recurse into bundles, `node.fileSize` for a bundle will be 0 (no
children to accumulate). This makes all bundles invisible in the treemap (zero area).

**Required fix in FileScanner.swift:** After marking a directory as a bundle, read its size on
disk using `getattrlist` on the bundle path (not its contents), or use `stat` to get a rough
size. A simpler approach that avoids an extra syscall: use `lstat` on the bundle path to get
`st_size` (the directory entry size, which is usually 96–160 bytes and not useful), so this is
not enough. The correct approach is to compute the bundle's allocated size using `fts(3)` or
`getattrlistbulk` on the bundle, but that defeats the purpose of not recursing.

**Recommended approach:** After the main scan completes, add a post-scan pass in `FileScanner`
that iterates all nodes, finds bundles (where `isBundle == true` and `fileSize == 0`), and
computes their on-disk size using `fts` or by calling `getattrlistbulk` shallowly on just the
top level of the bundle directory and summing. Alternatively, use `NSDirectoryEnumerator` with
`includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]` restricted to the bundle root.

For the initial implementation, a simpler approach: add a helper
`computeBundleSize(path: String) -> (fileSize: UInt64, allocatedSize: UInt64)` that calls
`stat64` or `getattrlistbulk` on the bundle path, gets its recursive total using a fast
`getattrlistbulk` loop (same as `scanDirectory` but without enqueueing subdirs). This is
essentially a collapsed single-threaded mini-scan.

The call site would be at the bottom of `scanDirectory`, after collecting children, for any
child that was marked `isBundle`. Since bundle scanning is single-threaded and shallow, it can
run inline within the existing operation.

**IMPORTANT — verify FileTree mutation API before writing size propagation code:**

Before implementing size propagation, read `/Users/okan/code/mac-graph/Sources/Scanner/FileNode.swift` in full and find:
1. How `FileTree` exposes mutation of existing nodes (look for methods named `updateNode`, `setFileSize`, direct `nodes[i]` access, or similar).
2. How parent-size accumulation works (look for `accumulateSize`, `addToParent`, or size-rollup methods).

The spec sketches the approach below using placeholder method names. Replace them with the actual API you find. If `FileTree` does not expose node mutation, use the `tree.nodesSnapshot()` + direct `FileTree` internal approach, or add a `public func setSize(at index: UInt32, fileSize: UInt64, allocatedSize: UInt64)` method to `FileTree`.

Because bundle children were explicitly NOT added to `subdirs`, you need a separate collection:

```swift
        // Parallel to `subdirs`: directories that are bundles (not recursed).
        var bundleDirs: [(name: String, childIndex: Int)] = []
```

Populate it in the same block that currently appends to `subdirs`:

```swift
                if isDir {
                    if !isBundle {
                        subdirs.append(...)
                    } else {
                        bundleDirs.append((name: entryName, childIndex: childLocalIndex))
                    }
                    dirCount += 1
                }
```

Then after `addChildren` and size accumulation, compute bundle sizes using whatever mutation API exists on `FileTree`:

```swift
        // Compute and propagate sizes for bundle directories (not recursed).
        for bundle in bundleDirs {
            let bundlePath = dirPath + "/" + bundle.name
            let (bFileSize, bAllocSize) = computeBundleSize(path: bundlePath)
            if bFileSize > 0 || bAllocSize > 0 {
                let bundleTreeIndex = firstChildIndex + UInt32(bundle.childIndex)
                // Use whatever FileTree mutation API exists — see note above.
                // If nodes are directly mutable: tree.nodes[Int(bundleTreeIndex)].fileSize = bFileSize
                // If FileTree has accumulateSize: tree.accumulateSize(from: bundleTreeIndex, ...)
            }
        }
```

Implement `computeBundleSize` as a private method on `FileScanner` that does a full recursive
`getattrlistbulk` walk but only accumulates sizes (no tree mutation, no enqueueing). It can
reuse the same buffer and attrlist setup. Keep the implementation under ~60 lines.

---

## 5. Implementation Checklist

In order, implement:

1. `FileNode.swift` — add `isBundle` bit-1 flag with getter/setter.
2. `FileScanner.swift` — add `kBundleExtensions` set and `isBundleName` helper.
3. `FileScanner.swift` — in `scanDirectory`, detect bundle dirs, set flag, skip `subdirs`.
4. `FileScanner.swift` — add `bundleDirs` collection and `computeBundleSize` method; propagate sizes.
5. `SquarifyLayout.swift` — in `layoutNode`, add bundle leaf guard after the file leaf guard.
6. `TreeNodeItem.swift` — add `!node.isBundle` guard to `hasChildren`.
7. `TreeTableView.swift` — add `!nodes[i].isBundle` guard in `expandOrGoFirstChild`.

---

## 6. Testing

- Open `/Applications` — each `.app` should appear as a solid rect with no children in the treemap.
- In tree view, `.app` rows must have no disclosure arrow.
- Keyboard right-arrow on a `.app` row must not expand it.
- `.framework` directories inside `/System/Library/Frameworks` should each appear as a single rect.
- `.xcarchive` bundles in `~/Library/Developer/Xcode/Archives` should show correct sizes.
- Confirm that `/Applications/Xcode.app` (several GB) shows a large single rect and the size
  matches what Finder reports (within ~5% — the difference is hardlinks inside).
- Run `swift build` and confirm no regressions; run `swift run DirWiz` and scan `/Applications`.

---

## 7. Files Modified Summary

| File | Change |
|------|--------|
| `Sources/Scanner/FileNode.swift` | Add `isBundle` computed property (bit 1 of `flags`) |
| `Sources/Scanner/FileScanner.swift` | Add `kBundleExtensions`, `isBundleName`, bundle detection in `scanDirectory`, `computeBundleSize`, size propagation |
| `Sources/Treemap/SquarifyLayout.swift` | Add bundle leaf short-circuit in `layoutNode` |
| `Sources/Views/TreeNodeItem.swift` | Add `!node.isBundle` guard in `hasChildren` |
| `Sources/Views/TreeTableView.swift` | Add `!nodes[i].isBundle` guard in `expandOrGoFirstChild` |
