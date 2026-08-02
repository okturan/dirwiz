## Context

Folders has no cushion lighting, so hierarchy and extension colors must coexist through flat fills.
The installed real-tree evidence rejected two one-shot constant choices:

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

## Goals / Non-Goals

**Goals:**

- Give Okan ten meaningfully distinct choices in the real native view.
- Make each choice a production-renderer recipe, not an image filter or mockup.
- Include light-to-dark, dark-to-light, temperature, and alternating hierarchy alternatives.
- Keep extension colours byte-identical in every candidate.
- Repaint cheaply without changing layout, navigation, selection, or hit testing.
- Preserve Cushion byte-for-byte at the color-input boundary.

**Non-Goals:**

- Pretend a final scheme has already been selected.
- Make ten permanent product themes before the review decision.
- Replace/reorder the extension palette.
- Change card geometry, density, labels, overlays, or descendant selection.
- Deploy the website or publish a release from this comparison build.

## Decisions

### 1. Compare ten complete hierarchy palettes

Each recipe owns an explicit eight-colour folder table indexed by `depth & 7`. A table can brighten,
darken, or alternate; it is not constrained to `darkBase + depth * step`. Values are applied by the
existing Swift instance builder before the unchanged Metal shader.

| # | Name | Outermost surface | Depth behaviour |
|---|---|---|---|
| 1 | Pearl | light cool neutral | steadily darkens inward |
| 2 | Frost | medium ice blue | steadily lightens inward |
| 3 | Silver | middle neutral | alternates around the midpoint |
| 4 | Graphite | dark neutral | steadily lightens inward |
| 5 | Midnight | dark navy | lightens through blue-grey |
| 6 | Sand | light warm neutral | steadily darkens inward |
| 7 | Clay | medium terracotta neutral | steadily lightens inward |
| 8 | Sage | light muted green | steadily darkens inward |
| 9 | Lavender | light muted violet | steadily darkens inward |
| 10 | Ink & Paper | dark ink | deliberately alternates dark and light |

Every outer colour is pairwise distinct. Across the set, outer luminance spans light and dark; at
least one palette brightens, one darkens, and one alternates. This makes each option a different
hierarchy treatment rather than a different amount of the same wash.

### 2. File colours are not a theme variable

Direct files and collapsed content-bearing folders keep the raw extension palette in every scheme.
Expanded folder panels ignore descendant representative colour and use only the selected structural
depth table. This removes both mechanisms that produced the reported grey wash and coloured veil.
The comparison now asks one question only: which folder hierarchy best frames the unchanged data
colours?

An absent preference resolves to `1. Pearl`, whose light outer surface also directly falsifies the
reported “every option starts dark” failure.

### 3. Use one persisted selection and a temporary native picker

`AppState.foldersColorScheme` persists the integer in the injected defaults store and is not reset by
scans. The picker appears only while Folders is selected and names options `1. Pearl` through
`10. Ink & Paper`, making feedback unambiguous. It is a review affordance; after Okan selects a
winner, a follow-up decides whether to remove the picker or retain a smaller user-facing set.

### 4. Reuse caches; repaint instances only

All candidates use the same extension palette, overlay results, layout, and CardNesting output.
Changing scheme marks only the instance buffer dirty. It does not bump color generation or alter
the resolved-colour cache. The existing descendant representative cache remains available for
collapsed folders, which still stand in for their hidden content.

### 5. Keep Cushion and website scope explicit

Cushion ignores `FoldersColorScheme` and always receives the raw resolved palette. The File Types
legend is raw in both styles because file colours are no longer transformed. The local website demo
also keeps raw file colours while review is open; it is not deployed and will be aligned to the
chosen final folder palette after the native decision.

## Risks / Trade-offs

- Ten choices are too many for a final product control. This is intentional evaluation scaffolding.
- Recipe changes are cheap but still rebuild the visible instance buffer; tests pin that they do not
  invalidate layout or Cushion's resolved-color cache.
- Light folder panels make dark header chips and vivid files carry more contrast than before; the
  real-tree gate decides whether that is desirable rather than treating darkness as an invariant.
- A single screenshot may favor one volume's extension distribution. The picker persists so the
  same candidates can be checked on another volume before finalization.

## Open Questions

- Which numbered scheme does Okan select on the restored tree?
- After selection, should the picker disappear or should a smaller subset remain user-configurable?
