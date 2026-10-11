# Noema orbital identity

`Sources/NoemaBrand/OrbitGeometry.swift` is the single source of the broken orbit, two satellites, and central ring. SwiftUI, SVG exports, and the packaged application icon all call this geometry; no renderer maintains a separate silhouette. Paths use a top-left origin and scale proportionally within a square. The SVG artwork retains its original 1024-point canvas and 778-point geometry frame at (123, 123). The flattened application icon retains its original rounded tile inset of 6% and geometry inset of 12%.

`Sources/NoemaBrand/NoemaBrandPalette.swift` defines the permanent identity, independently of `ThemePreference` and user settings. `MidnightIrisPalette` remains the configurable interface palette for surfaces, text, and controls. Selecting Forest, Amber, Rose, or another interface theme never changes these brand tokens:

| Brand token | Porcelain Iris (light) | Midnight Iris (dark) |
| --- | --- | --- |
| Identity background | `#F4F5FA` | `#101827` |
| Primary orbit | `#4358A8` | `#6478E8` |
| Satellites | `#287F9E` | `#61C6DF` |
| Nucleus | `#7767C2` | `#A49AF4` |

`scripts/Icon.swift` consumes the raw canonical `token(_:)` values. Runtime accessibility contrast correction belongs to `foreground(_:against:minimumContrast:)` and does not mutate the export tokens. In the app, `NoemaMark` uses the effective SwiftUI colour scheme, with a background-backed welcome identity and a compact transparent sidebar glyph. Reduce Transparency and Increase Contrast receive opaque, legible foregrounds. See [the brand contract](CONTRACT.md) for the palette API and accessibility requirements.

## Generated artwork

All files below derive from the shared palette and geometry:

- `orbit.svg` and `background.svg`: dark foreground and full square background layers. Ring centres remain transparent in the foreground.
- `orbit-light.svg` and `background-light.svg`: corresponding light layers with the Porcelain Iris background.
- `identity-dark.svg` and `identity-light.svg`: complete square compositions of the respective foreground and background layers, with no icon mask or lighting.
- `identity-dark.png` and `identity-light.png`: 1024-pixel raster previews of those complete identities.
- `icon-preview.png`: 1024-pixel preview of the dark flattened application icon, including its rounded tile and transparent outer margin.

SVG paths use fixed three-decimal, locale-independent coordinates. Rendering uses no random input, timestamps, or mutable application preferences. Repeated generation with the same source and macOS rendering tools produces identical assets.

## Reproduction and packaging

From the repository root, regenerate and verify assets without building the application:

```sh
mkdir -p .build/brand-assets/ModuleCache
swiftc -module-cache-path .build/brand-assets/ModuleCache \
  Sources/NoemaBrand/OrbitGeometry.swift \
  Sources/NoemaBrand/MidnightIris.swift \
  Sources/NoemaBrand/NoemaBrandPalette.swift \
  scripts/Icon.swift -o .build/brand-assets/icon-generator
.build/brand-assets/icon-generator .build/brand-assets/VaultIcon.iconset Resources/Brand
iconutil -c icns .build/brand-assets/VaultIcon.iconset \
  -o .build/brand-assets/VaultIcon.icns
```

The generator creates the standard 16, 32, 64, 128, 256, 512, and 1024-pixel iconset representations, including the expected Retina filenames. `scripts/build.sh` compiles the same sources, regenerates these exports, and packages `VaultIcon.icns` into `noema.app/Contents/Resources`. The existing SwiftPM build, signing, and archive process remains in place.

The `.icns` fallback intentionally uses the dark Midnight Iris identity in every system appearance. Light/dark exported artwork does **not** enable automatic Dock icon appearance switching. The About window displays `NSApplication.shared.applicationIconImage` at 64 points, so it matches the native application identity used by Finder and the Dock. The welcome mark is adaptive in-app artwork and is not a substitute for that native application icon.

Separate background and foreground SVG layers remain available for a future layered icon workflow. They contain no baked-in lighting, material effect, or mask. This SwiftPM pipeline does not compile layered `.icon` assets; adopting that packaging is outside UI.B3.

## Visual verification

The complete export previews above show both appearance variants and the packaged icon. `Resources/Brand/Verification/` contains isolated SwiftUI branding renders and their verification report. Reproduce them with:

```sh
scripts/render-brand-mark.sh Resources/Brand/Verification
```

The harness compiles the real `NoemaMark` in an isolated temporary directory and renders welcome identity and sidebar fragments for light/dark appearances. It includes 20-, 64-, and 96-point glyphs and every interface theme's sidebar background. These are component renders, not screenshots of a running application; the harness does not change application preferences. Its report records pixel checks for theme invariance. Read-only SwiftUI accessibility environment values prevent this harness from simulating system accessibility toggles; contrast correction is covered by palette tests, while the mark's opaque rendering supports Reduce Transparency. `Verification/export-verification.txt` records repeat-generation and native icon packaging checks.
