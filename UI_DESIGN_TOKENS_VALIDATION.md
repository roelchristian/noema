# Design token validation

UI.TK07 · 12 October 2026 · `dev/ui-design-tokens`

This report distinguishes automated native rendering from live keyboard, VoiceOver and window-server inspection. Passing compilation alone does not complete the visual acceptance gate.

## Reproduction and provenance

The pre-migration application source is commit `0046a9e`; the after application source is `8ebe0b9` (UI.TK06), before the nonvisual full-title tooltip integration follow-up. Captures were made on macOS 27.0 (26A428), arm64, with Apple Swift 6.2.4. The baseline archive is created with `git archive`; its application sources stay unchanged. The new `DesignTokenValidationTests.swift` fixture is copied into that archive solely to render equivalent states with the old APIs. Theme choice and light/dark are injected into the hosting environment. Increased contrast is supplied through the theme and high-contrast NSAppearance; this does not certify a live OS Increase Contrast toggle or propagation of every read-only SwiftUI accessibility environment value. SwiftUI accessibility environment properties are read-only in this SDK; Reduce Motion is not injected. Capture transactions disable animation solely to keep static snapshots stable. No theme/accessibility preferences are modified. The fixture bypasses `.systemNoemaTheme()` in both revisions and emulates only explicit theme/tint/background/scroll presentation. It therefore compares migrated view chrome under matching environments; it does not visually validate removal of the old `PaletteSurfaceModifier` global foreground override or the production preference/invalidation lifecycle. Semantic/source regression checks cover those changes separately. AppModel opens an isolated temporary vault with bookmark persistence disabled and local indexes placed in that temporary directory.

```sh
validation/ui-design-tokens/capture.sh
BASELINE_REF=0046a9e validation/ui-design-tokens/capture.sh "$PWD/validation/ui-design-tokens/generated/baseline"
python3 validation/ui-design-tokens/select-evidence.py
```

The opt-in capture creates 136 PNGs: seventeen fixture states × System/Midnight Iris × light/dark × standard/increased contrast. Ordinary test runs render all five page inspector tabs at the 280-point minimum in all eight appearances without writing screenshots. Bitmap checks reject flat/blank output and check raster dimensions; fitting-size checks establish the host bounds. Because the fixture applies a fixed outer frame, they do not establish descendant layout bounds or prove that every label is visible or every action is usable. Layout assessment relies on visual inspection of the rendered evidence.

Snapshots use NSHostingView attached to an offscreen borderless NSWindow. They render actual SwiftUI/AppKit view trees, including the native Sources Table and vault creation controls. They do not include the live titlebar, traffic lights, translucent composition against a desktop, menus, sheets attached to a live document window, or presented alerts. The creation snapshot shows sheet content with disabled controls and native buttons, not sheet presentation. The root toolbar adds a measured 32-point safe area: requested 960×620 ContentView fixtures have 960×652-point host rasters, and requested 1200×760 roots have 1200×792-point rasters. Inspector fixtures are exactly 280/340×620 points. The root captures therefore do not certify a live 960×620 outer window. Fixed-frame sheet captures include letterboxing around the content. Native accent, relative dates and font rendering follow the capture machine; these are provenance-recorded comparisons, not portable pixel-perfect golden assertions.

## Acceptance matrix

