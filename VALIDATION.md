# Validation — 10 October 2026

Environment: Apple Silicon Mac, macOS 27.0; Swift 6.2.4; macOS SDK 26.2.

## Page header cleanup — one-minute timebox

- Removed the Personal wiki label and its icon. The header starts with the page title unless an editing reminder is present; source labels and read-only indicators remain.
- `./scripts/build.sh debug` compiled and packaged successfully; `git diff --check` passed. Native inspection in an isolated temporary vault confirmed the header starts with the title and the toolbar controls remain. No content was edited. Regression, appearance/accent changes, and full accessibility checks were not run for this label/layout change.

## New page compose icon

- Replaced the plus-and-title presentation with the native `square.and.pencil` compose symbol. The existing page-creation menu keeps its New page tooltip and accessibility label.
- `./scripts/build.sh debug` compiled and packaged successfully; `git diff --check` passed. After relaunch, native accessibility inspection confirmed the New page menu uses `square.and.pencil`. No page content was edited. No regression suite, appearance/accent changes, or full accessibility checks were run for this icon-only change.

## Toolbar lock and New page control — two-minute timebox

- Moved lock/unlock into the native top toolbar group between Edit/Done and Trash. New page shows its plus symbol and title with the native rounded-rectangle border shape, producing a wider control instead of a circular icon-only button.
- `./scripts/build.sh debug` compiled and packaged successfully; `git diff --check` passed. Native inspection in an isolated temporary vault confirmed the toolbar placement and wider New page control. Lock changed to Unlock and disabled Edit; unlocking restored Edit. No demo content was changed.
- No regression suite was run for this control-placement/style change. Checks used current Light appearance; live appearance/accent changes, full VoiceOver, and accessibility-preference combinations remain unverified.

## Pages section and Noema display name

- Renamed the library section, heading, and search label to Pages; page creation uses New Page / Blank page. Visible app branding, window title, application menu, About panel, appearance copy, and mark accessibility label use Noema.
- `./scripts/build.sh debug` compiled and packaged the app and archive successfully with macOS icon-service access after restricted packaging failed at `iconutil`. `plutil -lint Resources/Info.plist` and `git diff --check` passed. No regression suite was run for this copy-only change.
- Native checks in an isolated app identity and temporary empty vault verified the Noema welcome/window/menu/About panel, Pages sidebar/heading/empty state, and Search pages accessibility label. The existing app also displayed Noema and Pages after rebuilding. No demo content was edited. Checks used current Light appearance; appearance/accent changes, editing states, and full VoiceOver/accessibility-preference combinations were not exercised.

## Block spacing and icon alignment — 3-minute UI timebox

### Follow-up: first-character caret stability

- Removed the custom insertion-point drawing that placed an empty block's caret lower than the native typing line. Empty block accents and backgrounds now use the native line position, accounting for paragraph spacing when the block follows other content.
- `./scripts/test.sh` passed all 40 entries (optional benchmark not executed). Focused coverage checks native insertion and decoration bounds before and after typing the first character in basic paragraph, heading, bullet, quote, code, and semantic blocks after an existing paragraph. `./scripts/build.sh debug` packaged the app and archive; `git diff --check` passed.
- Native Light appearance inspection in the separate `/tmp/Noema-Suggestion-Acceptance/Test Vault` showed the empty semantic accent and caret level with each other, then still level after typing the first character. Basic block typing was covered automatically; native Dark appearance, accent changes, and VoiceOver remain unverified for this change.

### Follow-up: compact slash menu from reference image

- The slash menu is 240 points wide, with 24-point command rows, aligned 16-point icon slots, native menu material, readable native label color, tighter section spacing, and a 405-point maximum height with scrolling. The initial menu still shows the basic/semantic divider and the first semantic commands.
- `./scripts/test.sh` passed all 40 entries (optional benchmark not executed), including width, maximum height, row spacing, icon/title clearance, section structure, and command selection. `./scripts/build.sh debug` packaged the app and archive successfully; `git diff --check` passed.
- Native Light appearance checks used the separate `/tmp/Noema-Suggestion-Acceptance/Test Vault` and verified the narrower menu, denser rows, title alignment, readable text, divider, and colored semantic icons. The final 405-point trim follows that visual check; Dark appearance, appearance/accent changes, and full VoiceOver interaction remain unverified.

