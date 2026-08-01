## Why

Folders style still reads as bright extension-color fields pasted into grey folder panels. Two
successive fixes proved too weak on real scans: a 25% move toward each color's own luminance left
the brightness mismatch intact, and a 55% move toward folder chrome still retained 45% of the
near-primary production palette. The Samsung8TB scan makes the failure unambiguous at volume scale.

The sidebar legend also continues to show the raw vivid palette while Folders draws a transformed
one, and the website's Cards demo still renders raw palette colors. The product therefore has three
different answers for what a Folders color means.

## What Changes

- Make extension color an accent inside Folders chrome, not the dominant visual field.
- Pull production palette colors 75% toward the surrounding parent-container neutral, retaining a
  measured 25% of relative color separation.
- Keep Cushion colors unchanged.
- Make the visible File Types legend use a representative Folders swatch while Folders is selected.
- Apply the same Folders color policy to the website's interactive Cards demo.
- Pin the behavior against all 17 production colors and a same-generation/different-content palette
  regression, rather than synthetic samples.

## Capabilities

### New Capabilities

<!-- None. -->

### Modified Capabilities

- `treemap-render-style`: Folders colors form one coherent surface across rendered tiles, collapsed
  folders, the legend, and the browser demo while preserving Cushion's existing palette.

## Impact

- `Sources/DirWizUI/Treemap/CardGeometry.swift`: stronger, documented Folders color transform.
- `Sources/DirWizUI/Treemap/CushionRenderer.swift`: keep parent-depth application for leaves and
  collapsed folders.
- `Sources/DirWizUI/Views/ExtensionLegend.swift` and `DirWiz/ContentView.swift`: style-aware legend
  swatches.
- `docs/index.html`: Cards demo color parity.
- `Tests/CardStyleTests.swift` and website contract coverage: production palette and parity gates.
