# Validation — 10 October 2026

Environment: Apple Silicon Mac, macOS 27.0; Swift 6.2.4; macOS SDK 26.2.

## Source summary metadata and context-menu icons — 11 October 2026

- Source context menu uses native Rename/pencil and Delete/trash labels without ellipses. Existing rename and named deletion dialogs remain in place.
- Each queued upload/link now starts topic-title and summary inference concurrently in separate on-device sessions. Title rules still use the shared article generator; summaries use its existing concise, language-preserving summarizer. Both read the same extracted content, bounded to 6,000 characters, and persist together in one coordinated metadata write. Optional `aiSummary` is compatible with existing records without the field; manual renames preserve it. Empty summaries or changed prior summary/title/identity/checksum/bookmark/path reject writes. The table and source reader do not display the metadata summary. Existing unavailable/unreadable-content and manual-override behavior remains: no enrichment is saved if generation fails or is superseded.
- Final `./scripts/test.sh` passed all 65 entries with macOS service access. New coverage verifies title/summary persistence and trimming, summary preservation after manual rename, original filename/bytes, stale rejection, and empty-summary rejection. `./scripts/build.sh debug` compiled, packaged, and signed the app/archive successfully. `git diff --check` passed; generated brand assets were unchanged. Existing demo-vault edits and user-created sources were preserved.
- Live concurrent Apple Intelligence output, performance relative to title-only inference, native menu icon rendering, queue interaction, appearance/accent/accessibility, and cross-Mac checks were not verified within the requested two-minute timebox. No claim of faster inference is made; titles remain based on the original extracted content rather than the generated summary.

## Source context actions and shared article titling rules — 11 October 2026

- Source inference calls the same `OnDeviceSummary.pageTitle` as articles: central-topic noun phrase, ideally 2–6 words and at most 8, detected language, Markdown cleanup, greedy sampling, and the same response budget. Text/Markdown source input now uses the article block-document normalization; HTML markup is stripped first. No alternate source prompt is introduced.
- Native source context menu adds Rename and Delete. Rename changes vault metadata only for imported and linked sources; original names/bytes remain unchanged. Pending AI naming yields to these manual actions. Named deletion confirmation distinguishes removing a link from permanently deleting an imported original and metadata. Repository deletion coordinates source-directory access and checks stale metadata, imported-byte checksums, symbolic-link paths, and unresolved metadata/original conflicts. Deleted-source windows close; renamed windows update their title; refresh reconciles Sources/search.
- Final `./scripts/test.sh` passed all 64 entries with macOS service access. New tests cover removing a linked record while preserving its external original and another source, refusing to recreate deleted metadata via rename, imported-original deletion, and refusal of stale/mutated imports. Existing rename/size/original tests passed. `./scripts/build.sh debug` compiled, packaged, and signed the app/archive successfully; generated brand assets were unchanged. `git diff --check` passed. Existing demo edits and source records were preserved.
- Native menu, rename dialog, destructive confirmation, reader-window reactions, live source title inference, appearance/accent/accessibility, and cloud conflict version acceptance were not manually verified within the requested two-minute timebox. Source imported deletion is permanent after confirmation; it does not enter page Trash.

## Source sizes and queued on-device display names — 11 October 2026

- Source table columns begin File Name and Original File Name, followed by Location, Kind, Size, and Captured. Canonical byte sizes are saved for new records and derived during scans for existing ones. Pending rows show Generating title with a mini spinner; the footer shows muted Renaming n of n files progress. Accepted sources enter the table before inference.
- Add Source accepts at most five files per picker submission and rejects folders. The former folder-limit setting is removed; existing source records remain readable. Linking remains the default; the 2 MB import limit remains enforced. One AppModel queue serializes Apple Intelligence topic naming, using text/Markdown/HTML content and PDFKit-extracted PDF text. Display names are coordinated metadata updates; original filenames/bytes are retained. Stale metadata rejects the generated title. Vault changes clear queued work. Unavailable AI or unsupported/empty extracted content retains the original display name with a notice; pending names are session-local.
- `./scripts/test.sh` passed all 62 entries with native macOS service access, including new source title persistence, byte/size/identity preservation, and rejection of stale rename results. Existing folder rejection and import-size checks passed. `./scripts/build.sh debug` compiled, packaged, and signed the app/archive successfully; generated brand assets were unchanged. `git diff --check` passed. Existing demo-vault edits and user-created source records were preserved.
- Live source AI inference, queue ordering/progress under concurrent imports, native multi-file picker/limit, immediate row presentation, PDF extraction quality, appearance/accent/accessibility, and cross-Mac checks were not manually exercised under the requested two-minute timebox. Other binary formats provide no naming text and retain the original display name. Quit does not wait for this new source-title queue; a source retains its original saved name if quit interrupts inference.

