## Context

Folders has no cushion lighting, so its flat fills need one coherent colour semantic. The installed
real-tree evidence rejected two attempts to blend hierarchy and extension colours into one surface:

- 75% neutral leaf blend: extensions became grey.
- 40% neutral leaf blend plus a 30% accent from a 65%-resolved descendant color: leaves recovered,
  but expanded panels carried about 19.5% raw content signal. Across nested, large folders those fills
  form the all-over veil visible in the supplied 880 GB screenshot.

The renderer, not a palette swatch, is the meaningful evaluation surface. Card nesting changes how
much of every parent remains visible, large same-extension regions dominate perception, and depth
causes several structural fills to be seen simultaneously.

The first ten-option build supplied another real-tree result: it still looked like one scheme. Seven
options used the exact same dark `chromeBase` and `depthStep`; two made small cool/warm changes and
one was darker. Most selection changes adjusted how strongly file colours were pulled toward that
same neutral ramp. The deterministic test called these recipes distinct because their structs were
not equal, but it never asserted distinct outer surfaces or distinct depth sequences.

The replacement ten-option build then exposed two deeper shared defects. All ten still show broad
same-colour upper hierarchy fields that abruptly become unrelated extension colours, and some
data-heavy regions remain pale, nearly empty landscapes. A 100-by-100 fixture with half its bytes
in one file and half in 2,000 tiny files produces exactly 5,000 square points of non-background
output. The other 5,000 points are silently dropped by `minPixelSize` and reveal the parent panel.

The complete SpaceMonger reference path matters here. Its defaults set both `file_color` and
`folder_color` to the same eight-colour depth palette, so files do not switch to a second semantic
at the bottom of the hierarchy. Separately, `FolderView.cpp::SizeFolders`
recursively groups siblings and calls `AddDisplayFolder(..., index: -1, flags: 0)` for a group whose
rectangle cannot be subdivided. The placeholder has no false file identity or label, but it paints
the group's occupied area. DirWiz copied the folder threshold and recursive inset, not this aggregate
coverage rule.

## Goals / Non-Goals

**Goals:**

- Give Okan ten meaningfully distinct choices in the real native view.
- Make each choice a production-renderer recipe, not an image filter or mockup.
- Include light-to-dark, dark-to-light, temperature, and alternating hierarchy alternatives.
- Give every Folders card one coherent depth-colour semantic from root through leaf.
- Keep collectively significant content visible when individual descendants fall below density.
- Resolve anonymous aggregate interaction to its owning folder rather than a made-up file.
- Keep raw extension colours and their meaning unchanged in Cushion.
- Repaint cheaply without changing layout, navigation, selection, or hit testing.
- Preserve Cushion byte-for-byte at the color-input boundary.

**Non-Goals:**

- Pretend a final scheme has already been selected.
- Make ten permanent product themes before the review decision.
- Replace/reorder the extension palette used by Cushion and analysis surfaces.
- Replace DirWiz's squarify algorithm with SpaceMonger's historical binary splitter.
- Claim that Folders is an extension-colour view; its sidebar must state that map colours show depth.
- Deploy the website or publish a release from this comparison build.

## Decisions

### 1. Compare ten complete map palettes

Each recipe owns an explicit eight-colour table indexed by `depth & 7`. The same table applies to
folder backgrounds, direct files, collapsed folders, and density aggregates. Values are applied by
the existing Swift instance builder before the unchanged Metal shader.

| # | Name | Source / character | Depth behaviour |
|---|---|---|---|
| 1 | SpaceMonger | reference `BoxColors` base row | eight-hue source sequence |
| 2 | Ocean | navy, blue, cyan, teal | cool high-contrast cycle |
| 3 | Forest | pine, moss, leaf, earth | natural multi-hue cycle |
| 4 | Sunset | plum, magenta, red, gold | warm chromatic progression |
| 5 | Spectrum | cyan through violet and warm hues | full-spectrum cycle |
| 6 | Candy | bright playful hues | strong adjacent contrast |
| 7 | Earth | clay, sand, olive, teal, slate | muted multi-hue cycle |
| 8 | Nord | restrained cool colours | muted cycle with red accent |
| 9 | Monochrome | neutral | alternating light and dark |
| 10 | Ink & Paper | tinted near-black and light paper | alternating light and dark |

Every outer colour is pairwise distinct and every adjacent pair within a recipe has material RGB
distance. This makes each option a complete map treatment rather than a different amount of one
wash.

