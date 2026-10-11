import AppKit
import SwiftUI
import NoemaBrand

/// Isolated renders of the production SwiftUI mark, not screenshots of a running app.
/// Compiled by render-brand-mark.sh with the actual NoemaMark and theme environment.
@main
struct BrandMarkVerification {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw VerificationError.failed("Usage: render-brand-mark.sh OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0
        for dark in [false, true] {
            for (presentation, sizes) in [(NoemaMark.Presentation.identity, [76.0, 116.0]), (.glyph, [20.0, 64.0, 96.0])] {
                for size in sizes {
                    let mark = NoemaMark(presentation: presentation).frame(width: size, height: size)
                    let baseline = try render(mark, dark: dark)
                    for preference in ThemePreference.allCases {
                        var theme = NoemaTheme(dark: dark)
                        theme.preference = preference
                        let image = try render(mark.environment(\.noemaTheme, theme), dark: dark)
                        guard pixels(image) == pixels(baseline) else {
                            throw VerificationError.failed("Mark changed with \(preference.rawValue)")
                        }
                        checks += 1
                    }
                }
            }
            let image = try render(BrandingStudy(dark: dark), dark: dark)
            let name = "swiftui-\(dark ? "dark" : "light").png"
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw VerificationError.failed("PNG encoding failed")
            }
            try png.write(to: output.appendingPathComponent(name))
        }
        let result = """
        Isolated SwiftUI ImageRenderer verification using the production NoemaMark.
        These images are branding fragments, not running-application screenshots.
        \(checks) pixel assertions passed at 20/64/96-point glyphs and 76/116-point identity tiles:
        - Identical mark pixels across every ThemePreference in light and dark appearances.
        Contact sheets show the welcome identity and 20-point sidebar glyph on every
        interface palette background, including the native system window background.
        No application was launched and no appearance defaults were modified.
        SwiftUI's colourSchemeContrast and accessibilityReduceTransparency are read-only
        environment values, so this isolated harness does not simulate their system toggles.
        Increase Contrast colour guarantees are verified separately by BrandPaletteTests;
        NoemaMark uses opaque fills in every mode, without a Reduce Transparency branch.
        
        """
        try result.write(to: output.appendingPathComponent("swiftui-verification.txt"), atomically: true, encoding: .utf8)
        print(result)
    }

    @MainActor
    private static func render<V: View>(_ view: V, dark: Bool) throws -> CGImage {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        // Scope native dynamic colours to this draw; never change system/user defaults.
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image else { throw VerificationError.failed("SwiftUI ImageRenderer produced no image") }
        return image
    }

    private static func pixels(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }

    enum VerificationError: Error { case failed(String) }
}

private struct BrandingStudy: View {
    let dark: Bool
    private var appPalette: MidnightIrisPalette { .init(dark: dark) }

    var body: some View {
        VStack(spacing: 24) {
            Text("\(dark ? "Dark" : "Light") · isolated SwiftUI branding render")
                .font(.system(size: 13, weight: .medium))
            VStack(spacing: 24) {
                NoemaMark(presentation: .identity).frame(width: 116, height: 116)
                VStack(spacing: 10) {
                    Text("Noema").font(.system(size: 38, weight: .medium))
                    Text("A personal atlas of thought.").font(.title3)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(color(appPalette.token(.background)))
            VStack(alignment: .leading, spacing: 10) {
                Text("Sidebar glyph · 20 points · interface backgrounds").font(.system(size: 13, weight: .medium))
                ForEach(ThemePreference.allCases) { preference in
                    var theme = NoemaTheme(dark: dark)
                    let _ = theme.preference = preference
                    HStack(spacing: 6) {
                        NoemaMark(presentation: .glyph).frame(width: 20, height: 20)
                        Text("Noema").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(preference.title).font(.system(size: 12))
                    }
                    .foregroundStyle(theme.text(.textPrimary, on: .background))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(theme.color(.background))
                    .environment(\.noemaTheme, theme)
                }
            }
            HStack(alignment: .center, spacing: 48) {
                ForEach([20, 64, 96], id: \.self) { size in
                    VStack(spacing: 8) {
                        NoemaMark(presentation: .glyph).frame(width: CGFloat(size), height: CGFloat(size))
                        Text("\(size) pt").font(.system(size: 12))
                    }
                }
            }
            Text("Production OrbitGeometry · opaque fills · unchanged interface layout")
                .font(.system(size: 11))
        }
        .padding(28)
        .frame(width: 680)
        .foregroundStyle(color(appPalette.foreground(.textPrimary, on: .background)))
        .background(color(appPalette.token(.background)))
    }

    private func color(_ rgb: ThemeRGB) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