## Sources without embedded preview, Add Source, and native reader windows — 11 October 2026

- Sources now uses a sidebar plus full-width native table, without the embedded preview pane. Add Source opens one native picker, defaulting to linking, with an unchecked Import into vault checkbox. File imports reject more than 2,000,000 bytes in both the picker path and repository. Folder imports are rejected; folder linking retains the configurable membership limit. Source table selection is independent of wiki selection, and opening a reader waits for the current page save.
- Markdown/text/HTML open in separate native read-only NSTextView windows (Markdown/HTML attributed rendering); PDFs and other formats use QLPreviewView. Security scopes stay active until windows close; imported-reader loads check the original checksum. Binary sources preserve original bytes and have no extracted search body. Older app versions cannot load binary records. UTF-8 remains required for text formats; unsupported Quick Look formats may have no preview.
- Final `./scripts/test.sh` passed all 61 entries with macOS service access, including exact 2 MB acceptance, rejection above the boundary with no published record, binary imported/linked byte preservation, empty derived binary bodies, and HTML content scanning. Final-source compilation passed. Final `./scripts/build.sh debug` compiled, packaged, and signed the app/archive successfully; generated brand assets were unchanged. `git diff --check` passed. Existing demo-vault edits and sources created by the running user app were preserved.
- Native picker, checkbox, Sources layout/selection, reader rendering/window lifecycle, Quick Look interaction, appearance/accent/accessibility, and cross-Mac permissions were not manually verified under the requested three-minute timebox. Automated checks establish repository behavior and compilation, not end-to-end reader presentation. The existing app read-write picker entitlement limitation for linked access remains as recorded below.

## Linked file and folder sources — 11 October 2026, requested two-minute timebox

- Added Vault → Link File or Folder and a creation-menu action. External UTF-8 `.txt`/`.md` originals remain outside the vault and are never written by linking/scanning. Persisted bookmarks request security-scoped read-only access. Folder membership is captured recursively once; all files count toward Settings → Sources → Max number of files in linked source (default 10). Over-limit, unsupported, or invalid text fails validation before publishing records. Source Location uses a link icon or in-vault tray icon. Refresh from Files reloads linked content; external locations are not watched.
- `./scripts/test.sh` passed all 59 entries with macOS service access, including recursive folder-limit rejection with no published records and external source byte preservation, no copied original, stable identity, and refreshed external changes. The first new-test run failed because the fixtures omitted creating their nested vault directories; corrected fixtures passed. `./scripts/build.sh debug` compiled, packaged, and signed the app/archive successfully. `git diff --check` passed; generated brand assets were unchanged. Existing demo-vault edits were preserved.
- Native picker/Settings/table flows, permission persistence after sandboxed relaunch, read-only permission enforcement, appearance/accent/accessibility, and cross-Mac bookmark behavior were not manually verified. The app retains its existing user-selected read-write entitlement for editable vaults; the new bookmarks request read-only access, while the picker’s initial temporary grant is governed by that app entitlement. Bookmarks are Mac/app-specific; stale/unavailable links surface notices. Older app versions cannot load metadata-only linked records; existing imported records remain compatible. No claim of cross-device linked-source access.

## Sources table correction — 11 October 2026, two-minute timebox

- Replaced the compact file column with a native SwiftUI Table. Name, Filename, Kind, and Captured columns support header sorting and resizing; initial sort is ascending Name. Source selection continues to open the read-only preview, and search uses the existing filtered rows. Table headers remain visible with no sources. The source pane uses a 620-point ideal width (520-point minimum, 850-point maximum).
- Final `./scripts/build.sh debug` compiled, packaged, and signed the app/archive successfully. `./scripts/test.sh` passed all 57 entries with macOS service access; `git diff --check` passed. Generated brand assets were unchanged. No storage or format changes; existing demo-vault edits were preserved.
- Native table interaction, visual sizing, appearance/accent switching, accessibility preferences, and VoiceOver checks were not performed within the explicit timebox.

