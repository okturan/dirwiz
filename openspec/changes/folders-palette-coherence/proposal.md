## Why

The 75% neutral blend shipped by this change was an overcorrection. On the supplied 5.35 TB scan it
turns even production red, blue, and green into greyish slate. Repeated screenshots also expose the
deeper discontinuity the blend could never solve: expanded folders are neutral grey even when all
of their useful content is several directory levels down in one color family, then their visible
leaves abruptly become red or blue.

The earlier 55% blend attacked the leaf alone and therefore left that grey-to-color boundary intact.
The correct unit is the hierarchy: panels need a quiet representative descendant tint, while files
and collapsed folders need enough chroma to remain an honest extension key. Cushion, which already
integrates raw colors through lighting, must remain unchanged.

## What Changes

- Restore clearly chromatic file colors in Folders by retaining a measured 60% of the production
  palette's channel spread and pairwise separation.
- Give expanded folder panels a quiet tint derived from the largest descendant content branch, so
  non-empty nested folders do not fall back to unrelated grey.
- Give collapsed folders file-like chroma because they stand in for the hidden contents.
- Keep Cushion colors unchanged.
- Make the visible File Types legend use a representative Folders swatch while Folders is selected.
- Apply the same direct-leaf Folders color strength to the website's interactive Cards demo.
- Pin the behavior against all 17 production colors, deep directory-only chains, and competing
  direct-file versus subtree content shapes.

## Capabilities

### New Capabilities

<!-- None. -->

### Modified Capabilities

- `treemap-render-style`: Folders colors form one coherent surface across rendered tiles, collapsed
  folders, the legend, and the browser demo while preserving Cushion's existing palette.

## Impact

- `Sources/DirWizUI/Treemap/CardGeometry.swift`: chromatic leaves plus distinct expanded/collapsed
  folder roles.
- `Sources/DirWizUI/Treemap/TreemapColorResolver.swift` and `CushionRenderer.swift`: Folders-only,
  descendant-aware representative colors with a generation-keyed cache.
- `Sources/DirWizUI/Views/ExtensionLegend.swift` and `DirWiz/ContentView.swift`: style-aware legend
  swatches.
- `docs/index.html`: Cards demo color parity.
- `Tests/CardStyleTests.swift` and website contract coverage: production palette and parity gates.
