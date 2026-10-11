# Validation — 10 October 2026

## Simpler vault setup experience — 2026-10-11

- Reworked the creation sheet into a 540-point vertical layout with a short introduction, labels above controls, consistent 24-point padding, native large controls, one save-location row with Choose…, and a prominent Create Vault action. The full destination appears after selection; longer paths can wrap below the row and remain available to accessibility and text selection. Removed the large inner panel in favor of spacing and a native separator; app theme roles continue to supply surfaces, text, and accents.
- Encrypted vault is now visibly disabled and off with Coming soon, replacing the previously selected but blocked option and repeated capability messages. One readable disclosure explains that the vault is unencrypted and Touch ID/recovery protection is unavailable. The sheet no longer probes biometrics. A valid name and chosen parent enable Create Vault, which still requires explicit plaintext confirmation before atomic creation. AppModel and repository encryption gates remain in place; no encryption or migration capability is claimed.
- `./scripts/test.sh` passed all 112 regression tests with native macOS service access, including encrypted-request rejection, complete plaintext publication, collision preservation, invalid names, and missing-parent checks. `./scripts/build.sh debug` compiled, packaged, and signed successfully with native icon-service access after the initial sandboxed packaging attempt failed at iconutil. Supervisor selftest and changed-file whitespace checks passed; generated brand assets were unchanged.
- UI validation was skipped at the user's request. Live layout, keyboard interaction, theme/accent/appearance switching, accessibility adaptations, VoiceOver, creation/bookmark relaunch, and two-Mac iCloud checks remain unverified for this revision. Existing demo-vault edits were preserved.

## Vault setup sheet follows the app theme — 2026-10-11

- Applied the shared theme modifier at the creation-sheet boundary so saved palette choices, full-palette/accent-only mode, theme previews, and system appearance feed the sheet's surfaces, text, and accents. Replaced the grouped Form's fixed gray surface with native SwiftUI fields, labeled content, and a switch on the shared elevated content surface; primary and secondary text use the matching semantic roles. Native focus, selection, and disabled-control behavior remain platform-managed.
- The five existing theme-mode, default-palette, hover-preview, and contrast tests passed via `./scripts/test.sh --filter 'theme|freshTheme|selectablePalettes|textAndInteractiveForegrounds'` with native service access. The final `./scripts/build.sh debug` compiled, packaged, and signed successfully with native access; the initial sandboxed packaging attempt failed at iconutil. Supervisor selftest and changed-file whitespace checks passed. No new tests were added for this presentation-only change.
- Before the user asked to skip UI validation, an isolated instance displayed palette-colored surfaces and accents in Dark appearance; the final layout was observed in Midnight Iris. Further UI validation stopped at the user's request. Final Forest/Amber/Rose and System/accent-only interaction, live appearance/accent changes, accessibility adaptations, and VoiceOver remain unverified. No vault was created or opened during these checks; unrelated demo-vault changes were preserved.

## Vault creation sheet and encryption release gate — 2026-10-11

- Added a native SwiftUI creation sheet with My Knowledge Vault as the default name, an existing-parent NSOpenPanel picker, final path, encryption requested by default, Touch ID + recovery key intent, and a capability probe without authentication. Encryption remains unavailable at the UI, AppModel, and repository boundaries; no encrypted manifest field or recovery key is produced. Plaintext creation requires explicit confirmation and publishes a staged complete v1 vault without merging existing folders.
- All 112 regression tests passed using `./scripts/test.sh --skip-build` with native service access after the full test wrapper compiled the new sources. New tests cover encrypted requests leaving the parent empty, complete plaintext publication, collisions preserving the manifest, invalid names, and missing parents. The initial sandboxed suite encountered file-coordination and pasteboard restrictions. `./scripts/build.sh debug` compiled, packaged, and signed successfully with native icon-service access after sandboxed iconutil failed. Supervisor selftest and changed-file whitespace checks passed.
- An isolated app instance, with separate preferences and no demo vault, displayed the creation sheet with the expected name, suggested iCloud parent, encryption on, Touch ID available, recovery not configured, and a disabled encrypted-creation button. Actual encryption/recovery/protected indexing are intentionally unimplemented. End-to-end sandboxed plaintext creation/bookmark relaunch, full theme/accent/accessibility combinations, VoiceOver, and two-Mac iCloud checks remain outstanding. Unrelated demo-vault edits were preserved.

## Editor font preferences and smaller defaults — 2026-10-11

- Reduced article body text from 16 to 15 points, with headings and code one point smaller, and source/plain readers from 15 to 14 points. Settings → Editor now offers System or an installed font family and a 10–32-point body size. Preferences persist and trigger article re-rendering with the existing selection and undo behavior; headings scale and code remains monospaced. Unavailable families fall back to the system font; invalid sizes are bounded or fall back to 15 points. Imported rich source formatting remains intact.
- `./scripts/test.sh` passed all 109 tests with native service access, including new preference persistence/fallback, body/heading/code scaling, rich font traits, and unchanged canonical-content checks. The first sandboxed run encountered macOS file-coordination and pasteboard restrictions; the native retry passed.
- `./scripts/build.sh debug` compiled, packaged, and signed the app and archive with native access after the sandboxed packaging attempt failed at `iconutil` with `Invalid Iconset`. Supervisor selftest and changed-file whitespace checks passed; generated brand assets were unchanged.
- Manual UI validation was omitted at the user's request. Live Settings interaction, theme/accent/accessibility combinations, font switching during editing, and relaunch presentation remain unverified. Unrelated demo-vault changes were preserved.

## Trash access stays inside the vault menu — 2026-10-11

- Removed the standalone sidebar Trash button. Trash and its nonzero count remain inside the vault-name menu at the bottom of the sidebar. The retained storage, restore, permanent-delete, and Empty Trash handlers are unchanged. README navigation instructions now match.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully. Supervisor selftest and changed-file whitespace checks passed. Manual UI validation remains stopped at the user's request; the regression suite was not rerun for this navigation-only removal.

## Automatic trash loss: storage-location correction — 2026-10-11

