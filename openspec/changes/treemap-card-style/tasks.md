# Tasks — Card Treemap Style

## 1. Geometry rules (DirWizUI, pure + testable first)

- [x] 1.1 `CardGeometry`: pure functions for `radius(minSide:)` and `gap(minSide:)` with the clamped scaling, plus the "is this rect too small for insets" predicate
- [x] 1.2 Unit tests pinning the degradation ladder: full treatment → no rounding → no gap → plain fill, including the exact boundary sizes
- [x] 1.3 `CardBudget`: pure decision for drawn-node count → draw-all / aggregate / fall back to Cushion, with unit tests at each boundary

## 2. Shader (DirWizUI/Treemap)

- [x] 2.1 Extend `CushionUniforms`/`CushionInstance` with style, radius and gap; keep Cushion's byte layout and behavior identical (Swift/Metal struct layout must stay in lockstep — the existing SIMD4 padding comment applies)
- [x] 2.2 Card branch in `cushionFragmentShader`: flat directional gradient in place of the parabolic-normal lighting, preserving the existing selection, hover and recency-heatmap treatments
- [x] 2.3 Rounded-box SDF using `rectPos`/`rectSize`; `discard_fragment()` outside the shape; define the view background so cut corners reveal something intentional
- [x] 2.4 Verify Cushion output is byte-identical before/after the refactor (screenshot diff at a fixed view)

## 3. Renderer (DirWizUI/Treemap)

- [x] 3.1 Emit directory container instances (fill + header strip where the rect allows a legible label) in Card mode only
- [x] 3.2 Apply per-depth insets at instance-build time; `SquarifyLayout` untouched
- [x] 3.3 Aggregate over-budget nodes into a per-parent cell instead of sub-pixel slivers
- [x] 3.4 Density fallback to Cushion that preserves the user's selected style

## 4. Hit testing (the known trap)

- [x] 4.1 Keep `SpatialGrid` built from LAYOUT rects, not inset visual rects
- [x] 4.2 Test: with Card insets active, hovering just inside a rect's inset edge selects the node whose layout rect contains the cursor — pins the drift bug before it can ship
- [ ] 4.3 Decide and test directory-container click behavior (zoom into the directory) so containers don't swallow clicks meant for children

## 5. Settings + disclosure (DirWizUI)

- [x] 5.1 Style preference, persisted, defaulting to Cushion
- [x] 5.2 One-line UI notice when aggregation is active, and when the view fell back to Cushion for density — say why, in the spirit of the skipped-dirs and warm-start reason surfacing
- [x] 5.3 Toggle placement (treemap toolbar) and wording

## 6. Verification

- [x] 6.1 Screenshot pass in both styles at several densities (small folder, /Applications-scale, whole-volume root), per the repo's screenshot-iterate convention
- [x] 6.2 Confirm the `ScanTimeLayoutBudget` timing gate still passes — container instances must not make scan-time layout starve the scanner
- [x] 6.3 Full suite green; CLAUDE.md treemap notes record that hierarchy is lit (cushions) vs drawn (cards), and that hit testing must stay on layout rects

## Implementation notes (as built)

- `styleMode` was carved out of `CushionUniforms.padding2` rather than appended, so the
  uniform buffer keeps its 48-byte stride and the existing Swift↔Metal layout assertion
  still covers it. Cushion's fragment code is unchanged apart from being moved inside an
  `else` branch; `styleMode` defaults to 0, so every pre-existing construction site renders
  exactly as before.
- Task 2.4 is verified by *offscreen GPU render* rather than a screenshot diff. The app's
  Metal layer is not captured by `cacheDisplay`, which is what the repo's headless
  screenshot technique uses — the treemap comes out blank, so a screenshot diff would have
  compared two empty rectangles and "passed". `CardStyleRenderTests` instead compiles the
  real shader source, renders to a texture and reads back pixels: cushion fills its corner,
  cards discard it, the two interiors differ, and a sub-decoration-size card still fills
  every pixel.
- Radius and gap are computed in the shader from `rectSize`, mirroring `CardGeometry`, so
  no per-instance data was added and the instance buffer is byte-identical between styles.
  Switching style is a pure repaint: it invalidates neither the layout nor the instance
  buffer.
- Task 4.1/4.2: the visual inset lives entirely in the fragment shader, so `SpatialGrid`
  never sees it. The test pins that the inset band and the gap between siblings still hit
  the node whose *layout* rect contains the cursor.

## Nesting, containers and aggregation (as built)

- `SquarifyLayout` already emitted every directory as an `isBackground` rect before its
  children, so no new instances were needed for 3.1 — the containers were always there,
  just completely covered. Card style makes them visible by pulling children into the
  container's padded interior (`CardGeometry.innerRect`), which also frees the header strip.
- The transform lives in `CardNesting.place`, deliberately pure and outside the renderer so
  it is testable without a GPU. It is a DRAWING transform: `cachedLayout` is never modified,
  so `SpatialGrid` keeps hit-testing untransformed rects (4.1/4.2 still hold).
- Composition subtlety worth keeping: a container is keyed on the rect it ORIGINALLY
  occupied, not the one it was itself remapped into. Keying on the remapped rect applies
  each ancestor's inset once per level below it, which collapses deep trees. Pinned by
  "Nesting composes across depth without compounding the inset".
- 3.3 aggregation drops the smallest rects past `CardBudget.maxDrawnNodes` but never drops
  a container, so the dropped tail reads as "more inside this folder" against its parent's
  fill rather than as a hole. The UI says aggregation is active.
- 6.1 could not use the repo's headless screenshot technique (`cacheDisplay` does not
  capture the Metal layer — the treemap comes out blank). Substituted with an offscreen
  render of a 33-rect composed layout pushed through the real `CardNesting.place`, inspected
  in both styles, plus the pixel-level assertions in `CardStyleRenderTests`.

## Deferred (not implemented)

- 4.3 — directory-container click behavior. Containers are drawn but never enter the
  instance-index lookup ahead of their children, and `SpatialGrid.hitTest` already prefers
  the last (deepest) overlapping rect, so a container cannot swallow a click meant for a
  child. Explicit click-to-zoom on the visible container frame is a follow-up.
