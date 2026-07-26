# Design — Card Treemap Style

## Context

`CushionRenderer` builds one `CushionInstance` per **leaf** rect and draws them all with a single instanced draw call. Hierarchy is not drawn — it is *lit*: `addRidge` accumulates a parabolic ridge per ancestor into each leaf's `coefs`, and `cushionFragmentShader` turns those coefficients into a surface normal for Lambertian + Blinn-Phong shading. Directories occupy no instances and no pixels.

That is the property that makes the app work at scale: a 4.45M-item scan on a ~1200×800 canvas gives each file ~0.2 px², and cushions still communicate structure because structure is encoded in shading rather than in whitespace.

Card style inverts that. Hierarchy becomes geometry: padding on four sides per level plus a header strip. A rect needs roughly `2 × (gap + radius)` before it can show its corners at all — about 12px per side at gap 2 / radius 4 — and the cost compounds with depth. The web demo that motivated this renders 648 nodes at depth 4, well inside that envelope.

So the design question is not "how do we draw rounded rects" (easy) but "how does this style behave honestly when it cannot draw what the user asked for" (the whole risk).

## Goals / Non-Goals

**Goals:**
- Offer the card look where it genuinely works, with Cushion untouched and still default.
- Degrade progressively rather than cliff-edge.
- Never imply completeness that isn't there.
- Keep one layout feeding both styles.

**Non-Goals:**
- Replacing Cushion, or changing its output in any way.
- Touching `SquarifyLayout`, the Oklab palette, or `TreemapColorResolver`.
- Matching the web demo pixel-for-pixel — it is a reference for the *look*, not a spec.

## Decisions

1. **Style is a render-time concern; layout is shared.** `SquarifyLayout` output is identical for both styles. Insets are applied when building instances, never when computing layout. This keeps zoom, breadcrumbs, and the spatial index working off one geometry.
2. **Hit testing keeps using layout rects.** `SpatialGrid` is built from layout rects today; Card style must not rebuild it from inset visual rects. Insets are up to ~2px per side, which is exactly the scale at which a mismatch is felt but not obviously diagnosed — a "selection is slightly off" bug that would be painful to chase later. Pin it with a test.
   - Consequence: a few pixels of gap are "owned" by the rect they were carved from. Acceptable, and matches how the web demo behaves.
3. **Adaptive radius and gap** as pure functions of the rect's smaller side: `radius = clamp(minSide × 0.12, 0, 6)`, `gap = clamp(minSide × 0.06, 0, 2)`. Both reach zero for small rects, so a shrinking rect loses its rounding, then its gap, then renders as plain fill — never as pure padding. These are cheap enough to compute per-instance on the CPU or per-fragment.
4. **Rounded corners via SDF in the fragment shader**, using the existing `rectPos` (0…1) and `rectSize` (px) varyings. `discard_fragment()` for the corner cutouts is simplest; the alternative is enabling alpha blending on the pipeline. Prefer `discard` initially and measure — if it costs too much at high instance counts, revisit, though card mode is bounded by construction.
   - Corners cut out means whatever is behind shows through, so the view needs a defined background fill (the demo uses a light card ground). Cushion mode tiles the canvas completely and never needed one.
5. **Directory containers become real instances.** In Card mode the renderer emits an instance per directory (container fill, and a header strip where `rw`/`rh` allow a legible label) in addition to leaves. This is the structural difference from Cushion and the reason instance counts rise.
6. **Node budget + disclosure.** Card mode carries a maximum drawn-node count. Over budget, the smallest/deepest nodes aggregate into a single cell per parent rather than becoming sub-pixel slivers, and the UI says so. The repo's existing discipline — surface the reason rather than silently degrade (skipped-dirs honesty, warm-start observability) — applies directly here.
7. **Density fallback preserves intent.** Above the threshold the view renders as Cushion while the *setting* stays Cards, so zooming into a folder restores the card look without the user touching the toggle. Switching styles under the user is only acceptable because the alternative is drawing something misleading.

## Risks / Trade-offs

- [Users read the fallback as a bug: "I chose Cards, I got Cushions"] → the UI must say why, in one short line, at the moment it happens.
- [Aggregation hides files] → it is disclosed, and Cushion (which hides nothing) stays default and one click away.
- [Container instances raise draw counts] → bounded by the node budget; measure against the existing `ScanTimeLayoutBudget` timing gate so the treemap can't start starving the scanner.
- [Hit-test drift] → decision 2 plus an explicit test; called out here because it is the most likely subtle regression.
- [Two shading paths to maintain] → contained in one fragment shader with a uniform branch, and Cushion's path is untouched.

## Migration Plan

Purely additive. Default is Cushion, so an existing user sees no change until they opt in. No persisted format changes beyond one new preference key. Rollback = revert; a stale preference value degrades to the default.

## Open Questions

- Global preference or per-volume? Global is simpler and probably right; per-volume only matters if someone keeps one small volume in Cards and a big one in Cushions.
- Does Card style want its own depth cap independent of the node budget? A budget alone may still yield deeply nested thin containers; a depth cap may read better.
- Should the Duplicates/Insights contexts default to Cards, given they are inherently small-N views where the style is strongest?