- The previous workflow patch did not prevent automatic loss. A disposable probe in this synced workspace, never opened by Noema, created identical files in `.Trash`, `Removed Pages`, and `.noema-trash`. The `.Trash` file disappeared before the five-second observation; the ordinary-folder controls remained through the 30-second probe and a later inspection. This establishes external removal associated with the `.Trash` location; the deleting process was not identified.
- Noema now creates/writes recoverable pages in the ordinary `Removed Pages` directory and never automatically expires them. Refresh migrates surviving legacy `.Trash` Markdown files without rewriting bytes or overwriting existing entries; failures retain the legacy item and show an issue. Pages already removed externally cannot be recovered by migration. The v1 manifest/Markdown formats are unchanged, but older builds cannot display the new trash location.
- Moving a page to trash previously coordinated the source as a deletion, omitting the destination. Trash, restore, and migration now share a synchronous storage helper that coordinates both URLs as a move and announces the moved URL to file presenters. Swift 6 coordinator ownership stays within this nonisolated helper, without Sendable/isolation suppressions.
- `./scripts/test.sh` passed all 104 tests, including new retention across repeated refresh/reopen and legacy migration with colliding filenames and malformed YAML while preserving original bytes. Existing restore, permanent-delete, Empty Trash, stale-file, and symlink protections passed. `./scripts/build.sh debug` compiled, packaged, and signed successfully. Supervisor selftest and changed-file whitespace checks passed. The first compilation exposed coordinator capture isolation errors; the synchronous helper resolved them before the successful suite/build.
- Native checks used an isolated rebuilt app and a temporary artifact vault in the current Dark appearance: all three deleted pages and previews remained visible; Restore returned the fixture to Pages and decremented Trash; moving it back used `Removed Pages` and restored the count. Named-page permanent-delete and Empty Trash confirmations opened, and cancelling each preserved entries. All three fixture files were still present after 159 seconds; `.Trash` was never created in this vault. Quitting and relaunching the isolated app reopened its bookmarked vault, and Trash still displayed all three items. UI validation stopped at the user's request immediately after this successful relaunch check. Final irreversible dialog actions remain covered by automated tests. Theme/accent switching, accessibility preferences, full VoiceOver, and two-Mac iCloud verification remain outstanding. Unrelated demo content was not modified.

## Trash workflow and display — 2026-10-11

- Added a direct sidebar Trash button, content previews, explicit refresh, operation progress/disabled actions, captured-page permanent-delete confirmation, and snapshot-based Empty Trash confirmation. Opening Trash clears global search. Restore/delete/empty reload the list and derived page/search state; per-item failures remain actionable while other confirmed entries are processed.
- Damaged Markdown remains visible with its decoding error and raw-byte hash for safe deletion; restore is disabled until repaired. Unreadable/unsafe entries remain visible and protected. Trash directory symlinks are rejected, and existing coordinated stale-hash, duplicate identity/title, and cloud-conflict protections remain. Canonical format is unchanged.
- `./scripts/test.sh` passed all 102 tests after the final code changes. New checks cover damaged-file visibility and recovery of healthy entries, deletion of readable damaged bytes, bulk partial failures, files changed after confirmation, files added after confirmation, active-page preservation, symlink protection, and navigation from global search. The initial sandboxed run was blocked by macOS file coordination; the successful suite used native service access. `./scripts/build.sh debug` compiled, packaged, and signed successfully. Supervisor selftest and changed-file whitespace checks passed.
- An isolated app copy opened a temporary vault and displayed the native Trash empty state, direct navigation, refresh, and disabled Empty Trash button. Populated-list appearance, native Restore, destructive-dialog execution/cancellation, theme/accent switching, accessibility adaptations, and VoiceOver remain unverified: fixture files were not retained at the initial UI test location, and repeated app-change guards blocked further UI actions. Permanent deletion and Empty Trash were verified through automated temporary-vault tests. Two-Mac iCloud verification remains outstanding. Unrelated demo-vault edits were preserved.

## Full Midnight Iris default — 2026-10-11

- Fresh installations now default to Midnight Iris with the full palette enabled. Settings, the theme environment, and invalid-value fallback share the same default. Existing saved theme and full-palette preferences are preserved.
- `./scripts/test.sh` compiled the app and passed all 95 tests outside the automation sandbox, including the default palette in both appearances and explicit System-mode coverage. `git diff --check` passed.
- `./scripts/build.sh debug` compiled, packaged, and signed the app and archive successfully outside the automation sandbox. The sandboxed packaging attempt failed with `Invalid Iconset`; the unsandboxed retry passed.
- UI validation was omitted as requested. Live fresh-install appearance and relaunch remain unverified.

## Theme dropdown swatches and hover previews — 2026-10-11

- The native NSPopUpButton shows six semantic palette swatches beside every theme. Native menu highlighting previews the theme throughout theme-aware windows, in the current full-palette/accent-only mode.
- Hover state is transient and separate from UserDefaults. Explicit selection is committed after menu tracking ends; cancelling clears the preview and retains the saved preference. Keyboard highlighting uses the same preview path.
- `./scripts/test.sh` compiled the app and passed all 94 tests outside the automation sandbox, including preview cancellation and deferred-selection coverage. `git diff --check` passed.
- No native UI validation was performed, as requested. Live hover repaint during native menu tracking, keyboard menu interaction, swatch rendering, and VoiceOver remain unverified. Packaging was not rerun; the prior Invalid Iconset limitation remains recorded below.

## Theme palettes and application modes — 2026-10-11

- Settings now offers System, Midnight Iris, Forest, Amber, and Rose, with a persisted full-palette checkbox. Unchecked palettes use their main color as an accent with native surfaces and text; palettes follow macOS Light/Dark appearance.
- `./scripts/test.sh` passed all 93 tests outside the automation sandbox, including palette contrast in both appearances with increased contrast and native/full-palette role checks. The initial sandboxed run encountered file-coordination and pasteboard failures.
- `./scripts/build.sh debug` compiled successfully, but packaging failed at `iconutil` with `Invalid Iconset`. `git diff --check` and supervisor self-tests passed.
- Native Settings inspection in an isolated app confirmed the choices and Forest full/accent-only surface switching in current Dark appearance. Further UI validation was stopped at the user's request. Light appearance, live system appearance/accent switching, editor/source-preview interactions, preference persistence after relaunch, and full accessibility checks remain unverified. Existing demo-vault edits were preserved.