## Sources column view — two-minute timebox

- Sources now defaults to a compact Finder-style file column beside the existing read-only preview. Native rows display a document icon, source title, original filename, and disclosure chevron. The source column has a 280-point ideal width and 240-point minimum; native selection, keyboard navigation, search, and split-view resizing use the existing controls. No source storage or format changes.
- `./scripts/build.sh debug` compiled, packaged, and signed the app/archive. `./scripts/test.sh` passed all 57 entries with macOS service access; initial restricted runs encountered file-coordination/pasteboard errors and iconutil packaging restrictions. `git diff --check` passed; generated brand assets were unchanged. Existing demo-vault edits were preserved.
- Native visual/interaction checks in a temporary vault, appearance/accent switching, accessibility preferences, and VoiceOver were not performed within the explicit timebox.

## Main-pane document controls — one-minute follow-up

- Moved document controls and adjacent creation/vault menus into the third pane's page/source header. The title and controls share a vertically centered native HStack. Empty selection retains creation/vault controls at the top of the third pane.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully after rerunning with macOS icon-service access (initial restricted packaging reported Invalid Iconset). `git diff --check` passed. Existing demo-vault edits were preserved.
- Native visual/layout, editing interactions, appearance/accent switching, accessibility, and regression checks were not performed within the explicit timebox.

## Compact pane headers — one-minute timebox

- Removed the native window-title branding from the middle pane. Page/source title fonts are 26 points (previously 32), including title editing; header top padding is 8 points (previously 28), with 20-point bottom spacing.
- `./scripts/build.sh debug` compiled and linked successfully, but packaging stopped at `iconutil` with Invalid Iconset in the restricted environment. `git diff --check` passed. Existing demo-vault edits were preserved.
- Native layout/alignment, theme/accent switching, accessibility, and regression checks were not performed within the explicit timebox. Toolbar alignment is not visually verified; packaging remains incomplete.

## Padded list rows, dates, and summary previews — three-minute timebox

- Page/source rows have 12 points of additional horizontal padding and 10 points of vertical padding. Page update times and source capture times appear beside titles, using a localized time today or date otherwise; missing metadata leaves the date empty. Saved, nonempty AI summaries provide the two-line preview with a sparkles icon. Other rows show opening plain content, excluding the block metadata envelope.
- `./scripts/test.sh` passed all 57 entries with native macOS service access, including new summary preference, empty-summary fallback, plain-content, and date checks. `./scripts/build.sh debug` compiled, packaged, and signed the app and archive successfully. Initial restricted checks encountered file-coordination/pasteboard failures and iconutil access limits; reruns passed. `git diff --check` passed; generated brand assets were unchanged.
- Native visual/interaction, appearance/accent switching, accessibility preferences, and VoiceOver checks were not performed within the timebox. Existing demo-vault edits were preserved.

## Optional semantic block headings

- Added **Settings… → Block display → Show semantic block headings**, off by default. Turning it on shows semantic names above block text in reading and editing views while retaining the colored icons and accents. The app-wide preference persists across relaunch; headings are display decoration and do not enter page content, selection offsets, or copied text.
- `./scripts/test.sh` passed all 46 entries (optional benchmark not executed), including new coverage for all semantic types across paragraph, heading, list, task, toggle, quote, and code structures; multiline spacing; repeated on/off rendering; lossless capture; selection preservation; and empty-block typing/undo. Initial restricted regression runs lacked file-coordination/pasteboard access; final runs used required macOS services. `./scripts/build.sh debug` packaged the app and archive successfully with icon-service access; `git diff --check` passed. Generated brand assets were unchanged.
- Native checks used a separate test app and temporary vault in current Dark appearance: verified default-off Settings control, enabled headings in reading view, editing and undo, switching back to icon-only during editing, and enabled preference after quitting/relaunching. The final five-point heading alignment correction is covered automatically; its packaged output was not separately inspected. Existing demo-vault edits were preserved.
- Light appearance, live appearance/accent switching, accessibility-preference combinations, full VoiceOver interaction, and two-Mac iCloud checks were not performed.