| Requirement | Evidence and result |
| --- | --- |
| Light, standard contrast | Rendered baseline/after custom chrome reviewed; native glass-control limitations remain below |
| Dark, standard contrast | Rendered baseline/after custom chrome reviewed; native glass-control limitations remain below |
| Light/dark, increased contrast | Rendered baseline/after high-contrast appearances reviewed; semantic palette text tests meet 7:1 and tested separators meet 3:1. Native glass controls remain pending live |
| System accent and Midnight Iris | All eight modes captured and reviewed; System uses the machine's current native accent, not a sweep of accent choices |
| Reduce Motion | Source inspection verifies guarded animation choices and suppression of large workspace transactions; static capture disables animations. Actual OS Reduce Motion and live animation timing pending |
| Small/minimum windows | Minimum-width sidebar/editor/inspector composition and all five inspector tabs reviewed; root safe-area limitation noted above. Real split-pane resizing pending |
| Sidebar, editor, Sources, inspector | Shared chrome, native Table and five inspector tabs rendered. Sidebar selection remains visible inactive. Document text fixture uses a locked editing page to prevent save side effects |
| Locked, empty and no-vault | All eight modes captured for each isolated state; no vault content appears in locked/no-vault views. Locked native glass-action legibility requires live verification |
| Keyboard navigation and VoiceOver | Pending live verification; no claim that NSHostingView screenshots establish accessibility behavior |
| Native controls, alerts and sheets | Native Table and creation-sheet controls visually reviewed; disabled Create Vault/Encryption are distinct. Live glass controls, alerts, native menus and sheet presentation pending |

Computer Use returned “Computer Use was not approved to use Noema Token Baseline” when attempting to select the isolated baseline app. The approved work therefore uses rendered fixtures and source/tests; real keyboard-only navigation, VoiceOver output and operating-system-specific appearance transitions remain explicitly unverified.

## Build and regression results

| Command / scope | Result |
| --- | --- |
| `./scripts/test.sh` after UI.TK06 | Exit 0; 244 tests in 26 suites passed in 38.062s; test build 96.30s; storage boundary guard passed |
| Baseline native matrix, `./scripts/test.sh --filter DesignTokenValidationTests` | Exit 0; 2 tests passed in 78.444s, including 136 PNG captures |
| Final native matrix, same command with screenshot directory | Exit 0; 2 tests passed in 36.813s; build 9.96s; 136 PNG captures |
| `./scripts/build.sh debug` packaged app | Exit 0; build 77.96s; signed `dist/noema.app` and produced `dist/noema.zip` |
| Shell syntax / Swift syntax / whitespace | Passed; capture selection script validated both complete matrices |

The full suite covers semantic color/state resolution, native system color preservation, contrast, geometry, existing inspector memory/link/selection regressions, Sources navigation, editor serialization and vault-session/storage behavior. The final opt-in run recompiles and tests the safe-area-aware screenshot harness added after that full-suite run. No application logic changed for that harness correction.

Initial fixture attempts caught read-only accessibility environment keypaths, native file-coordination restrictions inside the tool sandbox, and a 32-point toolbar safe-area mismatch in host assertions. These were corrected without changing application semantics. Native file tests then ran outside the tool sandbox with explicit approval; successful results above are from the corrected runs.

## Visual findings and reviewable evidence

Both revisions produced 136 complete, nonblank native rasters. Sixteen representative before/after pairs (32 PNGs, approximately 4.7 MiB) are committed under `validation/ui-design-tokens/evidence`; all 272 PNG names and SHA-256 hashes are recorded in `validation/ui-design-tokens/capture-manifest.json`. Full matrices remain locally available under ignored `generated/baseline` and `generated/after` directories.

The reviewed custom chrome shows common row/search/tab geometry, aligned inspector sections, distinct selected navigation, readable metadata and stronger boundaries in increased contrast. The minimum-width All Pages title truncates earlier because time metadata and the visible lock target consume row width. The integration follow-up adds the full title as a tooltip; complete text remains in the SwiftUI label, with real VoiceOver verification pending. The inspector's 280-point Properties layout keeps labels/actions visible and wraps timestamps naturally.

Native glass rendering prevents a complete legibility sign-off: in light offscreen document-header captures some native glass symbols are white/absent against the light canvas, and locked dark captures show black action labels against the dark backing. Similar artifacts occur in the pre-migration baseline. These controls require a real visible native window to distinguish offscreen composition limitations from product defects; the evidence does not establish either a regression or a fix. Native creation-sheet buttons/text fields/toggle and Table rows render clearly. Alerts, presented sheets and native menus are not captured.