## Custom TeX commands modal in Settings — 11 October 2026, standard timebox

- Moved custom TeX command inputs out of the main Settings pane into `CustomTeXCommandsModal`, opened from **Noema → Settings… → Math & TeX → View or Edit Custom Commands…**. The Settings pane now displays a summary count and the modal trigger button.
- `CustomTeXCommandsModal` lets users view configured commands with live rendered previews, add new commands (0–3 arguments via the command builder or direct `\newcommand` input), edit/rename existing commands in place (`TeXMacroStore.update` and `TeXMacroStore.updateFromNewcommand`), and delete commands (`TeXMacroStore.remove`).
- Verified with `./scripts/test.sh --filter inlineAndDisplayMathAndCustomNewcommandMacros` and `./scripts/build.sh debug`. Manual interactive UI, appearance/accent switching, and VoiceOver checks were not performed within the timebox.

## Inline and display math and custom TeX macros — 11 October 2026, six-minute timebox

- Added `TeXMath`, `TeXMacro`, and `TeXMacroStore` in `VaultCore` supporting inline math (`$...$` and `\(...\)`), display math blocks (`$$...$$` and `\[...\]`, plus `/math` and `$$` shortcuts), and custom `\newcommand` macros with 0 to 3 arguments (`#1`, `#2`, `#3`).
- Added **Custom TeX macros** in **Noema → Settings…** allowing users to add custom commands either via direct `\newcommand{\cmd}[n]{body}` input or via the Custom TeX macro builder UI (command name, 0–3 arguments picker, and TeX body), with live preview and removal. Inline `\newcommand` definitions inside math expressions are also expanded.
- `inlineAndDisplayMathAndCustomNewcommandMacros`, `slashCommandMatchingAndBoundaries`, `slashPaletteUsesCompactSectionsAndSemanticSymbols`, and all non-bookmark tests in `./scripts/test.sh` passed (5 linked-bookmark tests require unsandboxed `com.apple.security.files.bookmarks.app-scope` access). Manual interactive UI, appearance/accent, and VoiceOver checks were not performed within the timebox.

## Hanging semantic list icons — 11 October 2026, one-minute timebox

- Placed each semantic result's colored icon in a 20-point leading gutter outside the text column. Type, preview, and owning page now align together; retains requested Pages row padding and spacing.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully. Changed-file whitespace checks passed; brand assets were unchanged. No regression suite rerun for this layout-only adjustment. Manual visual, appearance/accent, and accessibility checks were not performed.

## Semantic list row padding — 11 October 2026, one-minute timebox

- Matched Semantic Blocks list rows to Pages: 12-point horizontal padding, 10-point vertical padding, and six-point spacing between row contents.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully. Changed-file whitespace checks passed; generated brand assets were unchanged. No regression suite rerun for this layout-only change. Native visual, appearance/accent, and accessibility checks were not performed.

## Global semantic block search — 11 October 2026, two-minute timebox

- Added Semantic Blocks below Sources. Native selectable list rows show semantic type/color/icon, one-line block preview, and owning page. Search matches all whitespace-separated terms across block text, semantic type, and page title, case-insensitively. Includes nested blocks and current editor content; omits generated summaries. Snapshot parsing/search runs off the main actor, with query/vault/cancellation checks before publishing. Selection uses existing save-before-navigation and block-jump actions, rendering the same article viewer and page inspector used by Pages.
- Final `./scripts/test.sh` passed all 75 tests with macOS service access, including new global search coverage for nested blocks, whitespace previews, multi-term case-insensitive type/text/page matching, generated-summary exclusion, no matches, and page-qualified row identity. `./scripts/build.sh debug` compiled, packaged, and signed successfully. Changed source/test/documentation whitespace checks passed; brand assets were unchanged. Existing edits and demo content were preserved.
- Manual global-list selection/search/edit flows in a temporary vault, appearance/accent/accessibility/VoiceOver checks, and the optional 5,000-entry benchmark were not performed within the timebox. No persisted schema or index changes.

## Semantic sidebar sizing and spacing — 11 October 2026

- Increased semantic previews and icons from native caption to body size, aligned icons in a 20-point column, and placed all rows in one stack with four-point spacing. This removes the outer inspector's 18-point gap between different semantic tags while retaining one-line previews and hover navigation.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully. Whitespace checks passed for the changed UI and validation files; generated brand assets were unchanged. No regression suite rerun for this layout-only adjustment. Manual visual, appearance/accent, and accessibility checks were not performed.

## Compact semantic rows and block navigation — 11 October 2026, two-minute follow-up

- Excluded AI-generated Summary blocks from semantic rows while retaining manually tagged Summary blocks. Removed tag title headings; each block has one preview line with its colored semantic icon. A right arrow appears on row hover or keyboard focus; the native button jumps to the block using the existing editor action, including revealing collapsed ancestors in locked/read-only views.
- Final `./scripts/test.sh` passed all 74 tests with native macOS service access. Coverage checks generated-summary exclusion/manual-summary retention and locked nested-block navigation without publishing content changes or adding undo actions. One initial assertion hit a Swift Testing key-path macro compile error; the corrected assertion passed. `./scripts/build.sh debug` compiled, packaged, and signed successfully. Diff whitespace checks passed for changed source/test/documentation files; unrelated live demo edits include trailing whitespace and were preserved. Generated brand assets were unchanged.
- Manual hover/keyboard presentation, sidebar layout, appearance/accent changes, accessibility settings, and VoiceOver checks were not performed within the timebox.

## Page sidebar semantic tags — 11 October 2026, two-minute timebox

- Page details automatically groups all semantic-tagged blocks by tag with one-line whitespace-normalized previews and full-text hover help. Includes nested/collapsed blocks, empty tagged blocks, unknown future tags, and Summary blocks; derives from the current editor body so edits update the list. No persistence or format changes.
- `./scripts/test.sh` passed all 73 tests with macOS service access, including new nested/unknown-tag, ordering, empty-block, and tag-removal coverage. `./scripts/build.sh debug` compiled, packaged, and signed successfully with icon-service access. Initial restricted checks failed on file coordination/pasteboard and icon packaging; service-enabled reruns passed. `git diff --check` passed; generated brand assets were unchanged. Existing edits and demo-vault content were preserved.
- Native sidebar layout and editing interaction in a temporary vault, appearance/accent switching, accessibility settings, and full VoiceOver checks were not performed within the explicit timebox.

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