### Follow-up: empty semantic caret — 2-minute timebox

- Empty semantic blocks draw the insertion caret at the same text bounds as their accent, excluding paragraph padding from its vertical position and height. Native caret color, blinking, horizontal position, and drawing are retained; populated blocks and ordinary empty paragraphs use their existing caret geometry.
- `./scripts/test.sh` passed all 40 entries (optional benchmark not executed), including empty semantic caret alignment for paragraph, heading, quote, and code presentations and unchanged ordinary paragraph geometry. `./scripts/build.sh debug` packaged the app and archive successfully; `git diff --check` passed.
- Live visual inspection, appearance changes, and VoiceOver checks for this adjustment were not performed within the timebox.

### Follow-up: command icon/text alignment — 2-minute timebox

- Native command button cells use a shared 20-point icon column with an 8-point gap before titles, keeping every title's leading edge aligned regardless of symbol width.
- `./scripts/test.sh` passed all 39 entries (optional benchmark not executed), including title alignment, icon clearance, and bounds containment at two row widths. `./scripts/build.sh debug` packaged the app and archive successfully; `git diff --check` passed.
- Live visual inspection and appearance/accessibility checks for this final spacing adjustment were not performed within the timebox.

### Current follow-up: vertical-only suggestions and trailing accent bounds

- Replaced the slash popover with a native nonactivating `NSPanel`, preserving editor keyboard focus. Its frame uses the visible editor's screen rectangle, chooses above/below the slash according to available room, and reduces height with scrolling when neither side fits the full menu. It has no lateral fallback. Initial selection reveals the section heading; outside clicks, editor scrolling, window moves/resizes, and view teardown dismiss it.
- Accent/background bounds now use the font ascender/descender on each occupied line, excluding trailing blank lines and layout spacing. Empty blocks still get a single-line accent. Stored text, including deliberate trailing whitespace/newlines, is retained without migration or removal.
- Final `./scripts/test.sh`: 39 entries passed (optional benchmark not executed). New coverage checks vertical placement and containment near the top/middle/bottom and in narrow views, plus content-bound accents for paragraph/heading/quote/code blocks with trailing blank lines and lossless capture. `./scripts/build.sh debug` packaged the app and archive; `git diff --check` passed. Brand assets were unchanged.
- Native acceptance used a separate bundle identity and `/tmp/Noema-Suggestion-Acceptance/Test Vault`. Confirmed a full menu below the text near the top, above it near the bottom, leading alignment, the initial Basic blocks heading/selection, filtering with colored semantic icons, Return execution while retaining editor focus, and a single-line semantic accent after adding a following block. The test app was closed after verification; the user's open demo vault was not used for mutations.
- These native checks used the current Light appearance. Dark appearance, system accent/appearance changes during editing, full VoiceOver navigation, and accessibility-preference combinations remain unverified for this follow-up.

### Initial spacing change

- Semantic presentations now show icons without visible name/status labels outside the article margin. Basic list/task/toggle markers sit inside the margin, with matching click positions. Semantic blocks, quotes, callouts, and code receive increased top/bottom spacing; callout/code backgrounds receive increased vertical padding. Accessibility names and statuses are retained.
- `./scripts/test.sh` passed all 34 test entries (the optional benchmark entry skipped its benchmark). Rendering coverage checks extra spacing, nested marker clearance, wrapped-text indentation, and semantic metadata retention in both theme variants.
- `./scripts/build.sh debug` successfully packaged `dist/noema.app` and `dist/noema.zip`; `git diff --check` passed. Initial restricted runs were blocked by macOS file coordination/pasteboard and icon services; the successful runs had access to those services.
- Live visual inspection of the updated package in a temporary vault, appearance/accent changes, and VoiceOver interaction were not completed in this timebox.

