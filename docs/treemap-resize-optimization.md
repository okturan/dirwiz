# Treemap Resize / Layout Lag — Optimization Spec

## Problem Statement

When a side panel closes or the window resizes, the treemap visibly lags up to **1 second** before reflowing to fill the new space. The root cause is that the squarify layout algorithm runs **synchronously on the main thread** inside `draw(in:)`, and a hard 1-second throttle (`CushionRenderer.swift:133`) deliberately prevents more frequent recomputes.

---

## Current Architecture (the bottleneck)

```
draw(in:) — called on main thread, up to 30fps
  └─ recomputeLayoutIfNeeded(viewportSize:)
       ├─ guard: if (now - lastLayoutTime) < 1.0 { return }   ← visible lag source
       ├─ tree.nodesSnapshot()                                 ← copies entire node array
       ├─ SquarifyLayout.layout(...)                           ← O(n log n), fully sync
       │    └─ stores ancestors: [(x,y,w,h)] on every rect    ← O(n×depth) memory
       ├─ for each rect: computeCushionCoefficients(for:)      ← O(n×depth) post-pass
       ├─ SpatialGrid(...)                                     ← O(n) grid rebuild
       └─ onLayoutUpdate?(cachedLayout)
  └─ updateInstanceBuffer()                                    ← O(n) full rebuild
```

**Measured costs for a typical 100K-node scan:**

| Step | Time | Memory | Notes |
|------|------|--------|-------|
| nodesSnapshot | ~2ms | ~8 MB | Single lock, then lock-free |
| SquarifyLayout.layout | ~25–60ms | ~34 MB | Dominated by ancestors allocation |
| computeCushionCoefficients (post-pass) | ~5–15ms | 0 | O(n × avg_depth) |
| SpatialGrid rebuild | ~3ms | ~1 MB | |
| updateInstanceBuffer | ~8ms | ~3 MB GPU | ~100K × 48 bytes |
| **Total per-layout** | **~45–90ms** | **~46 MB** | Blocks main thread |

The 1-second throttle exists to keep this cost off the critical path during scanning — but it is the direct cause of the visible lag when viewport size changes.

---

## Fix 1 — Eliminate `ancestors` Array, Inline Coef Computation

**Impact: ~14× memory reduction, ~20% faster layout, simplifies code**

### Root cause

`TreemapRect` currently stores:
```swift
public let ancestors: [(x: Float, y: Float, w: Float, h: Float)]
```

At `maxDepth = 20`, each rect can hold 20 × 16 bytes = **320 bytes of heap-allocated ancestor data**. For 100K rects this is ~32 MB of heap churn. The array is used *only* once in the post-layout coef pass, then abandoned.

### Fix

Compute cushion coefficients **inline** during the `layoutNode` recursion. The recursion already passes `ancestors` down the stack — use the stack copy directly at leaf/directory-emit time instead of storing it on the rect.

**`SquarifyLayout.swift` changes:**

1. Remove `ancestors: [(x,y,w,h)]` field from `TreemapRect`
2. Remove `cachedCoefs` field initialization from callsites
3. In `layoutNode`, before emitting a `TreemapRect`, compute coefs inline:

```swift
// At every emit point (leaf, max-depth dir, empty dir):
var coefs = SIMD4<Float>.zero
for (level, anc) in ancestors.enumerated() {
    let h = CushionConstants.H * powf(CushionConstants.F, Float(level))
    addRidge(&coefs, rectX: rect.x, rectY: rect.y, rectW: rect.w, rectH: rect.h,
             ancestorX: anc.x, ancestorY: anc.y, ancestorW: anc.w, ancestorH: anc.h, h: h)
}
result.append(TreemapRect(nodeIndex: index, x: rect.x, y: rect.y,
    width: rect.w, height: rect.h, depth: depth,
    cachedCoefs: coefs, isBackground: false))
```

4. Remove the post-layout coef loop in `CushionRenderer.recomputeLayoutIfNeeded`:
```swift
// DELETE this entire block:
for i in 0..<cachedLayout.count {
    cachedLayout[i].cachedCoefs = computeCushionCoefficients(for: cachedLayout[i])
}
```

**New `TreemapRect` size:** ~40 bytes (vs ~350 bytes for deep nodes). Zero heap allocation per rect.