## Compact metadata presentation — 2026-10-11

- Page and source metadata use caption-sized secondary text, six-point row spacing, and smaller native controls. Created, Updated, and Captured timestamps use localized abbreviated dates and shortened times; unparseable values remain visible. README updated; unrelated demo-vault edits preserved.
- `git diff --check` passed. Debug build/package and regression suite were started with native macOS access and remained in progress at the requested one-minute stop; their results are unconfirmed. Native UI, appearance/accent, accessibility preferences, and VoiceOver checks were not performed.


## Page/source references — 11 October 2026, three-minute timebox

- Added many-to-many references stored as source UUIDs in page YAML, editable from Page details → Sources and Source details → Pages. Existing coordinated page saves reject stale/deleted/locked pages; source originals remain untouched. Missing source references stay visible/removable. Existing UI/documentation/demo-vault changes were preserved.
- `./scripts/test.sh` passed all 71 tests with native macOS service access, including new many-to-many persistence, removal, stale-write rejection, locked-page rejection, and original checksum preservation coverage. The restricted run encountered file-coordination/clipboard service failures; its failures were environmental and the native rerun passed.
- `./scripts/build.sh debug` compiled, packaged, and signed the app/archive with native macOS icon-service access; the restricted packaging attempt failed at `iconutil`. `git diff --check` passed. Generated brand assets were unchanged.
- Native sidebar interaction in a temporary vault, appearance/theme/accent changes, accessibility/VoiceOver, and two-Mac iCloud behavior were not manually exercised within the timebox.


## Reference navigation and inline removal — 11 October 2026, two-minute timebox

- Added an open icon beside every page/source association. Source references open the existing native reader; page references switch to Pages, clear search filters, and select the page through the existing save-before-navigation flow. Locked pages retain access to opening references. Missing sources show a disabled open button.
- Replaced association minus icons with trash icons. Clicking trash reveals native inline Remove/Cancel controls and explains that only the association is removed. Confirmed removal uses the existing stale-checked repository operation; cancellation leaves the association unchanged.
- `./scripts/test.sh` passed all 72 tests with native macOS service access, including a new source-to-page navigation check for selection, scope, filter clearing, and body preservation. `git diff --check` passed.
- `./scripts/build.sh debug` compiled, packaged, and signed the app/archive successfully with native macOS service access. Generated brand assets were unchanged.
- Manual sidebar navigation/confirmation in a temporary vault, theme/accent changes, VoiceOver/accessibility adaptations, and two-Mac iCloud behavior were not exercised within the timebox.

## Coherent document inspector — 2026-10-11

- Unified page/source inspectors with a fixed Inspector header, compact wrapping document identity, shared native DisclosureGroup section headers/counts/actions, consistent 18-point section and 8-point content spacing, and a resizable 340-point ideal width. Condensed mode collapses references, semantic blocks, and summaries while retaining Properties. Property labels are muted and values primary; exact timestamp tooltips accompany localized dates. Page location reveals the file in Finder; Protection uses the existing lock action. Semantic rows show type, two-line preview, and a visible jump affordance using existing block navigation. Source/page associations retain their existing open/remove behavior and add controls in section headers; empty states are explicit. Summary previews use four lines and inline expansion; generation/delete actions move into headers.
- Debug compilation/package/signing passed for the redesign. Regression suite passed all 75 tests, including existing locked nested-block navigation and reference-opening coverage. Final copy/accessibility cleanup compiled as part of the regression run; the final debug packaging/signing rerun also passed. `git diff --check` passed. Previous compact-metadata validation also subsequently completed successfully (debug package and 70 tests).
- Manual inspector resizing/collapse, Finder/lock controls, appearance/accent, accessibility preferences and VoiceOver were not exercised within the timebox. Alias editing, additional semantic context-menu mutations, and persisted summary generation/freshness indicators are not implemented in this UI pass. Existing demo-vault changes were preserved; no storage format changes.

## Semantic inspector row alignment — 2026-10-11

- Semantic inspector buttons and their labels fill the available width with leading alignment. Wrapped type/preview text explicitly uses leading multiline alignment; icons and navigation arrows align to the top of each entry. Existing native button focus and navigation are retained.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully; `git diff --check` passed. No regression suite rerun for this layout-only change. Native visual, appearance/accent, and accessibility checks were not performed within the one-minute timebox. Unrelated demo-vault and validation edits were preserved.


## URL source captures — 2026-10-11, five-minute timebox

- Added Sources → Add Source → By URL and Vault → Add Sources by URL with a native multiline editor accepting 1–5 nonempty lines. HTTP(S) validation, device-side fetching, 2 MB streamed response limit, and independent per-item errors feed successful HTML/plain-text/PDF captures into the existing on-device title/summary queue. Fetched originals remain byte-for-byte preserved through staging publication and checksum enforcement.
- URL availability checks perform an uncached GET and persist archived/unavailable metadata on failure without changing captured bytes, title, or summary; successful checks clear the archived state. Optional metadata distinguishes fetched pages from pasted text with an origin URL. Archive writes reject missing/deleted records, symlinked metadata/directories, and unresolved metadata conflicts.
- Final regression suite passed all 79 tests with native macOS services, including URL validation/line limits, independent item failures, archive persistence, summary/original preservation, and availability recovery. The optional local HTTP acceptance entry was separately enabled against a temporary localhost server and passed HTML fetching plus 404, empty-response, oversized-response, and unsupported-type handling. Restricted initial tests encountered native file-coordination/clipboard service failures; native retries passed. Property lists and `git diff --check` passed.
- Final debug compilation, packaging, and signing passed with the outbound network entitlement and HTTP transport policy; signed bundle verification passed and the packaged transport policy was inspected. Tracked brand exports were unchanged. Existing demo-vault edits were preserved.
- Native sheet/batch/reader interaction in a temporary vault, theme/accent/accessibility/VoiceOver checks, live on-device inference, authenticated/JavaScript/non-UTF-8 web pages, external website compatibility, and two-Mac iCloud behavior were not manually verified within this timebox. HTTP acceptance tests use local synthetic pages; the optional test requires NOEMA_URL_FETCH_TEST_BASE pointing at its fixture.