### Heading alignment follow-up — two-minute timebox

- Heading placement now uses the native first glyph position, including the text container origin and line-fragment offset, instead of adding padding to the block's decorative bounds. The regression checks alignment against the native insertion rectangle across semantic types and block structures.
- `./scripts/test.sh` passed all 46 entries (optional benchmark not executed); `./scripts/build.sh debug` packaged the app and archive; `git diff --check` passed. Native Dark appearance inspection of the rebuilt isolated app in the temporary vault confirmed Idea, Question, Important, and Reference headings align with their body text. Appearance/accent switching and full accessibility checks were not repeated.

## Wider middle pane

- The page/source/Trash list uses a 385-point minimum and ideal width, with a 490-point maximum. The sidebar retains its 220-point ideal width, giving approximately the requested 1.75 ratio at the default sidebar width. Native split-view resizing remains available.
- `./scripts/build.sh debug` compiled and packaged successfully; `git diff --check` passed. Native inspection in the isolated UI-check app and temporary Test Vault confirmed sidebar width 220 and middle width 384.5 points, plus readable page selection, editor, and toolbar layout in current Dark appearance. No content was edited; generated brand assets were unchanged.
- No regression suite was run for this width-only change. Appearance/accent switching, minimum-window sizing, accessibility preferences, and full VoiceOver interaction were not exercised.

## Missing Trash folder — three-minute fix

- Recreate `.Trash` if it disappears while the vault is open, before listing trash or moving a page there. This prevents the new Trash refresh from aborting page-list/search reconciliation after page creation. Successful page creation also clears an earlier error banner. Existing demo edits were preserved.
- `./scripts/test.sh` passed all 44 entries (optional benchmark not executed), including a temporary-vault regression that removes `.Trash`, creates/saves a page, removes the folder again, then trashes/restores the page with its bytes preserved. The final `./scripts/build.sh debug` packaged the app and archive successfully; `git diff --check` passed. Initial restricted runs lacked macOS file-coordination, pasteboard, and icon-service access; final validation used service access.
- Live native UI, appearance/accessibility, and two-Mac iCloud checks were not performed within this timebox. The running app must be reopened to load the rebuilt binary.

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

## Locked-page list indicator — one-minute timebox

- Locked wiki pages display the native `lock.fill` symbol beside the list title, with a tooltip and VoiceOver label. The indicator follows the note's lock state and uses the existing semantic foreground color.
- `./scripts/build.sh debug` compiled and packaged the app and archive successfully; `git diff --check` passed. Brand assets were unchanged. No new tests were added for this localized visual change.
- Native UI verification could not proceed because the isolated UI-check app was unavailable to computer use. Lock/unlock visual transitions, appearance/accent changes, and accessibility interaction were not exercised within the timebox.

## Trash recovery menu — four-minute timebox

- Added Trash below Sources, backed by the existing `.Trash` folder and showing Restore and Delete permanently controls and context-menu actions. Permanent deletion requires a named-page confirmation. Storage uses coordinated access, checks stale hashes and path containment, and preserves bytes on restore. Active UUID/title collisions block restore; unresolved cloud versions block permanent deletion. Vault format remains v1.
- `./scripts/build.sh debug` packaged the app and archive successfully. `./scripts/test.sh` passed all 43 entries (optional benchmark not executed), including new restore identity/byte preservation, permanent deletion, stale-file rejection, and path/duplicate safety checks. `git diff --check` passed.
- Native checks used the isolated UI-check app and temporary Test Vault in current Dark appearance: verified sidebar placement, Trash count, visible actions/context menu, Restore returning a disposable page to Pages, and the named-page permanent-deletion confirmation. Final permanent deletion was covered automatically; no agent UI confirmation was submitted. No demo content was changed. Appearance/accent switching, full VoiceOver, accessibility preferences, and two-Mac iCloud checks remain unverified.


## On-device AI summaries — 2026-10-10

