## 1. Pin the rejected grey wash and hierarchy discontinuity

- [x] 1.1 Change the production-palette test to require 55-65% retained channel spread and exactly
  60% pairwise distance, so the shipped 25% treatment fails deterministically.
- [x] 1.2 Add pure coverage that expanded panels carry a quieter content tint, collapsed folders
  keep file-like chroma, and actually empty folders remain neutral.
- [x] 1.3 Add deterministic deep-chain and competing-content tests for descendant representative
  selection, including proof that Cushion's direct-child directory rule is unchanged.

## 2. App implementation

- [x] 2.1 Set the Folders direct-leaf chrome blend to 0.40 and document the rejected 0.75 result.
- [x] 2.2 Add a Folders-only largest-content-branch representative resolver bounded by tree depth,
  with stable tie-breaking and no per-subtree allocation.
- [x] 2.3 Tint expanded panels from representative descendants and give collapsed folders
  content-bearing color while preserving truly empty neutral panels.
- [x] 2.4 Cache Folders representative colors by layout/color generation without changing Cushion's
  resolved-color cache, palette ordering, overlays, layout, or hit testing.
- [x] 2.5 Keep `ExtensionLegend` style-aware and render depth-zero representative Folders swatches.

## 3. Website demo parity

- [x] 3.1 Update the named Cards leaf-color helper to use the same 0.40 chrome blend.
- [x] 3.2 Apply it only when Cards is active; Cushion and the hero animation retain their existing
  palette treatment.
- [x] 3.3 Keep legend and hover identity coherent with the displayed Cards leaf colors.

## 4. Verification

- [x] 4.1 Run the focused card-style, treemap-color, extension-palette, and website contract tests.
- [ ] 4.2 Render and inspect the native Folders view on the restored multi-million-item tree; confirm
  red/blue remain chromatic and nested panels bridge rather than jump from unrelated grey.
- [ ] 4.3 Render and inspect the website demo in both styles at desktop and mobile widths.
- [x] 4.4 Run the full suite and `CI=true` parity.
- [x] 4.5 Run `openspec validate --all --strict` and confirm Cushion/card shader tests remain green.
