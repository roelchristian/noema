import SwiftUI
import NoemaBrand

struct NoemaOrbitShape: Shape {
    var component: OrbitComponent? = nil
    func path(in rect: CGRect) -> Path { Path(OrbitGeometry.path(in: rect, component: component)) }
}

struct NoemaMark: View {
    enum Presentation {
        /// A complete identity tile, for welcome and empty-state branding.
        case identity
        /// Opaque ink on a transparent canvas, for compact interface branding.
        case glyph
    }

    var presentation: Presentation = .glyph
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    private var palette: NoemaBrandPalette { .init(dark: scheme == .dark, increasedContrast: contrast == .increased) }

    var body: some View {
        Group {
            switch presentation {
            case .identity:
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    artwork
                        // Preserve the welcome frame while giving its 116-point tile
                        // a 96-point geometry canvas. Scale the same inset at any size.
                        .padding(side * 10 / 116)
                        .frame(width: side, height: side)
                        .background {
                            RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
                                .fill(color(palette.token(.identityBackground)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .glyph:
                artwork
            }
        }
        // Opaque component fills preserve narrow edges at 20 points and support
        // Reduce Transparency without an alternate rendering or glass refraction.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Noema")
    }

    private var artwork: some View {
        ZStack {
            NoemaOrbitShape(component: .orbit).fill(componentColor(.orbit))
            NoemaOrbitShape(component: .satellites).fill(componentColor(.satellites))
            NoemaOrbitShape(component: .nucleus).fill(componentColor(.nucleus))
        }
    }

    private func componentColor(_ role: NoemaBrandRole) -> Color {
        // A fixed margin keeps increased-contrast glyphs above 7:1 on
        // every interface palette without allowing that palette to recolor them.
        let minimumContrast = presentation == .glyph && contrast == .increased ? 9.0 : 3.0
        return color(palette.foreground(role, minimumContrast: minimumContrast))
    }

    private func color(_ rgb: ThemeRGB) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