## Wikipedia main-content extraction — 2026-10-11, two-minute timebox

- Wikipedia URL HTML captures derive only the complete `<main>…</main>` container for search, automatic titles/summaries, and native reader content. Original HTTP response bytes/checksums remain intact. Other sites, imported files, and pasted text retain existing behavior. Tokenization handles case/quoted attributes and ignores markup examples inside comments/script/style; missing/incomplete main containers fail the individual fetch.
- Regression suite passed all 81 tests with native macOS services, including synthetic Wikipedia chrome removal, misleading-domain exclusion, missing/incomplete containers, capture/scan consistency, and original-byte preservation. Restricted initial tests hit file-coordination/clipboard service failures; native retry passed. `git diff --check` passed; final debug compilation, packaging, and signing passed. Tracked brand assets were unchanged.
- Live Wikipedia variants, reader interaction, appearance/accessibility, live on-device inference, and two-Mac checks were not exercised within this timebox. Existing repository and demo-vault changes were preserved; no schema changes.

## Wikipedia extraction rollback — 2026-10-11, one-minute timebox

- Removed Wikipedia main-container extraction and its fetch validation. URL captures, repository scanning, native reader content, and automatic on-device inference again use the full captured HTML through the existing HTML normalization path. Wikipedia pages without a main container are accepted. Saved original responses and existing summaries are preserved; title/summary regeneration remains available through existing actions.
- Replaced extraction tests with parameterized full-HTML capture/scan/checksum preservation coverage, including a page without a main element. `git diff --check` passed. Native regression suite passed all 80 tests. Debug packaging remained in progress at the one-minute stop; subsequent inspection confirmed successful compilation, packaging, and signing of the app/archive. Tracked brand assets were unchanged.
- Live Apple Intelligence generation and manual reader/UI checks were not exercised within this timebox. Existing demo-vault changes were preserved.

## AI page creation from sources — 2026-10-11, five-minute timebox

- Added Create Page with AI to a source's context menu and Source details → Pages → Add, with duplicate-request disabling and native inspector progress. On-device generation uses up to 6,000 characters of existing readable text/PDF extraction and creates a Markdown article plus topic title. The current editor is saved before opening the editable page; vault switches discard pending results. The repository persists its initial source UUID in the first coordinated page write, checks source presence/content, and resolves title collisions without changing existing pages or source originals.
- `./scripts/test.sh` passed all 81 tests with native macOS access, including new initial reference persistence, duplicate-title handling, existing-page/original-byte preservation, and rejection after source deletion without publishing a page. `./scripts/build.sh debug` compiled, packaged, and signed successfully with native macOS access. Restricted initial checks failed at native file coordination/clipboard and iconutil services; native retries passed. `git diff --check` passed; tracked brand exports were unchanged. README and architecture documentation updated; existing demo-vault edits preserved.
- Native-access validation retries extended beyond the requested timebox. Manual interaction in a temporary vault, live on-device article quality, appearance/accent changes, VoiceOver/accessibility adaptations, and two-Mac iCloud behavior were not exercised. Optional benchmark/live-model acceptance tests were not enabled. No storage format changes.

## On-device topic-page creation — 2026-10-11, two-minute timebox

- Added New page → From topic with AI and the File-menu action, presenting a native topic field with focus, keyboard submission/cancellation, validation, progress, and errors. AppModel searches the existing wiki index for up to three matching pages, extracts bounded Markdown without AI summary blocks off the main actor, and passes context to on-device Apple Intelligence. Without matches the model uses general knowledge. Drafts are short, explicitly identify AI/model or vault context, list retrieved page links, and open for editing. No web search is performed; the sheet and README say so. Duplicate submissions and earlier-vault results are guarded; save-before-navigation and coordinated creation are retained.
- `./scripts/test.sh` passed all 83 tests with native macOS access, including topic/context budget and rejected input checks. `./scripts/build.sh debug` compiled, packaged, and signed successfully with native macOS access. `git diff --check` passed; tracked brand exports were unchanged. Existing source-to-page feature and demo-vault edits were preserved; architecture/README updated without a schema change.
- Compilation and packaging completed beyond the requested two-minute implementation timebox. Manual native sheet interaction in a temporary vault, live model output/retrieval quality, appearance/accent changes, accessibility/VoiceOver, and two-Mac behavior were not exercised. Optional benchmark/live-model acceptance tests were not enabled.

## Web research for topic pages — 2026-10-11, two-minute timebox

- Topic generation now queries Bing's public RSS search and retrieves up to three readable HTML/text pages among the first five ranked results through the existing 2 MB/20-second request fetcher. Search-feed XML acceptance is scoped separately from ordinary source fetching. On-device AI summarizes bounded result text with numbered citations; the app adds actual fetched result links, a retrieval timestamp, and AI attribution. Search blocks/empty results or entirely unreadable pages fail without creating a page. The sheet discloses the external search request; general-model/local-vault fallback is removed. Existing source creation and demo-vault changes remain intact.
- Live DuckDuckGo HTML research returned a bot challenge, so the implementation switched to Bing RSS, which returned ranked results for Roman Empire history. The opt-in liveWebTopicSearchAcceptance check passed actual Bing search plus page retrieval. The full suite with live acceptance enabled passed all 86 tests; final regression suite also passed all 86 entries (live acceptance gated off on that final run). New synthetic coverage verifies ranking, redirect/URL validation, duplicate filtering, entity decoding, failed-page skipping, and blocked-search rejection. Final debug compilation/package/signing passed. `git diff --check` passed and tracked brand assets were unchanged.
- Provider investigation and a corrected Swift type-checking expression extended implementation/validation beyond the requested two-minute timebox. Native UI interaction, live model citation/summary quality, appearance/accent/accessibility/VoiceOver, and two-Mac behavior were not exercised. Public search-feed availability can change or be blocked; failures surface explicitly. No remote AI inference or persisted format change.

## Responsive read-mode page header — 2026-10-11

