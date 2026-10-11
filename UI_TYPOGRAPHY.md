# Noema editorial typography contract — UI.TYP01

Audit date: 12 October 2026. Audited production base: `b6cd5c73bdc97b49c8016ac0bd97fa28a1c743c4`.
This document specifies the UI.TYP workstream; UI.TYP01 adds documentation and an opt-in capture fixture only. Values below distinguish the **audited baseline** from the **implementation contract**. The implementation and validation report must record any departures from these targets.

## Ownership and inventory

`EditorTypography` is the sole owner of configurable document fonts and editorial metrics. Extend it with semantic roles and font/paragraph resolution; do not create a source-specific or SwiftUI-specific competing font resolver. `NoemaTypography` in `DesignTokens.swift` owns application chrome. Consumers may translate a resolved AppKit font to SwiftUI `Font`; they must not invent a second scale. `BlockTextStorage` owns applying styles to block and inline attributes. `ArticleTextView` owns native layout and drawing, using resolved metrics rather than choosing fonts. User document preferences do not change navigation, tables, toolbar controls, or source metadata.

The inventory covers explicit font paths found by `rg -n 'NSFont|\\.font\\(|fontSize|fontFamily' Sources`; views that inherit native control fonts belong to the chrome owner. Presentation exceptions are assigned explicitly rather than silently becoming editorial styles.

| Production path | Audited behavior | Owner / action |
| --- | --- | --- |
| `EditorTypography.swift` | Default 15 pt; 10–32 clamp; `editorFontFamily`/`editorFontSize`; custom nonregular weights all converted to bold | Editorial resolver; UI.TYP02 hierarchy and UI.TYP06 preferences |
| `BlockTextStorage.swift` | H1/H2/H3 offsets +14/+8/+4; body regular; code and display-math source size −2; inline code keeps role size; math uses italic system serif; line spacing 5; paragraph after 10; heading before 12; semantic/quote/callout/code/math before 12 and after 18 | Editorial attribute application; UI.TYP02/03; UI.TYP07 semantic reservation |
| `RichArticleView.swift` | Reads saved document preferences and rerenders existing block document; fixed 80×24 inset; outer wrappers capped at 980; summary labels use native callout/caption/headline | UI.TYP04 editorial geometry; UI.TYP06 preference refresh; summary controls remain chrome, summary prose is editorial |
| `ArticleTextView.swift` | Semantic title uses `BlockTextStorage.semanticHeadingFont`; list/structural marker 13 pt, language label 10 pt, callout icon 14 pt medium, drag title 13 pt; decoration rectangles derive actual glyph metrics | UI.TYP07 labels/decorations; UI.TYP04 gutter positions. Drag label belongs to chrome |
| `NativeTextViews.swift` / `MarkdownEditor` | Raw Markdown 14 pt system mono, 28×24 inset | Editorial code role and UI.TYP06 refresh; underlying plain Markdown unchanged |
| `NativeTextViews.swift` / `MarkdownPreview` | Body 15; H1–H6 29/23/19/17/16/15; quote indent 16; code 13 (inline span another −1); math 16 italic serif; line/paragraph 6/16, code line 3, heading before 16, math before/after 12/18 | UI.TYP05 maps readable previews to shared editorial roles; native link routing remains consumer-owned |
| `SourceReader.swift` | Separate read-only window; md/txt/html begin at system 14; Markdown/HTML imported attributed styles; 24×24 inset; appearance updates reset attributed text, preserve range and recolor; nontext uses Quick Look | UI.TYP05 readable prose and links use editorial resolver; Quick Look owns PDF/media/file rendering; access gates and immutable originals remain source owner |
| `ContentView.swift` / page header | `NoemaTypography.documentTitle` for name field/read-only page header, metadata tokens for tags, saving, word count, backlinks; independent editor document headings | Page-name field remains chrome title; content H1 belongs to editorial resolver; UI.TYP04 align header and body measure |
| `DesignTokens.swift` | Semantic SwiftUI title/headline/callout/caption styles | UI.TK chrome owner; retain tokens without root font overrides |
| `ContentView.swift` / navigation, library, sheets, notices | Mostly tokenized navigation/interface/metadata; native headline/callout/caption in dialogs and search previews; welcome/empty state 46 pt icon, 32/38 pt name, 8 pt status glyph | UI.TK chrome; UI.W welcome composition; fixed symbol/logo optical sizes are chrome exceptions, not document font preferences |
| `Inspector/{InspectorContainer,InspectorTabBar,PropertiesPanel,LinksPanel,TagsPanel,InsightsPanel,ReferencesPanel}.swift` | Tokens for titles, values, metadata and tabs; container notice `.body`; generated summary/snippet text currently inherits interface tokens | Inspector layout/navigation owner with UI.TK fonts; reading-summary prose may consume editorial supporting role without restyling metadata |
| `ChromeInteractionStyle.swift` | Notice/control metadata token | UI.TK chrome |
| `BlockCommands.swift` | AppKit command-category 11 pt semibold; command button/title 14 pt | Native command-palette chrome; selection does not follow document font |
| `EditorSettings.swift` | Native picker, stepper; caption/callout explanatory labels; monospaced system body TeX command fields and sample code; title/headline labels | UI.TYP06 owns document preference UX; all settings labels and TeX authoring controls remain native chrome |
| `NoemaAbout.swift`, `VaultCreationSheet.swift` | System semantic large title/body/caption and title2/subheadline/callout | UI.TK/about and vault-creation chrome; outside editorial scale |
| `SourcesLibraryView.swift`, native toolbar/menu/control defaults | Native table, controls and inherited platform fonts | UI.TK/library owner; no document preference propagation |
| `VaultCore/{BlockDocument,MarkdownService,TeXMath}.swift` | Parsing, metadata, Markdown/TeX-to-readable-string conversion, no application font selection | Content model owner; UI.TYP must not change serialization or canonical source bytes |
| `NoemaBrand` and brand resources | Logo/vector artwork, no document font resolver | UI.B owner; unchanged |

