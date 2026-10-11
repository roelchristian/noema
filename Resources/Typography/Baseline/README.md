# UI.TYP baseline native captures

Captured 12 October 2026 from production sources at `b6cd5c73bdc97b49c8016ac0bd97fa28a1c743c4`, preserved in `/private/tmp/noema-typography-baseline-b6cd5c7`. [provenance.txt](provenance.txt) records the byte-for-byte comparison of every tracked production source against that commit. Later UI.TYP production changes did not enter this baseline.

Eight PNGs show the real native article renderer at system sizes 10, 15, and 32 pt and the pre-change MarkdownPreview in Light and Dark appearances. Every capture uses an 840 × 940 pt viewport. The enlarged article intentionally crops below the viewport; it is not shrunk to fit. Fixtures use the default Midnight Iris surface.

The UI.TYP01 fixture was corrected in UI.TYP08 to call `BlockDocumentCodec`, capture through a fixed scroll viewport, and render decorations over the native theme surface. These corrections affect fixture composition only; baseline production sources remain unchanged. Native fixture selection, editing, and VoiceOver were not exercised by this capture run.

Reproduce by copying `Tests/NoemaEditorTests/TypographyBaselineCaptureTests.swift` and the canonical `scripts/test.sh` wrapper into a checkout of the audited base, then run:

```sh
NOEMA_TYPOGRAPHY_CAPTURE_DIR=/absolute/output scripts/test.sh --filter TypographyBaselineCaptureTests
```

The completed run passed one capture test; [capture.log](capture.log) retains its native compiler/test output. The fixture asserts nonblank raster content. See [the validation report](../../../UI_TYPOGRAPHY_VALIDATION.md) for after captures, visual inspection, automated editing checks, and live-check limitations.