- Read-mode page titles and actions use native SwiftUI ViewThatFits: actions move below the title when the complete horizontal row no longer fits. The stacked title can wrap with its full available width. Details-open and editing layouts retain their existing arrangement.
- `./scripts/build.sh debug` compiled and linked the app successfully (19.73 seconds), then failed packaging at `iconutil` with `Invalid Iconset`. Generated tracked brand exports were discarded if changed.
- `git diff --check` passed. UI validation was skipped at the user’s request; narrow-window behavior, appearance, and accessibility have not been manually checked. No regression suite was run for this layout-only change.

## Full-width AI summary banner — 2026-10-11

- Removed the enclosing page-content width cap and applied the existing 980-point limit to the summary text, generation indicator, and article editor. Expanded/collapsed summary material and divider now span the main pane while text stays centered with the article. Source previews retain their existing width.
- Initial build detected an input edited during compilation; retried after edits completed. The debug build retry exceeded its 35-second limit. Compilation is unverified.
- `git diff --check` passed. UI validation was skipped at the user’s request; wide-window, theme, and accessibility behavior remain manually unverified. No regression suite was run for this layout-only change.

## AI summary banner refinements — 2026-10-11

- Summary generation and summary content share one full-width native frosted background and a thinner bottom divider. Summary typography remains unchanged, as clarified by the user. Expanded banners initially show three lines with accessible Show more / Show less controls; hiding the banner or replacing summary text resets the preview.
- `./scripts/test.sh` compiled the test target but the run of 95 tests reported 44 issues, including editor paste/formatting expectations; the regression suite did not pass. Final `./scripts/build.sh debug` compiled and linked successfully (21.07 seconds), then packaging failed at `iconutil` with `Invalid Iconset`. `git diff --check` passed. UI validation, appearance, and accessibility checks were skipped at the user’s request.

## AI summary display preference — 2026-10-11

- Settings → Apple Intelligence adds a persisted Show page summaries picker. Editor when sidebar is closed is the default; Sidebar only suppresses the editor banner and generation indicator regardless of sidebar visibility. Saved summaries remain in the sidebar, and unknown preference values fall back to the default.
- Expanded the summary editing/preservation regression to exercise both placement choices with the sidebar visible and hidden. The serial regression run reported 44 issues across 95 tests, including temporary-vault write errors and editor paste checks; the suite did not pass. Debug compilation and linking passed. Packaging failed with Invalid Iconset.
- `git diff --check` passed. Native UI, appearance/accessibility, and preference persistence across an actual app relaunch were not manually exercised, consistent with the session’s no-UI-validation preference.


## Grouped global sidebar search — 2026-10-11

- Sidebar queries search all pages and sources through the existing index plus semantic blocks off the main actor, independent of the selected collection or tag filter. Results appear in Pages, Sources, Semantic Blocks order in the sidebar and main workspace; empty groups are omitted. Collection tabs and normal recent/all sections return when search is cleared. Result navigation preserves the query and uses existing save-before-navigation and block-jump behavior. Obsolete query/vault results are discarded. No storage format changes.
- Native regression suite passed all 97 tests, including new indexed page/source/nested-block matching, aliases, no matches, query-preserving navigation, and whitespace checks. The restricted initial run reported 44 file-coordination/clipboard-related issues; native retry passed. Debug compilation, packaging, and signing passed with native macOS access after restricted iconutil packaging failed. Generated tracked brand exports were unchanged. Supervisor selftest passed.
- An isolated app instance with a separate bundle identity and temporary fixture vault verified searching from Sources returns all three groups in order, hides collection tabs, opens a semantic result at its owning page, opens a source read-only, preserves the query, and restores tabs/Recent Sources when cleared. Existing demo-vault changes were preserved. Theme/accent switching, accessibility preferences, VoiceOver, and two-Mac iCloud behavior were not exercised.


## Bottom sidebar vault management menu — 2026-10-11

- Moved Trash (including its nonzero count), recoverable drafts, and vault notices into the existing vault-name menu anchored at the bottom of the sidebar. Finder reveal and refresh stay available there, with Open/Create Vault separated below. Actions retain their existing navigation, recovery, and refresh handlers; no storage changes.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully with macOS icon-service access; the initial restricted build compiled and linked but packaging failed with Invalid Iconset. Generated tracked brand exports were unchanged. Supervisor selftest passed, and changed-file whitespace checks passed.
- UI validation was skipped at the user's request, including menu interaction, appearance/theme/accent changes, accessibility preferences, and VoiceOver. No regression suite rerun for this menu-only presentation change. Existing source/documentation and demo-vault changes were preserved.


## Vault dropdown spacing and separator — 2026-10-11

- The bottom vault dropdown now uses 12-point footer side insets, eight-point spacing below its divider, eight-point inner horizontal/vertical padding, and a minimum 34-point control height. Semantic callout typography and a fixed icon column align the label; a single chevron replaces the paired indicator and hides the additional native menu indicator. Removed the redundant inner stack.
- Kept the native divider, inset it with the footer, and reduced normal opacity from 0.5 to 0.2; Increase Contrast uses 0.75 for visibility. Menu actions and storage are unchanged.
- Final `./scripts/build.sh debug` compiled, packaged, and signed successfully with macOS service access. An initial compile caught an incorrect environment key, corrected to `colorSchemeContrast` before the passing build. Supervisor selftest passed; changed-file whitespace checks passed. Generated tracked brand exports were unchanged.
- UI validation remained skipped per the user's earlier instruction, including menu layout/interaction, themes/accent colors, Increase Contrast and other accessibility preferences, and VoiceOver. No regression suite rerun for this presentation-only adjustment. Existing unrelated edits were preserved.


## Leading sidebar unlock control — 2026-10-11

- Locked sidebar pages replace the leading file/unread icon with a native Unlock button, removing the trailing lock beside relative edit time. Successful unlocking briefly shows an open lock, then restores the regular file or unread icon. Reduce Motion skips the animation; failures retain the locked state and allow retry. Selection and context-menu actions retain their existing handlers.
- UI validation remains skipped per the session preference. Automated build results are recorded below.
- Initial debug compilation, packaging, and signing passed; a final build was started after adjusting the regular-icon selection action. Supervisor selftest and changed-file whitespace checks passed. Regression suite was not rerun within the quick timebox; persistence uses the unchanged editing-lock handler. Final-build outcome is reported in the chat.