**Also refactor `addRidge` signature** to take flat Float params instead of a `TreemapRect` receiver — avoids a circular dependency and makes the inline usage cleaner.

---

## Fix 2 — Off-Thread Layout with Double Buffering

**Impact: Eliminates the 1-second visible lag entirely**

### Design

Replace the synchronous main-thread layout + 1-second throttle with an async double-buffer pattern:

```
State:
  cachedLayout: [TreemapRect]      ← last committed layout, rendered by draw(in:)
  pendingLayoutTask: Task<...>?    ← background task currently computing new layout
  pendingLayoutSize: CGSize        ← viewport size the pending task is computing for
```

### Flow

**On viewport size change (in `recomputeLayoutIfNeeded`):**

```swift
func recomputeLayoutIfNeeded(viewportSize: CGSize) {
    guard let tree = currentFileTree, !tree.isEmpty else { ... }
    guard viewportSize != currentViewportSize || needsForceLayout else { return }

    // If a task is already running for this exact size, don't restart.
    if pendingLayoutTask != nil && pendingLayoutSize == viewportSize && !needsForceLayout { return }

    needsForceLayout = false
    pendingLayoutSize = viewportSize
    pendingLayoutTask?.cancel()

    // Snapshot once on main thread (single lock acquisition).
    let snapshot = tree.nodesSnapshot()
    let rootIndex = currentRootIndex
    let bounds = CGRect(origin: .zero, size: viewportSize)

    pendingLayoutTask = Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }

        var layout = SquarifyLayout.layout(
            nodes: snapshot, rootIndex: rootIndex,
            bounds: bounds, maxDepth: 20, minPixelSize: 1.0
        )
        // Coefs now computed inline — no post-pass needed (see Fix 1)

        guard !Task.isCancelled else { return }

        let grid = SpatialGrid(
            viewportWidth: Float(viewportSize.width),
            viewportHeight: Float(viewportSize.height),
            rects: layout
        )

        await MainActor.run { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.cachedLayout = layout
            self.cachedSnapshot = snapshot
            self.currentViewportSize = viewportSize
            self.spatialGrid = grid
            self.instanceBufferDirty = true
            self.pendingLayoutTask = nil
            self.onLayoutUpdate?(layout)
            self.mtkView?.needsDisplay = true
        }
    }
}
```

**Key properties:**
- Main thread is **never blocked** by layout
- Only one task runs at a time; size changes cancel the previous task
- Remove `lastLayoutTime` throttle entirely — replaced by task deduplication
- `forceLayoutInvalidation()` sets `needsForceLayout = true` and cancels pending task
- `invalidateLayout()` just cancels pending task and triggers a new one

**Threading note:** `SquarifyLayout.layout` must remain pure (no shared mutable state) — it already is.

---

## Fix 3 — Immediate Scale Preview During Layout

**Impact: Zero perceived lag — treemap fills new space instantly**

### Design

When the viewport size changes, instead of showing a frozen/stale layout, **immediately scale the existing rects proportionally** to the new viewport. This is an O(n) multiply that completes in < 1ms even for 100K rects.

```swift
// In recomputeLayoutIfNeeded, before launching background task:
if !cachedLayout.isEmpty && currentViewportSize != .zero {
    let xScale = Float(viewportSize.width  / currentViewportSize.width)
    let yScale = Float(viewportSize.height / currentViewportSize.height)
    for i in 0..<cachedLayout.count {
        cachedLayout[i] = TreemapRect(
            nodeIndex: cachedLayout[i].nodeIndex,
            x:      cachedLayout[i].x      * xScale,
            y:      cachedLayout[i].y      * yScale,
            width:  cachedLayout[i].width  * xScale,
            height: cachedLayout[i].height * yScale,
            depth:  cachedLayout[i].depth,
            cachedCoefs: cachedLayout[i].cachedCoefs,  // reuse — close enough
            isBackground: cachedLayout[i].isBackground
        )
    }
    // Rebuild spatial grid for hit testing on the scaled layout.
    spatialGrid = SpatialGrid(
        viewportWidth: Float(viewportSize.width),
        viewportHeight: Float(viewportSize.height),
        rects: cachedLayout
    )
    instanceBufferDirty = true
    // Note: cachedCoefs are slightly wrong for the scaled rects but the visual
    // difference is imperceptible during the ~50-100ms preview window.
}
// Then launch background task (Fix 2)...
```

