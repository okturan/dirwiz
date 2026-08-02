## 1. Record the failed candidates honestly

- [x] 1.1 Pin the 75% neutral blend as rejected because it retained only 25% palette separation.
- [x] 1.2 Implement and test the 60%-leaf / descendant-panel candidate without changing Cushion.
- [x] 1.3 Inspect that candidate on the restored real tree and record the supplied 880 GB screenshot
  as a failed native visual gate: nested panel tint creates an all-over color veil.

## 2. Build the native comparison set

- [x] 2.1 Add exactly ten numbered `FoldersColorScheme` recipes spanning neutral, low-accent,
  cool, warm, dark, and the rejected tinted control.
- [x] 2.2 Default to `1. Clean`, with zero panel accent and full-strength direct-file colors.
- [x] 2.3 Thread the selected recipe through the Swift instance builder and Folders legend while
  leaving layout, CardNesting, overlays, hit testing, and Cushion inputs unchanged.
- [x] 2.4 Persist the selected number through the injected defaults store and scan reset.
- [x] 2.5 Add a temporary numbered picker beside the Folders toggle, visible only in Folders.

## 3. Deterministic gates

- [x] 3.1 Assert there are exactly ten sequential, named, pairwise-distinct recipes.
- [x] 3.2 Run every recipe across all 17 production colors; require channel-order preservation,
  at least 60% channel spread, and proportional pairwise separation.
- [x] 3.3 Pin the rejected `7. Tinted` panel/collapse strengths as the comparison control.
- [x] 3.4 Prove every Folders scheme produces identical raw color at the Cushion boundary.
- [x] 3.5 Keep deep descendant selection, collapsed-folder, shader, nesting, and hit-testing gates.

## 4. Local website baseline

- [x] 4.1 Set the local Cards demo leaf transform to Scheme 1's zero blend while selection is open.
- [x] 4.2 Keep the helper Cards-only and preserve Cushion and hero-animation behavior.
- [ ] 4.3 Inspect desktop and mobile website renders before any deployment.
- [ ] 4.4 After a native winner is selected, align and re-verify the website before publishing.

## 5. Verification and selection

- [x] 5.1 Run focused card-style, treemap-color, extension-palette, and website contract tests.
- [x] 5.2 Run the full suite, `CI=true` parity, and strict OpenSpec after the comparison implementation.
- [x] 5.3 Build, install, and relaunch the local app from a clean recorded commit.
- [ ] 5.4 On the restored multi-million-item tree, confirm the picker changes the actual native view
  and Scheme 1 removes the reported dark outer surface and panel veil.
- [ ] 5.5 Okan selects a numbered winner; do not remove the picker or call the palette final before it.

## 6. Replace the false comparison model

- [x] 6.1 Record Okan's native finding: every option starts with dark outer-folder chrome and mostly
  changes the strength or progression of one shared visual system.
- [x] 6.2 Replace base-plus-step recipes with ten explicit eight-level hierarchy palettes whose
  depth-zero colours and complete trajectories are genuinely distinct.
- [x] 6.3 Keep direct files and collapsed content-bearing folders at raw production colour in every
  option; remove descendant tint from every expanded panel.
- [x] 6.4 Strengthen deterministic tests to require distinct outer colours, full depth tables, light
  and dark starting points, multiple trajectory directions, and raw file-colour identity.
- [x] 6.5 Run focused, full, `CI=true`, and strict OpenSpec verification after the replacement.
- [x] 6.6 Commit, build, install, and relaunch the clean local comparison build before asking Okan to
  choose again.
