# UI.TYP08 — integration validation

Validated on 12 October 2026 with macOS 27.0, arm64, and Swift 6.2.4. The complete native package suite passed **285 tests in 32 suites in 64.784 seconds**, with process exit status 0. The final capture rerun passed **6 tests in 1 suite in 27.374 seconds**, also with exit status 0. Production code did not change between these runs; the capture fixture was adjusted to retain its fixed scroll viewport after native layout grows the document.

## Reproduce and inspect

```sh
NOEMA_TYPOGRAPHY_AFTER_CAPTURE_DIR=/absolute/output scripts/test.sh --scratch-path /private/tmp/noema-ui-typ02-build -j 4
NOEMA_TYPOGRAPHY_AFTER_CAPTURE_DIR=/absolute/output scripts/test.sh --scratch-path /private/tmp/noema-ui-typ02-build -j 4 --filter TypographyIntegrationTests
```

Use the canonical wrapper for this Command Line Tools installation's Swift Testing framework/plugin and cross-import-overlay flags. [Full native test output](Resources/Typography/Validation/full-tests.log) and [final capture output](Resources/Typography/Validation/capture-tests.log) retain the completed results. The opt-in `benchmarkSixteenSourceRowsAndUnchangedUpdates()` benchmark was skipped; the other enabled tests completed. The storage boundary guard passed 11 regression cases, 18 adversarial fixtures, and 40 reviewed exceptional calls. The native package build includes the application module; no personal vault or packaged application was launched for validation.

The [capture manifest](Resources/Typography/capture-manifest.csv) records dimensions and SHA-256 hashes for **84 PNGs**: eight [baseline images](Resources/Typography/Baseline/README.md) and 76 [final images](Resources/Typography/After/README.md). [Source hashes](Resources/Typography/Validation/source-sha256.txt) identify the final production sources and capture fixtures.

## Native coverage

| Check | Evidence |
| --- | --- |
| Editor layout | 72 configurations: system, Times New Roman, unavailable family; 10/16/32 pt; 420/1040 pt viewport widths; Light/Dark; semantic labels off/on. Native glyph bounds, selection, complete document equality, and canonical serialization are checked. |
| Source layout | 108 configurations: Markdown, HTML, plain text; the same families, sizes, widths and appearances. Shared editor/source font and paragraph attributes are compared, selection survives repeated presentation, and HTML import attributes remain unchanged. |
| Captures | 36 editor images with labels shown, 36 source images at 16 pt, two increased-contrast editor images, two static settings images. All use real AppKit text views or the real SwiftUI settings view. |
| Editing | Native typing, full selection ranges, scroll preservation, font changes, undo/redo and subsequent editing pass. Filling a parsed Markdown separator retains its caret baseline, selection and block identity. Font-only changes retain exact document equality; real content edits may update their modification timestamps. |
| Fonts and semantics | Native upright family weights select the nearest available weight for Avenir Next, Times New Roman and Helvetica. Missing families use the system fallback without overwriting the saved family. Label reservation, paragraph boundaries, lists, code and fitting mathematical previews are checked. |
| Stored content | Editor capture preserves model and Markdown serialization. An isolated real file repository/source store retains exact imported source bytes and snapshot through typography changes. Existing storage, source-reader and session tests pass. |
| Geometry | Programmatic native view resizing and wide/narrow fixtures check column alignment, nonnegative gutters and wrapped text. Existing geometry tests include 1000/500/320/1200 pt widths; semantic layout includes a 128 pt narrow case. |

At the 16 pt default, native line measurement over repeated independent English prose produced:

| Family | Text container width | Mean UTF-16 characters per complete line |
| --- | ---: | ---: |
| System | 559 pt | 72.7 |
| Times New Roman | 506 pt | 75.4 |

Both fall within the 65–80 character target. The shared width estimates 75 characters from the selected native body font and caps the result at 680 pt; narrower viewports use available space. These are measured fixture averages, not a guarantee for every language, font or string. Native editor/source column widths match.

Integration reconciled parsed blank separator spacing with source previews, retained stable caret behavior when those lines are filled, accounted for fractional first-label baselines, fitted mathematical overlays within native source line fragments, and made the reading measure font-aware. These changes affect presentation attributes and geometry; they add no serialized model fields.

## Capture provenance and visual review

The baseline's production sources are the audited `b6cd5c73bdc97b49c8016ac0bd97fa28a1c743c4` commit. All 62 tracked `Sources` files matched that commit byte-for-byte; [provenance](Resources/Typography/Baseline/provenance.txt) records the comparison. Only the copied capture fixture/wrapper was corrected to use the valid codec API, fixed viewport and native themed background. Its completed run passed one test in 2.561 seconds; [baseline output](Resources/Typography/Baseline/capture.log) is retained.

Baseline images show system 10/15/32 pt articles and the original source preview in Light/Dark at 840 × 940 pt. Final article/source images use 420 or 1040 × 1100 pt, increased-contrast articles use 840 × 1100 pt, and the production settings form retains its 540 pt width in a 1000 pt viewport. PNGs retain native backing scale: baseline images are 1× and final images are 2×. Comparisons are qualitative, not pixel golden assertions. Enlarged content may extend below the fixed viewport and is intentionally cropped vertically.

Visual review covered all eight baseline images and representative final system, serif, missing-family, minimum/default/enlarged, wide/narrow, source and increased-contrast settings images. The integration agent and parent reviewer inspected final regenerated samples; no visible overlap or horizontal clipping was found in those samples. The raster tests also check that every generated fixture contains native rendered content. All 76 final PNGs were generated; they were not all manually inspected.

## Accessibility and live-check limits

Increased contrast uses explicit `NoemaTheme(increasedContrast: true)` and native high-contrast Light/Dark appearances. Primary and muted text satisfy at least 7:1 contrast against the fixture surface, and existing design-token contrast tests pass. Preference fixtures use isolated defaults and disable SwiftUI animation transactions for a static capture. The actual OS Reduce Motion value was read as **false** and was not changed; these captures do not establish behavior with OS Reduce Motion enabled.

Live VoiceOver, keyboard accessibility traversal, pointer-driven window resizing, sidebar/inspector combinations and live source-window updates were not exercised. Automated native view resizing verifies geometry at fixed available widths; it does not establish interactive pane behavior. Native editing and undo/redo were exercised by automated real AppKit views. PDF/image/media Quick Look visuals were not captured; existing source/session and byte-preservation checks cover their integration boundaries.