## Unlock feedback before sidebar reordering — 2026-10-11

- Sidebar unlocking preserves the page's previous sort timestamp for All Pages and the update-sorted Recent Pages fallback while publishing saved unlocked metadata immediately. The native open-lock symbol uses system green and holds for 1.4 seconds; the regular icon returns with a 300-ms settling period before releasing the sort hold. Reduce Motion skips the presentation hold. Failed saves, disappearance during feedback, and vault switches release transient ordering state. Existing save/reconciliation handlers and persisted formats remain unchanged.
- `./scripts/test.sh` passed all 98 tests with native macOS service access, including a new regression for stable All/Recent ordering despite updated saved metadata, reordering after feedback completion, and cleanup after a failed unlock. `./scripts/build.sh debug` compiled, packaged, and signed successfully. Supervisor selftest and changed-file whitespace checks passed; tracked brand exports were unchanged.
- UI validation remains skipped per the session instruction; visual animation timing, appearance/theme/accent changes, Increase Contrast/Reduce Motion interaction, VoiceOver, and other manual accessibility checks were not exercised. Existing unrelated edits and demo-vault content were preserved.


## Right-click lock feedback before reordering — 2026-10-11

- Sidebar context-menu Lock and Unlock now share the transient sort-position hold. After a successful Lock save, the closed-lock icon stays in its row for 1.4 seconds before updated sorting moves it. Unlock retains the green open-lock pause and file-icon return. Saved metadata remains immediate; Reduce Motion skips the presentation pause. Cleanup now applies to both lock directions.
- `./scripts/test.sh` passed all 98 tests with native macOS service access, including parameterized lock/unlock tests for stable All/Recent ordering until feedback completion, immediate saved timestamps, and release after failed operations. `./scripts/build.sh debug` compiled, packaged, and signed successfully. Supervisor selftest and changed-file whitespace checks passed; generated tracked brand assets were unchanged.
- Manual UI validation, animation timing, appearance/theme/accent changes, Reduce Motion/Increase Contrast behavior, and VoiceOver/accessibility checks remain skipped per the session preference. Existing unrelated changes and demo-vault content were preserved.


## Subtle relocated-row feedback — 2026-10-11

- Completing either sidebar lock/unlock pause now emits a per-page move cue after releasing the sort hold. The relocated row fades to 90% opacity over 180 ms, then returns over 320 ms, starting 80 ms after movement. Reduce Motion suppresses the cue; cancelled row tasks reset opacity. Failed saves and duplicate completion callbacks do not emit new cues. No persisted data changes.
- All 98 regression tests passed with native macOS service access, including lock/unlock move-cue generation, duplicate completion suppression, and failed-save suppression. Supervisor selftest and changed-file whitespace checks passed. A final debug packaging build was started; its outcome is reported in the chat.
- Manual UI, visual timing/strength, appearance/theme/accent, accessibility-preference, and VoiceOver checks remain skipped per the session instruction. Existing unrelated edits were preserved.


## Longer, clearer relocated-row cue — 2026-10-11

- Increased the post-lock/unlock move cue from 90% to 75% opacity. It now starts 120 ms after relocation, fades out over 300 ms, holds near the lighter state for 900 ms, then fades back over 650 ms. The task stays alive through the return animation so cleanup cannot interrupt it. Reduce Motion handling, ordering, and move-cue eligibility remain unchanged.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully. Supervisor selftest and changed-file whitespace checks passed; tracked brand exports were unchanged. No regression suite rerun for this opacity/timing-only adjustment (the previous cue-change suite passed all 98 tests).
- UI validation, perceived visibility/timing, theme/accent switching, accessibility preferences, and VoiceOver remain manually unverified per the session's no-UI-validation instruction. Existing unrelated edits were preserved.


## About Noema background and copyright — 2026-10-11

- The native macOS About panel includes the supplied three-paragraph Greek and Husserl background, retaining italic terms and the existing tagline. App bundle metadata supplies “© 2026 Roel Christian Yambao. All rights reserved.” using NSHumanReadableCopyright. Credits use the native preferred body font and semantic label color.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully with macOS icon-service access. The initial restricted build compiled but packaging encountered Invalid Iconset. Packaged copyright metadata was verified. Supervisor selftest passed all 17 policy parameters; whitespace checks passed; tracked brand exports were unchanged. No regression tests were added or rerun for this copy-only presentation change.
- Prepared an isolated app identity with no saved vault for native inspection, but Computer Use returned “Computer Use was not approved to use Noema.” About-panel layout/scrolling, theme and accent switching, accessibility preferences, and VoiceOver remain manually unverified. Existing unrelated edits and demo-vault content were preserved.


## Larger themed About window — 2026-10-11

- About Noema now opens a native SwiftUI window at 820 × 760 points, with a 660 × 560 minimum and standard window resizing. The three paragraphs retain italic spans and selectable text, with scrolling available in smaller windows. The header retains the app icon, tagline and version; copyright remains visible below the text.
- The window uses the shared systemNoemaTheme modifier and semantic background/text roles, following the selected palette, full-palette/accent-only preference, System appearance, and accessibility contrast updates. No independent theme preferences were added.
- `./scripts/build.sh debug` compiled, packaged and signed successfully with macOS service access. Supervisor selftest passed; whitespace checks passed. An attempted focused palette regression run was interrupted because AppModel.swift was modified during compilation by concurrent work; a retry was started with the exact palette-test filter. Its outcome is reported in chat.
- Native UI access to Noema remains unavailable from the preceding attempt. Actual window layout/fit, live theme/accent changes, accessibility preferences and VoiceOver remain manually unverified. Unrelated concurrent edits and demo-vault content were preserved.


## Fixed About window matching the reference — 2026-10-11

- Locked About Noema to a 660 × 560-point content area, matching the reference image’s approximately 1320-pixel-wide window at Retina scale. SwiftUI content-size resizability fixes its dimensions; a native window attachment removes the resizable style, opts out of fullscreen and disables the zoom button. Closing, minimizing, text selection, scrolling and the shared theme layer remain available.
- `./scripts/build.sh debug` compiled, packaged and signed successfully with macOS service access. Supervisor selftest passed all 17 policy parameters; whitespace checks passed. No regression tests were added or rerun for this window-only adjustment.
- Native UI access remains unavailable from the earlier denied attempt. Edge dragging, zoom/fullscreen commands, reference-size comparison on screen, live theme/accent changes and VoiceOver/accessibility settings remain manually unverified. Existing unrelated and concurrent edits were preserved.