## Editorial roles and type hierarchy

Let `b` be the validated saved reading size. A new profile defaults to **16 pt**, while an existing valid saved size—including 15 pt—remains the selected size. Keep the current keys, empty-family system sentinel, and 10–32 pt range. Missing size uses 16; nonfinite values use 16; finite out-of-range values clamp. An unavailable saved family resolves to the native system family while preserving the saved preference so reinstalling the font can restore it.

| Role | Size relative to `b` | Requested weight / design | At `b = 16` |
| --- | --- | --- | --- |
| H1 | 1.93 | Semibold, chosen reading family | 30.88 pt |
| H2 | 1.53 | Semibold, chosen reading family | 24.48 pt |
| H3 | 1.27 | Semibold, chosen reading family | 20.32 pt |
| Body, lists, quotes, semantic block content | 1.00 | Regular, chosen reading family | 16 pt |
| Supporting prose | 0.88 | Regular, chosen reading family | 14.08 pt |
| Code (block and inline) | 0.88 | Native monospaced; bold/italic only when content requests them | 14.08 pt |
| Semantic label | 0.88 | Medium or semibold native interface family | 14.08 pt |
| Mathematical text | 1.00 | Readable system serif italic for rendered inline math; monospaced code role for raw TeX | 16 pt rendered |

H4–H6 in source previews should degrade monotonically between H3 and emphasized body; they must not be promoted above H3. Resolve genuine medium/semibold faces through descriptors or family members before using a nearest available face. A family with only regular/bold may choose the closest supported weight. Never map every requested nonregular weight directly to bold. Font choice must preserve inline bold, italic, underline, strike, highlight, code, wiki links, and URL semantics; presentation traits must not be captured as new content styles.