- Added an opt-in Apple Intelligence setting, manual Summarize action, native progress indicator, and a persisted semantic Summary rendered above the editable article with an AI-generated label.
- Full regression suite passed: 48 tests, including summary metadata round-trip/replacement and preservation when editable content is replaced. Restricted first run encountered file-coordination and paste access failures; rerunning with macOS access passed.
- Debug compilation and app packaging/signing passed with macOS access. Restricted packaging encountered an iconutil access error. Generated brand assets have no tracked changes.
- Foundation Models availability probe returned available. A synthetic live-generation probe was started but did not finish within the four-minute timebox; end-to-end AI output remains unverified.
- Native UI interaction was attempted but the vault chooser did not respond. Manual summary/progress/settings/relaunch, appearance/accent/accessibility, and two-Mac iCloud checks remain outstanding. Existing demo-vault changes were not edited by this task.


## AI summary loading position — 2026-10-10

- Moved the native summary progress indicator from the page header into the article area, immediately below the title/header divider, using the summary text margins.
- `./scripts/build.sh debug` compiled, packaged, and signed the app successfully; `git diff --check` passed. No regression rerun or new tests for this localized layout-only change. Generated brand assets were unchanged.
- Native UI validation used the isolated `local.noema.spinner-check` app and `/tmp/noema-ai-vault` synthetic content. Enabled summaries through Settings, clicked Summarize, and verified the native spinner and Generating AI Summary... text below the title in the article area, with Summarize disabled while generating. Current Dark appearance only; appearance/accent switching and accessibility preference combinations were not exercised. End-to-end generated output was not checked in this follow-up. The user's running app and demo content were not edited.


## Centered summary loading and scroll collapse — 2026-10-10

- Centered the native Generating AI Summary... spinner in its summary-area container. Scrolling beyond 24 points collapses the pinned summary to one caption-sized truncated line with Show; Hide collapses manually. Manual Show stays expanded during further scrolling, and returning to the top expands it. Separate thresholds avoid repeated layout toggles. No animation is introduced.
- `./scripts/test.sh` passed all 49 tests, including scroll/manual disclosure transitions. `./scripts/build.sh debug` compiled, packaged, and signed the app; `git diff --check` passed. Generated brand assets were unchanged.
- Native checks used the isolated `local.noema.collapse-check` app and `/tmp/noema-summary-scroll-vault`: verified automatic collapse on a 45-paragraph page, a small single-line excerpt with ellipsis, Show remaining expanded during continued scrolling, Hide and return-to-top expansion, and centered loading indicator during generation. Current Dark appearance only; alternate widths, appearance/accent switching, full VoiceOver, and accessibility preference combinations were not manually checked within the three-minute timebox. No user demo content was edited.


## Summary loading line, deletion, and clear glass — 2026-10-10

- Loading now uses a centered native spinner and text in one horizontal line. Expanded and collapsed summaries use native clear Liquid Glass; both expose an accessible trash action. Deletion uses the existing autosave path, preserves written/nested blocks, rejects future formats, and is disabled while locked or generating.
- `./scripts/build.sh debug` compiled, packaged, and signed the app. `./scripts/test.sh` passed all 50 tests, including summary deletion/content preservation and a summary-only document. The initial new test failed to compile because Swift Testing cannot expand a mutating call inside its expectation; fixed by evaluating the result first. `git diff --check` passed and generated brand assets were unchanged.
- An isolated native validation app launched, but summary interaction/visual verification did not fit within the two-minute timebox. Spinner layout, both glass states, deletion, appearance/accent changes, Reduce Transparency/increased contrast, and full VoiceOver remain manually unverified for this change. No demo content was edited.


## Full-width frosted summary and Delete label — 2026-10-10

- Replaced the rounded Liquid Glass card with native ultra-thin material covering the full summary width and padding between the dividers in expanded and collapsed states. Replaced the trash icon with a caption-sized Delete text control, retaining its accessible name and lock/generation guards.
- `./scripts/build.sh debug` compiled, packaged, and signed the app successfully; `git diff --check` passed. Generated brand assets were unchanged. No new tests or regression rerun for this localized styling/copy change.
- Native visual, alternate appearance/accent, Reduce Transparency, increased contrast, and VoiceOver checks were not performed within the one-minute timebox. Demo content was not edited.


## Compact AI summary loading line — 2026-10-10

- Removed the loading row's 96-point minimum height and reduced vertical padding to 8 points. The centered spinner/label uses its natural single-line height; no empty result block is reserved. The existing summary rendering remains conditional on persisted generated content, so a new Summary block appears only after successful generation.
- `./scripts/build.sh debug` compiled, packaged, and signed the app successfully; `git diff --check` passed. Generated brand assets were unchanged. No new tests or regression rerun for this localized spacing-only change.
- Native visual and appearance/accessibility checks were not performed within this one-minute task. Demo content was not edited.


