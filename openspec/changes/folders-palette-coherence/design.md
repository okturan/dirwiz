## Context

The extension palette is intentionally vivid because Cushion lighting integrates those colors into
one surface. Folders has no cushion lighting, but muting leaves alone is insufficient: the 75%
neutral blend shipped by the first revision retained only 25% of source chroma and made the palette
look grey, while the folder panels themselves still supplied no hint of the content hue below them.
The supplied multi-terabyte scans reject both extremes and identify hierarchy continuity as the
missing mechanism.

## Goals / Non-Goals

**Goals:**

- Make folder structure and extension identity read as one hierarchy in Folders.
- Preserve a stable, clearly chromatic amount of extension-color information.
- Prevent non-empty directory-only chains from falling back to unrelated grey.
- Keep Cushion pixel behavior unchanged.
- Make the legend and website Cards demo honest representations of the app.
- Cover the actual 17-color production palette.

**Non-Goals:**

- Replace or reorder the extension palette.
- Remove extension coloring from Folders.
- Change treemap layout, card nesting, hit testing, labels, or palette ranking.
- Retune temporal-diff or recency overlays.

## Decisions

### 1. Retain 60% of extension color on direct leaves

Folders blends each file 40% toward the neutral tone of its parent container. Because the target is
the same neutral for every color at a given depth, this preserves exactly 60% of every pairwise RGB
distance and channel spread. The production palette therefore remains visibly red, blue, green, and
magenta instead of becoming a grey code users cannot read.

The old 55% and 75% blends were both asked to solve hierarchy continuity at the leaf. They could
only trade one failure for the other. Continuity now comes from folder surfaces themselves.

### 2. Tint expanded panels from the largest descendant content branch

The existing general resolver intentionally colors a directory from direct file children only; that
behavior remains unchanged for Cushion. Folders adds a separate representative lookup. At each
directory level it aggregates direct files by extension, compares the largest aggregate with the
largest child directory by on-disk bytes, and follows the winning directory branch until it reaches
files. Stable hash/index tie-breaks make the result deterministic.

The walk is bounded by tree depth, not subtree size, and its results are cached by layout and color
generation. That avoids per-directory descendant maps on multi-million-node trees and preserves
cheap style toggles.

An expanded panel carries 30% of the resolved directory color. The resolved directory color itself
contains 65% representative extension signal, so two production hues remain separated by about
19.5% on panels: enough to bridge grey-to-color discontinuities without making panels compete with
their leaves.

### 3. Collapsed folders remain content-bearing

A collapsed folder replaces all of the tiles it contains, so treating it like an expanded structural
panel would erase the only available content key. It retains 90% of its resolved directory color,
or about 58.5% of the raw representative signal, deliberately aligned with direct leaves' 60%.
Actually empty folders remain neutral.

### 4. Cushion remains the raw palette

The raw palette is not globally muted. Cushion relies on vivid color under shared lighting and is a
separate user-selected style. The extra descendant resolver and cache are Folders-only. The ordinary
resolved-color cache and Cushion's direct-child directory rule remain unchanged.

### 5. The Folders legend shows representative rendered colors

The always-visible File Types sidebar is explicitly the treemap's color key. While Folders is
selected, its swatches use the same direct-leaf transform at depth zero; while Cushion is selected,
they remain raw. A single legend cannot represent every depth shade, so depth zero is the documented
stable representative. The full file-type table and tree-row icons are analysis surfaces, not the
treemap key, and remain raw unless separately specified.

### 6. The browser demo follows the direct-leaf policy

The website claims its Cards toggle uses the app's renderer. Its direct and collapsed leaves must
apply the same 40% neutral blend when Cards is selected and leave Cushion unchanged. A named
JavaScript constant and helper make the parity testable instead of burying another independent
judgement in shader math. The browser demo does not claim parity for native panel nesting.

## Risks / Trade-offs

- Content-tinted folder panels add more color than the rejected neutral-only model. Their measured
  approximately 19.5% source separation keeps them subordinate to files.
- A depth-zero legend swatch is not pixel-identical to a deep tile. It is still truthful about hue
  and strength.
- Browser and Swift implementations could drift again. Contract tests pin the shared 0.40 factor and
  the presence of the Cards-only helper.

## Open Questions

None. The real-volume evidence rejects both a neutral-only hierarchy and the 25%-signal grey wash;
the three-role policy above makes the accepted distinctions explicit and testable.
