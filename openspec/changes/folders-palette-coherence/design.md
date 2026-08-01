## Context

The extension palette is intentionally vivid because Cushion lighting integrates those colors into
one surface. Folders has no cushion lighting. Its neutral nested panels and flat tile gradients make
the same palette look pasted on, especially when one extension owns a large part of a multi-terabyte
volume. The current Folders transform retains 45% of the original channel spread; the supplied real
scan shows that this remains the dominant visual signal.

## Goals / Non-Goals

**Goals:**

- Make folder structure visually primary and extension identity secondary in Folders.
- Preserve a stable, measurable amount of extension-color information.
- Keep Cushion pixel behavior unchanged.
- Make the legend and website Cards demo honest representations of the app.
- Cover the actual 17-color production palette.

**Non-Goals:**

- Replace or reorder the extension palette.
- Remove extension coloring from Folders.
- Change treemap layout, card nesting, hit testing, labels, or palette ranking.
- Retune temporal-diff or recency overlays.

## Decisions

### 1. Retain 25% of extension color around the parent chrome

Folders blends each leaf 75% toward the neutral tone of its parent container. Because the target is
the same neutral for every color at a given depth, this preserves exactly 25% of every pairwise RGB
distance and channel spread. The hue's channel ordering remains intact, but large same-extension
regions no longer overpower the folder hierarchy.

This is deliberately a larger change than the rejected 55% blend. The real-volume screenshot is the
acceptance evidence: 45% still produced saturated blue, red, green, and magenta fields. A 75% blend
turns those fields into tinted slate while leaving the extension key readable.

### 2. Cushion remains the raw palette

The raw palette is not globally muted. Cushion relies on vivid color under shared lighting and is a
separate user-selected style. The transform stays at Folders instance-build time, so style toggles
remain cheap and the cached resolved colors remain style-independent.

### 3. The Folders legend shows representative rendered colors

The always-visible File Types sidebar is explicitly the treemap's color key. While Folders is
selected, its swatches use the same transform at depth zero; while Cushion is selected, they remain
raw. A single legend cannot represent every depth shade, so depth zero is the documented stable
representative. The full file-type table and tree-row icons are analysis surfaces, not the treemap
key, and remain raw unless separately specified.

### 4. The browser demo follows the same policy

The website claims its Cards toggle uses the app's renderer. The demo must apply the same 75% neutral
blend when Cards is selected and leave Cushion unchanged. A named JavaScript constant and helper
make the parity testable instead of burying another independent judgement in shader math.

## Risks / Trade-offs

- Closely spaced source hues become subtler. That is intentional: Folders prioritizes hierarchy,
  while labels, the legend, search, and Cushion retain stronger identification.
- A depth-zero legend swatch is not pixel-identical to a deep tile. It is still truthful about hue
  and strength, unlike the current raw swatch.
- Browser and Swift implementations could drift again. Contract tests pin the shared 0.75 factor and
  the presence of the Cards-only helper.

## Open Questions

None. The real-volume result rejects the 45% retained signal; this change fixes the visual policy at
25% and keeps that number explicit.
