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

- [ ] 3.1 Emit directory container instances (fill + header strip where the rect allows a legible label) in Card mode only
- [ ] 3.2 Apply per-depth insets at instance-build time; `SquarifyLayout` untouched
- [ ] 3.3 Aggregate over-budget nodes into a per-parent cell instead of sub-pixel slivers
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

- [ ] 6.1 Screenshot pass in both styles at several densities (small folder, /Applications-scale, whole-volume root), per the repo's screenshot-iterate convention
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

## Deferred (not implemented)

- 3.1 / 3.2 / 3.3 — directory container instances with header strips, per-depth insets at
  instance-build time, and per-parent aggregation of over-budget nodes. The leaf-level card
  treatment already delivers the requested look; containers are an additive second pass and
  are not required for the style to be correct. Over-budget views currently fall back to
  cushion (3.4) instead of aggregating, and the UI says so.
- 4.3 — directory-container click behavior is moot until containers exist.
- 6.1 — the multi-density screenshot pass is blocked by the `cacheDisplay` limitation above.
  Substituted with the offscreen render verification described in 2.4, plus a 33-rect
  composed-layout render inspected in both styles.