Quotes use the body family, restrained semantic color and indentation, rather than an obligatory italic/serif body. Supporting **prose** is distinct from metadata: dates, file size, source kind, tags, language badges, and counts remain native caption/interface styles. A serif reading family may be chosen; it is optional and does not affect chrome.

## Rhythm and native line metrics

Line height is a font-metric-dependent reading measurement, not a fixed number of extra points. Compute the native line height for the resolved font and target normal body baseline separation near `1.50 × b`; the default-system-font acceptance band is `1.45…1.55 × b`. Derive nonnegative extra leading from actual native metrics (e.g. `NSLayoutManager.defaultLineHeight(for:)`) and avoid forcing a line box that clips tall ascenders, descenders, fallback glyphs, or math. Larger heading metrics should remain comfortable without multiplying body paragraph gaps again.

Use one documented boundary-spacing policy in the editorial resolver / attribute application layer. Baseline design references are paragraph separation around `0.65 × b`, heading-before around `0.9 × b`, heading-after around `0.45 × b`, and tighter continuation spacing within a list. UI.TYP03 must choose exact rules and verify measured native behavior: a boundary gets a single intended gap, never an accidental sum of outgoing paragraph spacing and incoming heading spacing. Consecutive headings use the larger required boundary, not two stacked gaps. Paragraphs within one multiline block and continued/nested list text share baseline rhythm without adding a block gap on every wrapped line. Empty blocks retain a caret line; first-paragraph spacing must account for AppKit ignoring `paragraphSpacingBefore` at document start.

Semantic heading reservation is derived from resolved label ascender/descender plus a small optical gap. Reserve it only for the first paragraph of that block. Showing or hiding labels changes the reserved label area, not canonical text, block IDs, or selection offsets. Nested semantic labels, markers, and quote accents must follow glyph baselines and content indentation. UI.TYP07 owns this geometry.

## Reading measure and geometry

UI.TYP04 owns editorial geometry, coordinated with `ArticleTextView` decoration drawing. The prose line measure is capped at **680 pt** at ordinary desktop sizes, centered in the actually available editor viewport. This is a geometric ceiling, not a promise that every family/size produces exactly the same character count. The target at ordinary reading settings is roughly 65–80 characters per line. Deduct container padding, scrollbar space and reserved marker/decoration gutters when calculating the measure; do not center against the full window width when navigation or inspector panes consume it.

At narrow widths, use available width with compact, nonnegative gutters. Text must wrap without horizontal scrolling or decorations entering the text. Centering must preserve marker hit testing, block drag affordances, title/body alignment, scroll offsets and semantic-label reservation. Window, sidebar and inspector constraints remain their existing owners. Fixed optical gaps, control hit areas and gutter bounds can remain points; line heights, heading scale and prose paragraph rhythm derive from typography metrics.

## Source and preference behavior

Readable extracted articles, Markdown previews and UTF-8 text sources consume the same reading family and role metrics as wiki content. Markdown/HTML heading, quote, code and link semantics remain intact while typographic attributes adopt the shared contract. Plain text is readable prose unless explicitly shown as source code. An unavailable source uses native explanatory UI. Quick Look remains responsible for original PDF/image/media presentation. Never persist rewritten fonts into the original file or write transformed content to source storage.

Preferences are described as **document reading and editing** settings. Show useful family previews and an understandable system fallback without adding independent spacing/density controls. Open documents and readable source windows should update in place; preserve text, full selection length, caret position, undo history, editing mode and current scroll where native layout allows. A font-only update must not reload a draft or register a content edit. Live reflow may move a glyph's screen position naturally; it must not move the selected character index unexpectedly.

## Baseline evidence and reproduction

