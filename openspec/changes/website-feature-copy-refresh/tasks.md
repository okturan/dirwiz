## 1. Establish product truth

- [x] 1.1 Inventory the current homepage feature claims against `README.md`, `DirWizApp.swift`,
  `ContentView.swift`, and the active OpenSpec list.
- [x] 1.2 Record the native control split: menu bar = Find and Go navigation; window toolbar =
  recency, snapshot pin, temporal diff, CSV/JSON export, and legend visibility.
- [x] 1.3 Identify source-only features and exclude them from claims about the current public release.

## 2. Rewrite the page

- [x] 2.1 Replace the hero's “sized by the space it actually takes on disk” sentence with the exact
  outcome-first paragraph from `design.md`.
- [x] 2.2 Add concise `Living view` and `Mac-native controls` cards.
- [x] 2.3 Update snapshots copy to describe the compressed checkpoint timeline, arbitrary comparison,
  and pins without turning the card into implementation documentation.
- [x] 2.4 Refresh description and social metadata so they name current headline capabilities.
- [x] 2.5 Keep allocated-block accuracy in the technical proof sections and keep all safety claims
  exact.

## 3. Contract and visual verification

- [x] 3.1 Add a contract test that rejects the old hero phrase and requires the new hero and feature
  titles.
- [x] 3.2 Assert menu-bar and window-toolbar wording matches the source inventory.
- [ ] 3.3 Render the page at desktop and mobile widths; verify the nine-card grid, line breaks,
  navigation, live demo, and download block.
- [x] 3.4 Check local links/assets and run `openspec validate --all --strict`.
- [x] 3.5 Before deployment, download the public release and verify every new feature claim against
  that artifact; do not publish source-only claims. Verified against a fresh v1.2.1 download
  (build 13, tag/source `c69542d`, SHA-256 `0acc8061…13f09`): the tagged source and shipped binary
  contain the named living view, snapshot timeline, Find/Go menu commands, recency, temporal diff,
  CSV/JSON export, legend, search, duplicates, hardlinks, insights, warm start, and shared CLI.
