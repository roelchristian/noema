# UI.TYP final native captures

The finalized production renderer and corrected fixed-viewport fixture produced **76 PNGs** on 12 October 2026. `TypographyIntegrationTests` passed all six tests during this final export; see [capture-tests.log](../Validation/capture-tests.log). The preceding complete native suite passed 285 tests in 32 suites; see [full-tests.log](../Validation/full-tests.log).

The native matrix tests render 72 editor configurations (three families × three sizes × two widths × two appearances × semantic labels off/on), and 108 source configurations (three source modes × three families × three sizes × two widths × two appearances). Export retains 36 editor configurations with labels shown, 36 source configurations at 16 pt, two increased-contrast editor fixtures, and two static preference fixtures. All cases use real AppKit text views; preferences use the real SwiftUI settings view with isolated defaults.

`system` uses the empty-family sentinel; `serif` uses Times New Roman; `missing` preserves an unavailable family and renders the system fallback. Article/source viewports are 420 or 1040 × 1100 pt. Increased-contrast editor fixtures use 840 × 1100 pt. Settings retain the production form's 540 pt width and a 1000 pt viewport. Enlarged/narrow content is intentionally cropped vertically within the scroll viewport. PNGs preserve the native backing scale; the [manifest](../capture-manifest.csv) records actual pixel dimensions and SHA-256 hashes. Baseline captures use their separate original 840 × 940 pt viewport, so these are qualitative comparisons rather than pixel golden tests.

Reproduce the final export:

```sh
NOEMA_TYPOGRAPHY_AFTER_CAPTURE_DIR=/absolute/output scripts/test.sh --filter TypographyIntegrationTests
```

Ordinary tests validate layout and nonblank rasters without exporting files. Captures do not open a personal vault or change global preferences. Appearance and increased contrast are explicit fixture inputs; static settings captures disable SwiftUI transactions. Actual OS Reduce Motion was read as false and was not changed. No live VoiceOver, keyboard accessibility traversal, drag-resize, or sidebar/inspector interaction was exercised. See [the validation report](../../../UI_TYPOGRAPHY_VALIDATION.md) for checks and limits.