`Tests/NoemaEditorTests/TypographyBaselineCaptureTests.swift` is an opt-in native AppKit/SwiftUI capture fixture. It renders the real `BlockTextStorage`/`ArticleTextView` and `MarkdownPreview` paths in light and dark appearances. Article cases explicitly use the pre-change system sizes 10, 15 and 32. The preview captures demonstrate its separate fixed baseline typography. Fixtures are 840×940 pt and show H1–H3, wrapped body text, inline styles, links, quote, list continuation, code and a semantic block. The largest-size crop is intentional: it records the same viewport rather than shrinking enlarged text to fit.

To reproduce the baseline, use production sources at the audited base commit and copy the capture test into that checkout; running on later production sources is an **after** comparison. The captured sources were copied from the unchanged original checkout into `/private/tmp/noema-typography-baseline-b6cd5c7`, so concurrent production edits in the integration worktree cannot contaminate the baseline. Enable capture explicitly:

```sh
NOEMA_TYPOGRAPHY_CAPTURE_DIR=/absolute/output/directory scripts/test.sh --filter TypographyBaselineCaptureTests
```

Use the canonical `scripts/test.sh` wrapper: this Command Line Tools installation requires its Swift Testing framework/plugin and cross-import-overlay flags. Ordinary test runs do not write PNGs or modify stored preferences. Capture results and inspected images are recorded in `Resources/Typography/Baseline/README.md` when native capture succeeds. These are rendered native fixtures, **not live application interaction screenshots**. They do not establish VoiceOver behavior, keyboard focus, editing/undo correctness, or window/pane resizing. UI.TYP08 must report those checks separately and identify what was not exercised.

## Integration acceptance

UI.TYP02–07 implement their assigned layers; UI.TYP08 reconciles them and owns final regression evidence. Validate minimum/default/enlarged sizes, system/available custom/missing families, light/dark appearances, wide/narrow viewports, sidebar/inspector combinations, long documents, empty blocks, consecutive headings, lists, semantics and preview parity. Serialization and source-byte checks must demonstrate that typography is presentation-only. Selection and editing checks must exercise native views; static font-size assertions alone do not establish layout or caret correctness. The final PR records task IDs, checks, capture provenance and any live accessibility/layout limitations.

## Implemented integration policy — UI.TYP08

The maximum reading width remains 680 pt. `EditorTypography.readingMeasureWidth` now estimates a 75-character line from the selected body font's native width of an independent English reference sentence, then caps it at 680 pt. `ReadingGeometry` applies that limit within the actual viewport and its required gutters. Native editors/readers and preference-observing SwiftUI title/summary columns consume that one measure. Enlarged text can reach the ceiling; this is an approximate reading target rather than a guarantee for every language or string. The validation report records measured native results at default system and serif settings.

Boundary spacing is owned by the incoming content paragraph. Parsed Markdown separator blocks retain their native empty caret line and receive zero extra spacing, without resetting the preceding nonempty role. A presentation-only `noema.markdownSeparator` attributed-string marker derives from the block's existing blank `originalMarkdown`; it persists while that line is filled so typing cannot suddenly add a paragraph gap. Newly created empty editing blocks keep the normal incoming boundary so their first typed glyph also retains its caret baseline. Neither case adds serialized fields or removes blank content. Semantic heading reservation uses the same preceding-role context. Plain-text/HTML source separator paragraphs similarly receive no extra boundary gap; their exact text remains unchanged.

Semantic labels use native semibold at 0.88 × body size. Their first-document reservation includes a 1 pt optical allowance for fractional native baseline rounding. Raw mathematical source uses the code face, with enough line height for the optional larger mathematical preview. That preview is centered within the native line fragment and shown only when the source is one unwrapped line and the unused horizontal/vertical space fits it. Narrow or wrapped source retains the readable raw text.

The final evidence is in [UI_TYPOGRAPHY_VALIDATION.md](UI_TYPOGRAPHY_VALIDATION.md). Baseline and after captures are opt-in fixtures; ordinary test runs validate native layout and raster content without creating PNGs. Capture routines never open a personal vault or change global font preferences.