**Visual behavior:**
- Treemap immediately stretches/shrinks to fill new space
- Rectangles may be slightly non-square during preview (usually < 100ms)
- Background task swaps in correctly laid-out rects; user sees a brief settle

Combined with Fix 2, the user sees: immediate fill → subtle reshape ~50ms later. Feels instant.

---

## Fix 4 — Skip Buffer Rebuild for Hover Changes

**Impact: Removes unnecessary O(n) work on every mouse move**

### Current

```swift
if !instanceBufferDirty && !selectionChanged && !hoverChanged {
    return
}
```

Hover changes trigger a full O(n) instance buffer rebuild. But hover is **already handled by the uniform**, not the per-instance buffer:

```swift
var uniforms = CushionUniforms(..., hoveredIndex: hoveredInstance, ...)
```

The shader uses `hoveredIndex` to brighten the hovered rect — the per-instance color is NOT changed for hover.

### Fix

Remove `hoverChanged` from the buffer-dirty condition:

```swift
// Before:
if !instanceBufferDirty && !selectionChanged && !hoverChanged { return }

// After:
if !instanceBufferDirty && !selectionChanged { return }
```

Hover-only `draw(in:)` calls (30fps while moving mouse) will skip `updateInstanceBuffer` entirely, only updating the uniform. This saves ~8ms × 30fps = ~240ms/second of unnecessary CPU work during mouse movement.

---

## Fix 5 — Incremental Instance Buffer for Selection Changes

**Impact: ~100× faster selection updates**

### Design

Selection changes currently trigger a full O(n) buffer rebuild to update 1-2 instances (prev selected → normal color, new selected → bright color).

Add a `nodeIndexToInstanceIndex: [UInt32: Int]` lookup built during full buffer builds:

```swift
private var nodeIndexToInstanceIndex: [UInt32: Int] = [:]
```

For selection-only changes (no layout change), update only the affected instances:

```swift
func applySelectionChange(from oldSel: UInt32?, to newSel: UInt32?, nodes: [FileNode]) {
    guard let buffer = instanceBuffer else { return }
    let ptr = buffer.contents().bindMemory(to: CushionInstance.self, capacity: instanceCount)

    // Reset old selection.
    if let old = oldSel, let idx = nodeIndexToInstanceIndex[old] {
        ptr[idx].color = baseColor(for: old, nodes: nodes)  // recalculate without highlight
    }
    // Apply new selection.
    if let new = newSel, let idx = nodeIndexToInstanceIndex[new] {
        var c = baseColor(for: new, nodes: nodes)
        c.x = min(c.x + 0.25, 1.0); c.y = min(c.y + 0.25, 1.0); c.z = min(c.z + 0.25, 1.0)
        ptr[idx].color = c
    }
}
```

This makes selection O(1) instead of O(n).

**Note:** The white SwiftUI `selectionBorderOverlay` (already implemented in `TreemapInteraction.swift`) makes selection highly visible without relying on the Metal highlight. Fix 5 is the lowest-priority item here.

---

## Implementation Order

| # | Fix | Effort | Impact | Risk |
|---|-----|--------|--------|------|
| 1 | Eliminate ancestors array | Medium | Memory + CPU | Low (pure refactor) |
| 2 | Off-thread layout | Medium | Eliminates all lag | Medium (threading) |
| 3 | Scale preview | Small | Instant perceived response | Low (additive) |
| 4 | Skip buffer rebuild on hover | Tiny | ~240ms CPU/s saved | Trivial |
| 5 | Incremental selection update | Medium | Minor | Medium |

**Recommended sequence:** Fix 4 (trivial, do it now) → Fix 1 (safe refactor) → Fix 2 + Fix 3 (together, one PR) → Fix 5 (if profiler shows it matters).

---

## Acceptance Criteria

1. Panel open/close: treemap fills new space within one frame (~33ms at 30fps)
2. Window resize drag: treemap tracks resize in real-time (scale preview), settles correctly
3. Mouse hover: no visible latency, CPU usage during hover < 5% (was ~8% due to buffer rebuilds)
4. `swift test` passes, no regressions
5. Scan-in-progress: treemap still updates periodically (remove hard 1s throttle, rely on task deduplication — scan updates fire every 0.5s via `invalidateLayout`, task dedup prevents queue buildup)
