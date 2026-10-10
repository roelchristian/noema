# noema orbital identity

The broken orbit, two satellites, and central ring adapt the supplied reference into a symbol for connected thoughts. `Sources/NoemaBrand/OrbitGeometry.swift` is the single source of geometry for the SwiftUI mark, SVG layer, and packaged icon.

In the app, `NoemaMark` uses SwiftUI's real `glassEffect(_:in:)` material with this silhouette. The Midnight Iris identity uses indigo for the orbit, cyan for satellites, and violet for the nucleus. Reduce Transparency and increased contrast use opaque, contrast-adjusted foregrounds. No custom animation is applied, so there is no motion to suppress. `Sources/NoemaBrand/MidnightIris.swift` supplies the semantic light and dark tokens for both the app and icon generator.

`scripts/build.sh` regenerates these assets:

- `orbit.svg`: transparent dark-appearance foreground geometry, with open ring centers.
- `background.svg`: full square midnight navy background, without a baked-in mask.
- `orbit-light.svg` and `background-light.svg`: matching light-appearance layers.
- `icon-preview.png`: preview of the flattened `.icns` fallback shipped by the command-line build.

For a system-rendered layered Dock icon, import the SVG layers into Apple's Icon Composer, use the orbit as the glass foreground, and let the system supply highlights, refraction, shadows, and masking. Preview light, dark, clear, and tinted appearances there, then add the saved `.icon` to an Xcode app target. This SwiftPM packaging workflow currently ships `.icns`; it does not compile `.icon` assets. Icon Composer and the Xcode asset tools are not installed on the development machine.

Design guidance: [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), and [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