### Follow-up: block terminator and slash menu

- Block decoration bounds exclude a nonempty block's terminating newline, preventing an added block from extending the preceding semantic accent into an empty line. No Markdown content is removed.
- Slash palette width reduced to 260 points; rows show command titles with details in tooltips/accessibility labels. Basic/semantic headings have a native separator, and semantic symbols/colors come from the shared registry. The anchor uses the caret rectangle, menu width, and available screen space to choose above or below.
- Final `./scripts/test.sh` passed all 36 entries (optional benchmark not executed), including semantic split/capture/decorative bounds and compact palette sections, matching, and keyboard selection. `./scripts/build.sh debug` packaged the app and archive successfully. `git diff --check` passed; generated brand assets had no changes.
- Live menu positioning near screen edges, native icon-color appearance, and VoiceOver interaction remain unverified within the under-3-minute timebox.

### Follow-up: suggestion alignment while typing — under 2 minutes

- The slash menu now anchors to the slash's insertion rectangle and updates its content size and positioning rectangle as the query changes. It reopens on the opposite edge when available space requires it; horizontal clamping keeps the anchor within the editor's leading edge even in narrow views.
- `./scripts/test.sh` passed all 37 entries (optional benchmark not executed), including a new anchor geometry regression covering leading alignment, line height, right-edge clamping, and narrow editor bounds. Live visual typing and appearance/accessibility interaction remain unverified in this timebox.
- `./scripts/build.sh debug` successfully packaged the app and archive; `git diff --check` passed. Generated brand assets were unchanged.

### Follow-up: click to edit and lock reminder — under 2 minutes

- A single article-area click starts editing; native mouse handling still places the caret/selects text. A locked click keeps editing disabled and shows a caption beside the lock: “Article locked. Unlock it to edit.” A future-format read-only article gets a read-only message instead. The reminder clears when a note is loaded/unlocked or editing starts. Recovery notices remain separate.
- `./scripts/test.sh` passed all 38 entries (optional benchmark not executed), including edit activation, repeated-click idempotence, locked feedback without edit activation, and activation after unlocking. `./scripts/build.sh debug` packaged the app and archive successfully; `git diff --check` passed. Brand assets were unchanged.
- Live single-click caret placement, lock-reminder appearance, appearance/accent changes, and VoiceOver interaction remain unverified within this timebox.

### Follow-up: slash-menu spacing — under 2 minutes

- Command rows have 32-point height with 5-point gaps, 12-point horizontal and 14-point vertical outer padding, and extra space around section headings and separators. Menu height accounts for the larger rows/sections and caps at 480 points with scrolling; width stays 260 points.
- `./scripts/test.sh` passed all 38 entries (optional benchmark not executed), including palette section, filtering, keyboard-selection, and anchor regressions. `git diff --check` passed. Live visual spacing and appearance/accessibility checks remain unverified within this timebox.
- `./scripts/build.sh debug` packaged the app and archive successfully; generated brand assets were unchanged.

## Block editor — current validation

The block editor was implemented within the user’s one-hour cap, including interrupted work. The sections below this one retain historical validation; the previous app-specific Midnight Iris appearance preference has been replaced by system appearance and dynamic AppKit colors.

