## Why

Two successive numerical fixes passed synthetic color tests and failed on the restored real tree.
The 75% neutral blend made extension colors grey. The next hierarchy-aware candidate restored leaf
chroma but tinted every expanded panel; the 880 GB screenshot from the installed build shows that
those nested panel fills combine into an ugly color veil over whole subtrees. That screenshot fails
the change's native visual gate, so the 60% leaf / 19.5% panel treatment is not a final decision.

Picking another pair of constants from swatches would repeat the same mistake. The first native
comparison also exposed a second modelling error: schemes 1 through 7 shared the same dark outer
folder colour and linear depth ramp, 8 and 9 only changed its temperature slightly, and 10 merely
made it darker. They were ten unequal structs but not ten meaningfully different folder palettes.
The decision must be made in the actual Swift and Metal renderer on the actual multi-million-item
tree.

## What Changes

- Add ten numbered Folders hierarchy palettes to the native renderer. Each owns all eight folder
  depth colours, including the outermost surface, rather than sharing one base-plus-step formula.
- Put a temporary scheme picker beside the Folders toggle so all ten repaint the same displayed tree
  without a rescan, relayout, or synthetic screenshot pipeline.
- Default to **1. Pearl**: a light outer folder surface that darkens inward.
- Keep direct files and collapsed content-bearing folders at their raw extension colours in every
  candidate; expanded folders use structural palette colours only, eliminating content tint as a
  source of another subtree veil.
- Include light-to-dark, dark-to-light, cool, warm, and deliberately alternating hierarchies, with
  pairwise-distinct outer folder colours.
- Persist the selected number across relaunch and keep the visible File Types legend raw.
- Require complete Cushion isolation and prove the ten full depth palettes differ perceptually, not
  merely by an otherwise invisible coefficient.
- Keep the local website demo on raw file colours until one native scheme is selected; do not
  deploy or call the palette final before that choice.

## Capabilities

### New Capabilities

<!-- None. -->

### Modified Capabilities

- `treemap-render-style`: Folders exposes a bounded native color-comparison set while the final
  hierarchy/palette treatment is chosen from real-tree evidence.

## Impact

- `CardGeometry.swift`: ten eight-level hierarchy palettes and the light Pearl default.
- `AppState.swift`, `CushionTreemapView.swift`, and `CushionRenderer.swift`: persisted selection and
  cheap instance-only repainting.
- `TreemapInteraction.swift`: temporary numbered picker next to Folders.
- `ExtensionLegend.swift`: raw extension-colour parity.
- `docs/index.html`: clean-default parity while native review remains open.
- `CardStyleTests.swift`: full-hierarchy distinctness, raw-file, and Cushion-isolation gates.