## Smooth summary disclosure — 2026-10-10

- Summary collapse/expansion now uses a 250 ms ease-in/ease-out layout animation and opacity transitions for the expanded text and compact excerpt. Both scrolling and Show/Hide share the transition. macOS Reduce Motion disables the animation.
- `./scripts/build.sh debug` compiled, packaged, and signed the app; `git diff --check` passed. Generated brand assets were unchanged. No new tests or regression rerun for this localized animation-only change.
- Native motion, scroll position during animation, appearance/accessibility checks, and Reduce Motion toggling were not visually exercised within the one-minute timebox. Demo content was not edited.


## Smaller, muted summary loading indicator — 2026-10-10

- Changed the native spinner to mini control size and its label to callout typography with the adaptive secondary foreground color. The existing single-line centered layout is retained.
- `./scripts/build.sh debug` compiled, packaged, and signed the app successfully; `git diff --check` passed. Generated brand assets were unchanged. No new tests or regression rerun for this typography-only change.
- Native visual, appearance/accent, increased contrast, and VoiceOver checks were not performed within the one-minute timebox. Demo content was not edited.


## Final AI summary regression before commit — 2026-10-10

- Reran `./scripts/test.sh` against the final smaller indicator, compact loading, frosted summary, and smooth disclosure changes: all 50 tests passed with native macOS access. `git diff --check` passed. Manual visual/accessibility limitations recorded above remain outstanding. Demo-vault edits are excluded from the feature commit.


## Automatic on-device page titles — 2026-10-10

- New unnamed pages are tracked for this session; finishing editing, saving, navigation, app deactivation, and quit attempt a Foundation Models title after saving content. User titles and changes made during inference are preserved. Filename/alias behavior uses the existing repository save path.
- Initial debug compilation passed; packaging was blocked by sandbox iconutil access (Invalid Iconset). Final regression rerun with native macOS service access passed all 51 tests, including final-source compilation, after an incremental run was interrupted by a source edit. Added title-output validation coverage. `git diff --check` passed.
- Live title generation, lifecycle/navigation UI, model-unavailability flows, accessibility, and cross-device checks remain unverified. Demo-vault edits were preserved.


## Background title generation and language — 2026-10-10

- Title inference now runs per page after its content save, allowing immediate navigation and saving the captured page without requiring active selection or app focus. Quit waits for pending attempts. Repository stale-write, deletion, and lock checks remain in force; active unsaved edits reject results. Switching vaults discards pending results from the earlier vault.
- NaturalLanguage detects the article language with the system preferred language as fallback. Generated titles are parsed into plain text to remove Markdown headings, emphasis, links, and inline code; multiline/empty/overlong results are rejected.
- `./scripts/test.sh` passed all 53 tests with macOS service access, including inactive-page eligibility, user-title preservation, language fallback/detection, and Markdown cleanup. `./scripts/build.sh debug` compiled, packaged, and signed the app and archive successfully. `git diff --check` passed; generated brand assets have no tracked changes.
- Live Foundation Models output, background navigation/quit UI, appearance/accessibility, and two-Mac behavior were not exercised within the two-minute timebox. Existing demo-vault edits were preserved. Eligibility remains session-local.


## Explicit-save title eligibility — 2026-10-10

- ⌘S / Save Page and top Done/checkmark now explicitly register blank or numbered Untitled placeholders for naming, including reopened pages. User titles remain untouched. Both actions use the existing background generation/save path.
- `./scripts/test.sh` passed all 54 tests, including reopened placeholder recognition, blank titles, and preservation of user titles. `git diff --check` passed. `./scripts/build.sh debug` compiled, packaged, and signed the app and archive successfully.
- Native shortcut/top-button interaction and live AI generation were not exercised within the one-minute timebox. Demo-vault edits were preserved.


## Topic-title prompt correction — 2026-10-10