- Final `./scripts/test.sh`: 33 test entries passed (32 functional checks plus the optional benchmark entry, skipped in the ordinary run). Added coverage includes rich/nested JSON round trips, external text overriding stale metadata, future-version read-only behavior, malformed data retention, two-space/tab indentation, repeated legacy UUIDs, structure/tag independence, split/merge/list exit, nested moves/duplicates, collapsed content, slash matching/query removal, selection-preserving formatting, Markdown/RTF paste, emoji insertion, typing/command undo, duplicate/delete/reorder undo and redo, and cross-block selection preserving surviving descendants.
- The 1,000-block render/capture/serialization/reload pipeline took 115 ms in the final run. This is a pipeline measurement, not a sustained typing latency or frame-rate benchmark.
- Explicit `VAULT_BENCHMARK=1 ./scripts/test.sh --filter benchmarkFiveThousandEntries` passed: scan 13.72 s, index 5.73 s, cached load 54.50 ms, search p95 34.89 ms with 5,000 results. Search omits the editor envelope, and a changed derived-index revision forces rebuilding previous cached wiki rows.
- Native checks used a separate app identity and `/tmp/Noema-Block-Acceptance`, preserving the user’s demo vault. Observed existing Markdown headings/lists/tasks/quote/code/divider, all ten semantic icons and labels, a question retaining bullet structure and answered status, callout presentation, toggle collapse with children retained on disk and after relaunch, caret-adjacent `/h2` filtering, Return execution with query removal, heading creation, list continuation/exit, autosave/reload, and editing/splitting/merging at the end of a 1,000-block document. Automated insertion separately verifies emoji; the computer-use keyboard mapper substituted punctuation for the emoji in its rapid-input sequence.
- The final native surface was inspected in the Mac’s current Dark appearance and native blue selection/accent. The user’s system settings were not changed. Automated rendering covers both theme variants, but final live Light appearance, changing system appearance/accent while editing, full VoiceOver navigation, and accessibility preference combinations remain unverified.
- Native drag attempts reached valid sibling targets but did not produce a completed drop/reorder. The drag handle, scoped pasteboard, insertion drawing, and shared reorder/undo commands are implemented; deliverable 18 is **not accepted**. Keyboard/menu reorder is the available path, with automated undo/redo coverage. Further native drag diagnosis is required.
- Tables, images, and unsupported HTML remain literal rather than receiving dedicated editors. RTF attachments retain original RTF in metadata for recovery. Multi-block drag is not implemented. Two-Mac iCloud acceptance remains outstanding.

- Final `./scripts/build.sh release` succeeded, producing `dist/noema.app` and `dist/noema.zip`. The ZIP was extracted outside iCloud and passed `codesign --verify --deep --strict`. `git diff --check` passed; temporary drag diagnostics were removed. The app is locally ad-hoc signed, not notarized.

### Requested deliverables

| # | Result and evidence |
|---|---|
| 1 | Compatibility decision recorded in `BLOCK_EDITOR.md`; existing changes preserved. |
| 2 | UUID/tree/rich runs/metadata/timestamps model; automated coverage passed. |
| 3 | Lossless versioned envelope, source spelling, external-edit recovery; tests passed. |
| 4 | Paragraph/headings/lists/quote/tasks implemented; Markdown import tests and native checks performed. |
| 5 | Code/divider/callout/toggle implemented; rendering tests and native checks performed. |
| 6 | Shared core mutations preserve runs, identity, and children; tests passed. |
| 7 | Native typing plus document/selection command undo; create/transform/delete/reorder checks passed. |
| 8 | Split/merge/empty-list exit covered by tests and native editing. |
| 9 | Continuous native navigation plus indent/outdent; model/caret checks passed; exhaustive held-key stress remains. |
| 10 | Fuzzy matching, aliases, grouped palette; tests and native filtering passed. |
| 11 | Arrow/Return/Escape handlers and query removal; automated/native execution covered. |
| 12 | All specified block prefixes registered and tested. |
| 13 | Bold/italic/underline/strike/code/highlight/links; selection and rich-run tests passed. |
| 14 | Plain/Markdown/RTF paste and recovery of unsupported content; tests passed. |
| 15 | Ten editable, labeled semantic presentations; registry tests and native visual checks performed. |
| 16 | Independent semantic tags and optional statuses survive structure changes/reload; tests and native checks passed. |
| 17 | Shared context actions implemented; duplication/deletion/move/indent tests passed. End-to-end OS block-link launch remains unverified. |
| 18 | Native drag **incomplete**: attempts did not complete a drop. Reorder commands and undo/redo pass. |
| 19 | Partial acceptance: Dark/native input checked; live Light/theme/accent changes and full accessibility pass remain. |
| 20 | Regression, 5,000-page benchmark, 1,000-block pipeline/native edit, and documentation completed; packaging result recorded below. |