### 2. One color semantic spans the whole Folders tree

SpaceMonger's defaults select the depth table for both files and folders. Folders now does the same:
every visible card at depth `d` uses the selected recipe's `d & 7` colour. Extension identity remains
available in Cushions, the Extensions analysis, Search, and the File Types breakdown. It is not mixed
into Folders, because that creates the rejected abrupt transition from broad hierarchy fields to
red/blue leaves.

An absent preference resolves to `1. SpaceMonger`, which is traceable to the reference source rather
than another invented neutral ramp.

### 3. Use one persisted selection and a temporary native picker

`AppState.foldersColorScheme` persists the integer in the injected defaults store and is not reset by
scans. The picker appears only while Folders is selected and names options `1. SpaceMonger` through
`10. Ink & Paper`, making feedback unambiguous. It is a review affordance; after Okan selects a
winner, a follow-up decides whether to remove the picker or retain a smaller user-facing set.

### 4. Reuse caches; repaint instances only

All candidates use the same layout and CardNesting output. Changing scheme marks only the instance
buffer dirty. It does not bump color generation or alter Cushion's resolved-colour cache. Folders no
longer walks descendant extensions to invent a panel accent, which also removes that rebuild cost.

### 5. Keep Cushion and website scope explicit

Cushion ignores `FoldersColorScheme` and always receives the raw resolved palette. In Folders, the
sidebar shows the selected eight-colour depth key above the File Types breakdown and explicitly says
the map colours show depth. The file rows keep raw category swatches for filtering; they are no longer
presented as the Folders map key. The local website is not deployed during native review.

### 6. Preserve occupied area at the density cutoff

`SquarifyLayout` emits an aggregate rectangle for each contiguous sibling region whose individual
items fall below `minPixelSize` but whose union is still visible. The rectangle carries one real
child as a unique bookkeeping anchor and the actual owning folder for interaction. It is not a
fabricated filesystem node.

Folders paints that aggregate with the selected colour for its depth, so occupied data cannot
masquerade as a parent-depth empty field. Aggregate rectangles receive no filename label, and a hit
resolves to the owning folder, matching SpaceMonger's anonymous-placeholder semantics. Cushion does
not draw these Folders aggregates and keeps its existing rendered rectangles and color inputs.

### 7. Give every card its own contrast boundary

The 892 GB installed result confirms that one depth semantic and aggregate occupancy repair the
earlier discontinuity and empty-landscape failures. It also makes the remaining renderer defect
unambiguous: DirWiz discards the rounded gap to reveal whatever saturated parent colour happens to
sit behind it, then shades the whole card with one soft diagonal gradient. Adjacent surfaces can
therefore merge, and bright cards retain low-contrast white labels.

`FolderView.cpp::MinimalDrawDisplayFolder` uses three separate roles instead. It first draws a black
outer box, then `DrawDualBox` supplies a bright top/left and dark bottom/right edge, and only then it
fills the base colour. DirWiz mirrors those roles in the existing Metal card branch. The boundary
lives inside the shader's drawn area, so `CardNesting`, `displayRects`, `SpatialGrid`, and the rule
that visual gaps remain clickable do not change. Edge decoration fades in with card size so dense
small rectangles remain coloured content rather than becoming black lines.

The flat centre also gives label contrast a deterministic input. Folders selects whichever of black
or white has the larger WCAG contrast against the scheme's depth colour. Cushion and post-palette
recency or temporal overlays keep white because their final shaded colour is not the raw depth table.

## Risks / Trade-offs

- Ten choices are too many for a final product control. This is intentional evaluation scaffolding.
- Recipe changes are cheap but still rebuild the visible instance buffer; tests pin that they do not
  invalidate layout or Cushion's resolved-color cache.
- Very light reference colours use measured black-or-white label polarity; folder headers retain
  their dark chips because they can span several differently coloured descendants.
- Strong outlines can overwhelm dense regions. The shader fades edge treatment out between the
  plain-fill floor and full-size cards, and the offscreen test keeps sub-floor cards fully occupied.
- An aggregate intentionally trades per-file identity for honest occupied area below the legibility
  threshold. It is non-selectable as a fake file; zooming its owner reveals the underlying detail.
- A single screenshot may favor one volume's nesting shape. The picker persists so the same
  candidates can be checked on another volume before finalization.

## Open Questions

- Which numbered scheme does Okan select on the restored tree?
- After selection, should the picker disappear or should a smaller subset remain user-configurable?