- Replaced the broad descriptive-title prompt with explicit central-topic naming: a specific noun phrase, ideally 2–6 words and at most 8, anchored to the actual page subject. It excludes summaries, explanatory sentences, generic labels, preambles, and formatting. Title generation uses greedy sampling with a 48-token response budget and rejects results exceeding eight whitespace-separated words. Language detection and Markdown cleanup remain intact.
- `./scripts/test.sh` passed all 55 entries (the live-model acceptance test returns unless explicitly enabled). `NOEMA_AI_TITLE_ACCEPTANCE=1 ./scripts/test.sh --filter onDeviceTopicTitleAcceptance` passed on synthetic pages, producing “Pertinax's Reign” and “Composting Routine”; composting is absent from the prompt's examples. An earlier synthetic sourdough probe produced “Sourdough Starter Care” and passed as well. These checks verify subject retention, word limit, plain text, and no ending period for those samples; they do not establish quality on every article or language.
- `./scripts/build.sh debug` compiled, packaged, and signed the app and archive; `git diff --check` passed. Generated brand assets had no tracked changes. Native save/navigation UI and broader multilingual title quality were not checked in this prompt-only change. Demo-vault edits were preserved.


## Unread title-change dot — 2026-10-10

- Added a native SF Symbol blue dot beside wiki-row titles when a rename occurs on another page or while the app is inactive. Generated titles, local saves, and external refresh title changes share tracking. Opening the page (or reactivating the app with it displayed) clears its indicator. State is session-local and clears on vault switching. The dot uses systemBlue and exposes a tooltip and VoiceOver label.
- Added coverage for other-page and inactive-app renames, unchanged titles, focused-page suppression, and clearing only viewed pages. `./scripts/test.sh` passed all 56 entries with macOS service access. `./scripts/build.sh debug` subsequently completed compilation, packaging, and signing of the app and archive successfully. `git diff --check` passed.
- Native visual/interaction, appearance/accent/accessibility, and live background-title checks were not performed within the timebox. Existing demo-vault edits were preserved.

## Source metadata and AI summary sidebar — 2026-10-11

- Single selection now displays a resizable native split-view inspector to the right of the source table, showing saved metadata and AI-generated summary, generation progress, or an explicit unavailable state. Double-click uses the existing table primary action to open the separate read-only native reader/Quick Look window; Open Preview remains available in the context menu.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully with native macOS access. `./scripts/test.sh` passed all 65 tests with native macOS access (optional benchmark/live-model acceptance not enabled). Initial restricted runs encountered iconutil packaging and native coordination/paste test access failures. `git diff --check` passed; generated brand assets were unchanged.
- Implementation was completed within the requested two-minute scope; native-access validation retries extended the work beyond that boundary. Manual single/double-click, resizing, theme/accent, accessibility preferences, and VoiceOver checks were not performed. Existing demo-vault changes were preserved. No storage format or inference changes.

## Manual source AI summary generation — 2026-10-11

- Added Generate AI Summary / Regenerate AI Summary in the source context menu and below the inspector's AI summary heading. Controls follow saved summary presence, disable during inference, and show manual generation progress while retaining any prior summary. Manual inference shares automatic source text extraction and persists through coordinated stale-checked metadata writes without changing the title or original bytes. Vault switches discard pending results.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully. `./scripts/test.sh` passed all 66 tests with native macOS access, including new summary regeneration/title/checksum/original-byte preservation and stale-summary rejection coverage. Optional benchmark/live-model acceptance were not enabled. `git diff --check` passed; brand exports were unchanged.
- Manual context-menu/button interaction, live model output, appearance/accent, accessibility preferences, and VoiceOver were not exercised within the two-minute timebox. Existing demo-vault changes were preserved.

## Source availability checks — 2026-10-11

- Added Availability column (Available by default/on addition), Check Availability in source context menus/details, and Source Actions → Check Availability of All Sources beside Add Source. A serial session-only queue displays a mini spinner and muted checking text for queued/running rows. Checks use off-main-actor coordinated reads, linked security bookmarks, and imported checksum verification; vault switching discards pending results.
- Valid linked metadata remains listed when an original cannot be read, with empty derived body and a transient unavailable issue. Missing files report Linked file not found when macOS supplies a missing-file error; stale permissions, downloads, and other access errors retain specific explanations. No source metadata schema/write changes. Availability results are local read results, not cloud-upload confirmation.
- Debug build/package/signing passed; all 68 regression tests passed with native macOS access, including missing/changed imported originals and broken linked-record retention/stale-bookmark/relink recovery. Initial new tests required correction for temporary directory creation and macOS stale-bookmark behavior after replacing a deleted file. These retries extended validation beyond the two-minute boundary. `git diff --check` passed; tracked brand assets were unchanged.
- Manual queue/spinner/context-menu interaction, appearance/accent/accessibility checks, large linked-file performance, and two-Mac iCloud verification were not performed. Optional benchmark/live-model acceptance were not enabled. Existing demo changes were preserved.

