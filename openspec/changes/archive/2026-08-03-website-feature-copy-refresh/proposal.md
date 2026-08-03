## Why

The homepage hero currently leads with “each one as a rectangle, sized by the space it actually
takes on disk.” That is implementation copy, not a reason to use DirWiz, and it reads awkwardly in
the most valuable sentence on the page. The feature grid also trails the product: it omits the
living view and says almost nothing about the native macOS controls already visible in the app.

## What Changes

- Replace the hero paragraph with outcome-first copy about finding space, comparing changes, and
  moving unwanted files to Trash.
- Keep allocated-block accuracy as supporting technical proof lower on the page, not hero copy.
- Add the living view and native Mac controls to the feature grid.
- Update snapshots copy from a single saved baseline to the current checkpoint timeline with pins.
- Distinguish the macOS menu bar from the window toolbar and name only controls that exist.
- Refresh page metadata to match the current product story.
- Gate publication on the downloaded release artifact so unreleased source-only work is not
  advertised as already available.

## Capabilities

### New Capabilities

- `website-product-presentation`: The public site's hero, feature inventory, Mac-control claims,
  metadata, and release-truth requirements.

### Modified Capabilities

<!-- None. -->

## Impact

- `docs/index.html`: hero, feature grid, metadata, and current feature descriptions.
- Website contract tests: rejected phrase, required feature claims, control terminology, links, and
  release-truth guard.
- No scanner, UI behavior, or release artifact changes.