## Automated

- Release regression suite passed: 13 functional checks, plus the optional benchmark entry (not executed without `VAULT_BENCHMARK=1`).
- Covered semantic YAML preservation, exact source bytes/checksums, malformed data, code-excluded wiki links/tags, title aliases, duplicate identity quarantine, external moves, stale edits/deletions, recoverable trash, disk-save failures, draft reopening, search, backlinks, rebuilding indexes, incomplete sources, and vaults inside hidden parent folders.
- A separate release run executed the 5,000-page benchmark successfully: initial scan 13.68 s; initial index 6.01 s; cached load 43.53 ms; search p95 35.41 ms, returning all 5,000 matches across 20 searches.
- Search passed the 150 ms target; cached service loading passed the two-second target. End-to-end cached app launch timing is not formally measured.

## Native UI

Initial local checks verified creating a vault via a folder picker, creating a personal page, editing a title/body/tags, autosave, Markdown reading preview, inline tag discovery, and following an unresolved link to create a page.

The final release build verified folder switching through an attached native picker, restoring the selected vault after relaunch, pasted-source capture and a non-editable source viewer, backlinks between the Pertinax/Rome demo pages, and a live external Markdown edit appearing automatically in the reading view. The demo vault is included under `Examples`.

Packaging produces a local ad-hoc signed `.app` and an archive without extended attributes. The iCloud-backed Documents folder can attach Finder information to an app bundle after launch, which makes strict signature verification of that in-place bundle fail; the clean archive is verified after extraction outside iCloud.

## Liquid Glass and orbital identity update

- Reviewed Apple's [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and custom-view guidance. Glass remains concentrated in navigation and controls; page text, source originals, and metadata retain standard content backgrounds.
- Release compilation passed. The existing 13 functional checks passed; the optional benchmark entry returned without running the benchmark. The sandboxed test attempt could not use macOS file coordination; rerunning with access to that service passed the suite.
- Native UI checks verified the glass search field, ⌘K focus, search clearing, Edit / Read toolbar control, Markdown preview, source navigation, grouped source actions, and the non-editable original text viewer. Glass control groups rendered without overlap in the observed window.
- The orbital mark uses native SwiftUI Liquid Glass, with shared filled geometry for its SVG layer and packaged icon. Icon previews were inspected at 128 and 1024 pixels, including open ring centers and rounded orbit endpoints.
- Reduce Transparency and increased contrast have explicit opaque-logo fallbacks; native controls handle their own accessibility adaptations. System accessibility preference combinations and a full VoiceOver pass remain unverified; light/dark appearance checks are recorded below.
- This command-line build ships the updated flattened `.icns` Dock icon. SVG foreground/background layers are ready for Icon Composer; system-rendered layered icon appearances require Icon Composer and an Xcode app target, which are unavailable here. See `Resources/Brand/README.md`.

## Midnight Iris appearance update