## Page metadata and AI summary sidebar — 2026-10-11

- Selected pages now show a resizable native details sidebar matching Sources, with file path, creation/update timestamps, tags, aliases, editing lock status, and saved AI summary. Generate/Regenerate AI Summary uses the existing on-device generation and stale-write protection; generation follows the Settings preference and editing lock. Delete Summary remains available. Close or the Page details toolbar button toggles the sidebar.
- While details are open, the editor's pinned summary and generation indicator are completely absent from its layout. Closing details restores the existing summary display. Summary blocks remain excluded from editable content and preserved during edits in both visibility states; parameterized regression coverage verifies this preservation.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully; `./scripts/test.sh` passed all 68 tests, including both summary visibility cases, with native macOS access. Restricted initial runs encountered iconutil packaging, file-coordination, and pasteboard failures; native-access retries passed. `git diff --check` passed; generated tracked brand assets were unchanged.
- Completed implementation and automated validation within the requested two-minute timebox. Manual sidebar interaction/resizing, appearance/accent switching, VoiceOver/accessibility preferences, and live summary generation were not exercised. Existing demo-vault changes were preserved; no storage format changes.

## Duplicate source prevention — 2026-10-11

- Source imports and links reject already recorded original-byte checksums across modes; linking also rejects the same resolved external path after its bytes change. Detection reads valid existing source metadata under coordination before creating staging files, including unavailable source records. Errors state File already added as a source and name the existing title. The picker loop accumulates filename-specific failures and continues other selected files. Same filenames alone are not duplicates; replacing a broken link requires removing its old record first.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully; `./scripts/test.sh` passed all 70 tests with native macOS access. New coverage checks rejection across link/import modes, changed linked-path rejection, and a later unique file succeeding after duplicate failure. Existing binary-link and bookmark-recovery tests were adapted to reject duplicate records and remove the old linked record before relinking. `git diff --check` passed; tracked brand exports were unchanged.
- Native picker/error-message interaction, appearance/accessibility, and simultaneous additions from separate app instances/Macs were not exercised within the two-minute timebox. Optional benchmark/live-model acceptance were not enabled. Pre-existing editor/UI/README and demo-vault edits were preserved.

## Compact sidebar summaries and page action placement — 2026-10-11

- With page details open, the page-header action icons sit in a separate row below the page title. Closing details restores actions beside the title. Both page and source details share a native summary preview limited to three lines initially, with Show more / Show less buttons and explicit accessibility labels/states. Selecting another item or changing summary text resets its preview to collapsed.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully, and `./scripts/test.sh` passed all 70 tests with native macOS access. `git diff --check` passed; tracked generated brand assets were unchanged. This is a localized SwiftUI presentation change using existing summary generation/persistence behavior.
- Completed within the requested two-minute timebox. Manual title/action layout, preview expansion/collapse/resizing, appearance/accent switching, VoiceOver and accessibility preferences were not exercised. Pre-existing repository and demo-vault changes were preserved.

## Dismissible errors and notices — 2026-10-11

- Added a shared native dismiss control to error messages on welcome, Sources, Trash, empty detail, page detail, and paste-source screens, plus editor/AI notices. External-change messages can be hidden without changing the underlying conflict state; switching pages or a new external-change transition resets that presentation. Vault notices can be dismissed individually or all together; identical dismissed scan issues stay hidden until switching vaults.
- Debug compilation/package/signing passed; regression suite passed all 70 tests with native macOS access. `git diff --check` passed; tracked brand exports were unchanged. Validation completion extended beyond the one-minute timebox. No dedicated new tests for these presentation controls.
- Native dismissal interaction, appearance/accent, accessibility preferences, and VoiceOver were not exercised. Source availability continues to show the file's actual checked status. Pre-existing editor/UI/README and demo-vault edits were preserved.
