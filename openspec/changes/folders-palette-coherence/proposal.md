## Why

Two successive numerical fixes passed synthetic color tests and failed on the restored real tree.
The 75% neutral blend made extension colors grey. The next hierarchy-aware candidate restored leaf
chroma but tinted every expanded panel; the 880 GB screenshot from the installed build shows that
those nested panel fills combine into an ugly color veil over whole subtrees. That screenshot fails
the change's native visual gate, so the 60% leaf / 19.5% panel treatment is not a final decision.

Picking another pair of constants from swatches would repeat the same mistake. The decision must be
made in the actual Swift and Metal renderer on the actual multi-million-item tree.

## What Changes

- Add ten numbered Folders color schemes to the native renderer, spanning neutral, lightly bridged,
  cool, warm, and dark structural treatments.
- Put a temporary scheme picker beside the Folders toggle so all ten repaint the same displayed tree
  without a rescan, relayout, or synthetic screenshot pipeline.
- Default to **1. Clean**: neutral panels and full-strength extension colors, with no subtree tint.
- Keep **7. Tinted** as the rejected installed treatment so the comparison has an honest control.
- Persist the selected number across relaunch and make the visible File Types legend follow it.
- Require every candidate to preserve channel order, at least 60% production-palette separation,
  and complete Cushion isolation.
- Keep the local website demo on the clean default until one native scheme is selected; do not
  deploy or call the palette final before that choice.

## Capabilities

### New Capabilities

<!-- None. -->

### Modified Capabilities

- `treemap-render-style`: Folders exposes a bounded native color-comparison set while the final
  hierarchy/palette treatment is chosen from real-tree evidence.

## Impact

- `CardGeometry.swift`: ten renderer recipes and the clean default.
- `AppState.swift`, `CushionTreemapView.swift`, and `CushionRenderer.swift`: persisted selection and
  cheap instance-only repainting.
- `TreemapInteraction.swift`: temporary numbered picker next to Folders.
- `ExtensionLegend.swift`: selected-scheme parity.
- `docs/index.html`: clean-default parity while native review remains open.
- `CardStyleTests.swift`: all-candidate production palette and Cushion-isolation gates.