## Combined trash and 15-day retention — 2026-10-11

- Trash combines pages, linked source records, imported sources, and URL sources in one list; sidebar collection tabs hide while Trash is open. Sources move to recoverable storage with their metadata and imported originals. Restore preserves identity and bytes; permanent deletion and Empty Trash use captured snapshots and stale/conflict/path checks. Linked external originals are never removed.
- Automatic cleanup runs on refresh/open after 15 days. Existing undated trash gets a full 15-day grace period from first refresh; damaged, unreadable, unsafe, or conflicted items remain protected. Canonical v1 formats remain unchanged; older builds cannot display trashed sources.
- The service-enabled `./scripts/test.sh` passed all 107 tests, including mixed page/source restore, external-original preservation, stale/duplicate source restoration, and retention across reopen with legacy grace and damaged-file protection. The first restricted run failed because native file-coordination/pasteboard services were blocked. Code compiled, `git diff --check` and supervisor selftest passed.
- `./scripts/build.sh debug` was interrupted by concurrent modification of `Sources/noema/NoemaApp.swift`; packaging verification remains outstanding. UI validation was skipped at the user's request. Accessibility/theme/accent and two-Mac iCloud checks were not performed.


### Sidebar editing-lock refinement (2026-10-11)

- Document icons and titles open pages; a separate persisted lock indicator/control exposes Lock Editing / Unlock Editing on hover, selection, focus, and to VoiceOver. Removed delayed unlock color, sorting holds, and row opacity feedback; the symbol replacement uses a brief transition with Reduce Motion support.
- Added regression coverage for lock-only timestamp preservation, pending content timestamps, stable sidebar ordering, rapid duplicate actions, stale-write failure, and retry. Storage continues through coordinated stale-checked writes with no format change.
- Supervisor selftest passed (all 17 policy parameters). After correcting temporary-directory setup in the new model tests, the service-enabled `./scripts/test.sh` passed all 115 tests, including rapid actions in both lock directions, failure/retry, and pending-content timestamp preservation. `./scripts/build.sh debug` compiled, packaged, and signed successfully with native macOS service access. Initial sandboxed runs encountered coordinated-file-write/pasteboard errors and iconutil rejected the iconset; service-enabled reruns resolved those blocks. See `.build/sidebar-lock-commit-tests.log`, `.build/sidebar-lock-build-unsandboxed.log`, and `.build/sidebar-padding-build.log` for passing evidence.
- Outstanding: manual verification of the rebuilt UI in a temporary vault, keyboard focus and VoiceOver behavior, Reduce Motion, theme/System appearance/accent variations, and two-Mac iCloud behavior. Inspection of the running older app does not validate the rebuilt sidebar.

### D01.2 protocol and plaintext content adapter (2026-10-11)

- Added the vault-relative byte protocol, plaintext adapter, typed operation errors, create-only/expected-byte atomic writes, and snapshot-checked file/flat-directory moves and deletes. Existing repository flows and vault v1 bytes remain unchanged; integration is a separate step.
- Native `./scripts/test.sh --filter VaultContentStoreTests` passed all seven tests, including eight unsafe-path cases, binary/empty-byte round trips, occupied destinations, stale/missing-file preservation, symlink ancestry, and source-directory snapshots. Tests exposed and verified a fix for nonexistent leaves under symlinked parents. Restricted execution compiled but native coordination was blocked.
- The native full regression run passed all 122 tests (`.build/d012-regression.log`). Debug compilation, packaging, and signing passed (`.build/d012-build.log`); tracked brand exports were unchanged. Whitespace checks and supervisor selftest passed. No manual UI or two-Mac iCloud checks were performed. Actual unresolved cloud-version and provider hydration scenarios remain untested; explicit conflict refusal and hydration/unavailable handling are retained.

### Sidebar page-row trailing spacing (2026-10-11)

- Reduced page-row trailing padding from 8 to 4 points, giving titles 4 more points of available width. The existing row inset, lock control, and edit timestamp remain in place.
- `./scripts/build.sh debug` compiled, packaged, and signed successfully with native macOS service access; whitespace and supervisor compliance checks passed. No regression tests were added for this spacing-only change. Manual UI, theme/accent, VoiceOver, and Reduce Motion checks were not performed.

### D01.3 wiki page I/O migration (2026-10-11)

- FileVaultRepository now uses its VaultContentStore for wiki creation, scan cache misses, current-byte reads and expected-byte saves, trashed-page reads, and preserved conflict copies. NoteCodec, UUID/title/alias rules, hash checks, mtime/size scan caching, and the v1 canonical format remain intact. The default plaintext adapter retains the selected root for security-scoped access. Cloud-version enumeration/resolution stays under repository coordination; OS-owned version bytes are read with the existing coordinated helper, copied through the adapter, and all copies must succeed before any version is resolved. UI, sources, recovery journal implementation, and trash move/delete paths are unchanged.
- Added three focused integration tests (four parameterized cases) for adapter routing, create/edit/reopen, stable identity/filename and aliases, unknown YAML preservation, external Markdown without scan rewrites, cached scan reads, external-change detection, trashed-page reads, and modification/deletion between read and coordinated replacement. Both race cases verify canonical preservation, competing conflict drafts, and recovery-journal persistence after reopen.
- Native `./scripts/test.sh --filter WikiPageAdapterTests` passed; the final native full regression suite passed all 125 tests, including the subsequent trash-read assertion (`.build/d013-focused-native.log`, `.build/d013-regression.log`). The initial restricted run compiled but failed coordinated manifest writes with NSCocoaErrorDomain Code 512; native macOS services resolved the environmental block.
- Native `./scripts/build.sh debug` compiled, packaged, and signed successfully (`.build/d013-build.log`). Supervisor selftest passed all 17 policy parameters; whitespace checks passed. No manual UI/accessibility, actual provider hydration/unresolved cloud-version, or two-Mac iCloud verification was performed.
