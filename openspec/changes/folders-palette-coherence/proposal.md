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

The second native comparison rejected the shared rendering model, not merely its ten palettes.
The supplied 882 GB screenshot shows two failures shared by every option: broad same-colour upper
hierarchy fields abruptly become unrelated red/blue extension tiles, and pale regions read as empty
even though they contain substantial data. A deterministic fixture reproduces the latter: when half
the bytes are split across individually sub-threshold files, DirWiz paints exactly 5,000 of 10,000
square points as content and exposes folder background across the other half.

The complete SpaceMonger 1.4 source explains both failures. Its defaults set `file_color = 0` and
`folder_color = 0`, so `MinimalDrawDisplayFolder` selects the same `BoxColors[depth & 7]` table for
files and folders. It never changes colour semantics at the leaf boundary. Separately,
`FolderView.cpp::SizeFolders` emits an anonymous occupied placeholder when a sibling group can no
longer be subdivided. DirWiz copied the 32-by-24 gate and title inset but neither of these behaviors.

## What Changes

- Add ten numbered complete Folders depth palettes to the native renderer. Each owns all eight
  colours and applies them to files, folders, collapsed blocks, and density aggregates alike.
- Put a temporary scheme picker beside the Folders toggle so all ten repaint the same displayed tree
  without a rescan, relayout, or synthetic screenshot pipeline.
- Default to **1. SpaceMonger**, traceable to the reference `BoxColors` base row.
- Keep extension colours in Cushions. Folders uses its selected depth palette for the whole map so
  hierarchy colour progresses continuously instead of exploding into a second palette at leaves.
- Match SpaceMonger's density-cutoff semantics: collectively visible content that is too dense to
  split into useful individual cards becomes an occupied aggregate tile instead of exposed folder
  background.
- Give an aggregate the depth colour for its region, omit a false file label, and map interaction
  to the folder that owns the group.
- Include the original SpaceMonger sequence plus ocean, forest, sunset, spectrum, candy, earth,
  Nord, monochrome, and ink/paper alternatives with readable adjacent depth contrast.
- Persist the selected number across relaunch. In Folders, show the active eight-swatch depth key
  above the still-clickable raw File Types size breakdown.
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

- `CardGeometry.swift`: ten complete eight-level map palettes and the SpaceMonger reference default.
- `SquarifyLayout.swift`: explicit occupied aggregates for contiguous sub-threshold sibling groups.
- `AppState.swift`, `CushionTreemapView.swift`, and `CushionRenderer.swift`: persisted selection and
  cheap instance-only repainting plus unified depth-colour rendering.
- `TreemapInteraction.swift`: temporary numbered picker next to Folders and no labels for anonymous
  aggregate regions.
- `ExtensionLegend.swift`: an explicit Folders depth key plus the separate file-type breakdown.
- `docs/index.html`: clean-default parity while native review remains open.
- `CardStyleTests.swift` and `SquarifyLayoutTests.swift`: full-map palette semantics, source parity,
  occupied-area, interaction, and Cushion-isolation gates.
