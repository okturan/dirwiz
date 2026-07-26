# Card Treemap Style

## Why

The landing page's demo treemap - rounded rectangles, padding between siblings, nested containers with header labels, flat gradient fills - reads as noticeably prettier than the app's cushion rendering, and that reaction came from someone seeing both side by side without being told which was which. It's worth offering in the app.

It is not a shader toggle, because the two renderings convey hierarchy by different means. The app draws **leaves only**: one instanced quad per file, with nesting baked into each leaf's parabolic cushion coefficients by `addRidge`. Hierarchy costs **zero pixels** - which is precisely why the app can show 4.45M files at ~0.2 px² each and still look like a structured map. The card style draws **nested containers**: every directory becomes a rounded card with padding on four sides and a header strip, so hierarchy costs pixels at *every level*, and padding compounds with depth.

That makes the tradeoff structural rather than cosmetic. A rect cannot render below roughly `2 × (gap + radius)` - about a 12px floor per side at gap 2 / radius 4. The demo that prompted this looks good because it is 648 nodes at depth 4; the same treatment applied to a whole-volume scan cannot draw most of its leaves at all. So card style must be an explicitly *bounded* view, not a drop-in replacement.

## What Changes

- A treemap render style setting with two options: **Cushion** (today's, unchanged, remains the default) and **Cards**.
- Card style draws directory containers - rounded fill, inset children, header label where the rect is large enough - plus flat directional-gradient leaves instead of cushion lighting.
- **Adaptive geometry** so it degrades instead of falling off a cliff: corner radius and gap scale with rect size (`radius = clamp(minSide × 0.12, 0, 6)`, `gap = clamp(minSide × 0.06, 0, 2)`), collapsing to plain fill for small rects.
- A **node budget** for card mode: below the budget everything draws; above it, the deepest/smallest nodes are aggregated rather than drawn as sub-pixel slivers. The UI states when aggregation is in effect - the app must not silently imply it is showing everything when it isn't.
- Automatic fallback to Cushion when a view exceeds what card mode can honestly draw (e.g. whole-volume root), with the style setting preserved so zooming into a folder returns to Cards.
- Out of scope: changing `SquarifyLayout` (identical layout feeds both styles), the colour palette, and any change to Cushion rendering.

## Capabilities

### New Capabilities
- `treemap-render-style`: the style setting, card-mode drawing rules, adaptive geometry, node budget with honest disclosure, and the density-based fallback.

### Modified Capabilities
None - no baseline specs exist yet.

## Impact

- **DirWizUI/Treemap**: `CushionShaderSource` gains a style branch (flat gradient + rounded-box SDF, which needs alpha blending or `discard` - the fragment currently returns opaque); `CushionInstance`/uniforms gain style, radius and gap fields; `CushionRenderer` gains container-instance emission and per-depth insets at instance-build time.
- **Hit testing - the real trap**: `SpatialGrid` is built from layout rects. Card mode insets what is *drawn*, so hit rects must keep using layout rects or hover/selection will drift visibly from the cursor. Directory containers also become hit targets in a way they are not today, which interacts with click-to-zoom.
- **Settings/persistence**: a new user preference, plus deciding whether it is global or per-volume.
- **Tests**: geometry unit tests for the adaptive radius/gap function and the budget/aggregation rule; a hit-testing test pinning that layout rects (not inset visual rects) drive selection; screenshot verification of both styles at several densities, per the repo's screenshot-iterate convention.
