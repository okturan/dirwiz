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

## Goals / Non-Goals

**Goals:**

- Give Okan ten meaningfully distinct choices in the real native view.
- Make each choice a production-renderer recipe, not an image filter or mockup.
- Include no-tint, low-tint, temperature, and contrast alternatives.
- Keep extension identity readable in every candidate.
- Repaint cheaply without changing layout, navigation, selection, or hit testing.
- Preserve Cushion byte-for-byte at the color-input boundary.

**Non-Goals:**

- Pretend a final scheme has already been selected.
- Make ten permanent product themes before the review decision.
- Replace/reorder the extension palette.
- Change card geometry, density, labels, overlays, or descendant selection.
- Deploy the website or publish a release from this comparison build.

## Decisions

### 1. Compare ten bounded recipes

Each recipe owns chrome base, depth step, direct-leaf neutral blend, expanded-panel accent, and
collapsed-folder neutral blend. Strengths are applied by the existing Swift instance builder before
the unchanged Metal shader.

| # | Name | Leaf blend | Panel accent | Structural character |
|---|---|---:|---:|---|
| 1 | Clean | 0% | 0% | Current slate, neutral panels, raw leaves |
| 2 | Crisp | 12% | 0% | Neutral panels, lightly settled leaves |
| 3 | Balanced | 28% | 0% | Neutral panels, calmer leaves |
| 4 | Whisper | 10% | 6% | Barely tinted panels |
| 5 | Soft | 18% | 12% | Small content bridge |
| 6 | Bridge | 25% | 18% | Visible but bounded bridge |
| 7 | Tinted | 40% | 30% | Rejected installed treatment, retained as control |
| 8 | Cool Slate | 10% | 0% | Cooler blue-grey structure |
| 9 | Warm Graphite | 10% | 2% | Warmer graphite structure |
| 10 | Dark Contrast | 0% | 0% | Dark neutral structure, raw leaves |

No leaf blend exceeds 40%, so every candidate retains at least 60% source channel spread and
pairwise RGB distance. Candidate 7 is not endorsed; it makes the failure directly comparable.

### 2. Default to the falsifiable no-veil baseline

An absent preference resolves to Scheme 1. Its panel accent is exactly zero, so it cannot reproduce
the reported subtree veil through representative colors. This gives the next screenshot a clean
control rather than silently preserving the rejected candidate.

### 3. Use one persisted selection and a temporary native picker

`AppState.foldersColorScheme` persists the integer in the injected defaults store and is not reset by
scans. The picker appears only while Folders is selected and names options `1. Clean` through
`10. Dark Contrast`, making feedback unambiguous. It is a review affordance; after Okan selects a
winner, a follow-up decides whether to remove the picker or retain a smaller user-facing set.

### 4. Reuse caches; repaint instances only

All candidates use the same extension palette, overlay results, descendant representative cache,
layout, and CardNesting output. Changing scheme marks only the instance buffer dirty. It does not
bump color generation or force a descendant walk, because the cached representative color is an
input shared by every recipe.

### 5. Keep Cushion and website scope explicit

Cushion ignores `FoldersColorScheme` and always receives the raw resolved palette. The File Types
legend applies the selected leaf recipe only in Folders. The local website demo uses Scheme 1's zero
leaf blend while review is open; it is not deployed and will be aligned to the chosen final recipe
after the native decision.

## Risks / Trade-offs

- Ten choices are too many for a final product control. This is intentional evaluation scaffolding.
- Recipe changes are cheap but still rebuild the visible instance buffer; tests pin that they do not
  invalidate layout or Cushion's resolved-color cache.
- A single screenshot may favor one volume's extension distribution. The picker persists so the
  same candidates can be checked on another volume before finalization.

## Open Questions

- Which numbered scheme does Okan select on the restored tree?
- After selection, should the picker disappear or should a smaller subset remain user-configurable?