| Example | Before | After |
| --- | --- | --- |
| System light workspace | [PNG](validation/ui-design-tokens/evidence/before/workspace-minimum-system-light-standard.png) | [PNG](validation/ui-design-tokens/evidence/after/workspace-minimum-system-light-standard.png) |
| System dark, increased contrast | [PNG](validation/ui-design-tokens/evidence/before/workspace-minimum-system-dark-increased.png) | [PNG](validation/ui-design-tokens/evidence/after/workspace-minimum-system-dark-increased.png) |
| Midnight light, increased contrast | [PNG](validation/ui-design-tokens/evidence/before/workspace-minimum-midnightIris-light-increased.png) | [PNG](validation/ui-design-tokens/evidence/after/workspace-minimum-midnightIris-light-increased.png) |
| Midnight dark workspace | [PNG](validation/ui-design-tokens/evidence/before/workspace-minimum-midnightIris-dark-standard.png) | [PNG](validation/ui-design-tokens/evidence/after/workspace-minimum-midnightIris-dark-standard.png) |
| Inspector minimum, increased contrast | [PNG](validation/ui-design-tokens/evidence/before/inspector-minimum-midnightIris-light-increased.png) | [PNG](validation/ui-design-tokens/evidence/after/inspector-minimum-midnightIris-light-increased.png) |
| Native Sources Table | [PNG](validation/ui-design-tokens/evidence/before/sources-native-table-system-light-standard.png) | [PNG](validation/ui-design-tokens/evidence/after/sources-native-table-system-light-standard.png) |
| Locked state | [PNG](validation/ui-design-tokens/evidence/before/workspace-locked-midnightIris-dark-standard.png) | [PNG](validation/ui-design-tokens/evidence/after/workspace-locked-midnightIris-dark-standard.png) |
| No-vault state | [PNG](validation/ui-design-tokens/evidence/before/workspace-no-vault-system-light-standard.png) | [PNG](validation/ui-design-tokens/evidence/after/workspace-no-vault-system-light-standard.png) |
| Native creation-sheet content | [PNG](validation/ui-design-tokens/evidence/before/vault-creation-sheet-content-midnightIris-dark-standard.png) | [PNG](validation/ui-design-tokens/evidence/after/vault-creation-sheet-content-midnightIris-dark-standard.png) |

## Deliberately retained style exceptions

The audited exceptions in `UI_DESIGN_TOKENS.md` remain the governing contract. Source inspection after UI.TK06 found no remaining fixed-size interface fonts or ad-hoc opacity-derived surface fills in the inspector panels/tab shell. Shared sidebar search/tabs/rows, library headings and inspector framing use semantic colors and named typography/metrics. Meaningful remaining literals include:

- Window and pane constraints, editor reading width/gutters and specialized modal dimensions remain component layout.
- Branding mark sizes, welcome heading and lock-symbol geometry remain identity/empty-state composition.
- Sources Table columns and native control sizes/selection remain platform-owned.
- Capsule badge optical offsets, zero-sized lifecycle bridges and native/optical hairlines remain local.
- Source category/unread marker colors (including the 8-point unread icon) and the orange 0.12 recovery warning banner retain status meaning; the banner has explanatory text. Its local 12/14-point padding remains document-status layout.
- Custom TeX settings, link-suggestion popover and recovery/import sheet layout are outside the shared chrome migration.

No new preference, density setting, theme engine or global interface font override was introduced. Native Table implementation, editorial font/layout, branding assets and vault/session/storage formats are preserved. Pending live checks remain separate from automated test success.

## Native-toolbar integration follow-up

The native-toolbar branch integrates main `b6cd5c7` with the token ownership contract preserved: custom chrome consumes semantic tokens; native toolbar/glass controls and window/pane geometry remain platform/component-owned. The historical evidence and manifest above retain their original source attribution. Current opt-in fixtures isolate pane preferences, retain the 136-image baseline via `NOEMA_LEGACY_TOKEN_FIXTURE`, and render 152 current images including the native workspace/welcome sizes. The merged suite passes 284 tests across 31 suites with all captures enabled. Refreshed live toolbar screenshots, representative minimum-size fixtures and the remaining manual accessibility checks are recorded in [native integration validation](docs/UI_TBR_VALIDATION.md).