- Added the eight supplied semantic light/dark tokens in `Sources/NoemaBrand/MidnightIris.swift`, shared by SwiftUI, native text views, and the icon generator. Text variants are derived toward the palette's primary text rather than substituting unrelated hues.
- Four new checks verify sRGB contrast calculation, AA contrast for primary/muted/accent text against both content surfaces, increased-contrast variants, and readable white/off-white labels on derived control fills. All passed along with the existing 13 functional checks (18 test entries total, including the optional benchmark that did not run).
- Native UI verified Light and Dark preferences, immediate recolouring of the existing Markdown preview, matching editor foreground/background colours, and Dark remaining selected after quitting and relaunching. System is the default and uses `preferredColorScheme(nil)` to follow macOS. Switching from Light to System restored the Mac’s current dark appearance; the preference was left on System after checks. No macOS appearance settings were changed.
- Native selection backgrounds remain platform-managed. Selected library rows use primary text for legibility; topic icons/chips use violet and relationship links use cyan. The search placeholder uses an accessible, non-interactive themed label because macOS ignored its custom native placeholder colour.
- Native controls and glass materials retain system activation, focus, hover, disabled, and accessibility behaviour. The custom orbital mark has explicit opaque fallbacks for Reduce Transparency and increased contrast. Contrast tests validate solid token surfaces; a full VoiceOver and system accessibility-preference combinations pass remains outstanding.
- Exported light/dark SVG layers and the Midnight Iris `.icns` icon share the same palette and geometry. The app currently has wiki pages, topics, sources, and backlinks; no knowledge graph renderer exists. Graph highlight/relationship roles are available for future use without adding a new graph feature during this styling change.

## Not yet verified

- Two-Mac iCloud Drive transport, offline concurrent edits, cloud-only placeholders, and real `NSFileVersion` cloud conflicts. Automated stale-file conflict tests passed, but these do not establish cross-device sync reliability.
- System accessibility preference combinations (Reduce Transparency / Reduce Motion) and full VoiceOver navigation. Standard native controls/materials are used; no custom animation or glass renderer is present.
- Formal end-to-end app launch benchmark and long-document typing performance.

## Two-Mac acceptance procedure

1. Open the same iCloud Drive vault on two Macs signed into the same account. Wait for files to download.
2. Create a page on Mac A; confirm its body, tags, links, and identity appear on Mac B.
3. Edit different pages offline on both Macs. Reconnect and confirm both edits arrive without data loss.
4. Edit the same page offline on both Macs. Reconnect; confirm conflict files/recovery controls preserve both texts. Recover a draft as a new page and inspect the disk version.
5. Import a source on Mac A and compare its checksum/bytes on Mac B. Test a cloud-only note/source and download/unavailable notices.
6. Rename a page, check its old-title links, then move it to trash. Confirm changes arrive on the other Mac and restore its Markdown file from `.Trash`.

Until this procedure passes, iCloud support is implemented but cross-device behavior remains unverified.

## Page row swipe actions — 2026-10-10

- Page rows use native trailing swipe actions for Delete and leading actions for Lock/Unlock, with context-menu alternatives. Delete confirms the captured page identity and uses recoverable vault trash. Actions on another row preserve the current selection.
- `./scripts/test.sh` passed all 40 existing test entries (optional benchmark not executed). `./scripts/build.sh debug` packaged the app and archive successfully. Restricted initial attempts could not use macOS file coordination, pasteboard, or icon services; reruns with service access passed.
- Added a regression for trashing a locked page while preserving its original bytes and another page; `./scripts/test.sh --filter trashLockedPagePreservesBytesAndOtherPages` passed. `git diff --check` passed. Native gesture execution in a temporary vault, appearance/accent changes, accessibility adaptations, and VoiceOver were not exercised within the requested timebox.

## Compact article margins — 2026-10-10

- Reduced the shared reading/editor horizontal text inset from 152 to 80 points per side. Code-language labels now fit inside the narrower gutter, keeping the block handles and semantic icons clear of article text.
- `./scripts/build.sh debug` compiled and packaged the app and archive successfully. `./scripts/test.sh` passed all 41 entries (optional benchmark not executed); `git diff --check` passed. Generated brand assets were unchanged.
- Native Light appearance inspection used the isolated `local.noema.suggestion-check` app and `/tmp/Noema-Suggestion-Acceptance/Test Vault`: confirmed the narrower reading and editing layouts and visible semantic-icon clearance. No page content was edited. Appearance/accent switching, accessibility-preference combinations, full VoiceOver, and code-language label interaction were not manually exercised.
