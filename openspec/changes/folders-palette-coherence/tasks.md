## 1. Pin the failure

- [x] 1.1 Change the production-palette test to require 20-30% retained channel spread and exactly
  25% pairwise distance, so the shipped 45% treatment fails deterministically.
- [x] 1.2 Add coverage that Cushion keeps raw palette colors and that the Folders legend uses a
  representative transformed swatch without mutating the underlying palette.
- [x] 1.3 Add a website contract test that pins one Cards-only color transform and the shared 0.75
  factor; the live demo must not silently keep the raw palette.

## 2. App implementation

- [x] 2.1 Set the Folders chrome blend to 0.75 and update its rationale from the real-volume result.
- [x] 2.2 Keep parent-depth application for ordinary leaves and collapsed folders.
- [x] 2.3 Make `ExtensionLegend` style-aware and render depth-zero representative Folders swatches.
- [x] 2.4 Preserve Cushion rendering, the color-resolution cache, palette ordering, overlays, and
  hit-testing behavior.

## 3. Website demo parity

- [x] 3.1 Add a named Cards leaf-color helper using the same chrome blend.
- [x] 3.2 Apply it only when Cards is active, including collapsed directory leaves; Cushion and the
  hero animation retain their existing palette treatment.
- [x] 3.3 Keep legend and hover identity coherent with the displayed Cards colors.

## 4. Verification

- [x] 4.1 Run the focused card-style, extension-palette, and website contract tests.
- [ ] 4.2 Render and inspect the website demo in both styles at desktop and mobile widths.
- [x] 4.3 Run the full suite and `CI=true` parity.
- [x] 4.4 Run `openspec validate --all --strict` and confirm Cushion/card shader tests remain green.
