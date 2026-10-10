import SwiftUI
import NoemaBrand

struct NoemaOrbitShape: Shape {
    var component: OrbitComponent? = nil
    func path(in rect: CGRect) -> Path { Path(OrbitGeometry.path(in: rect, component: component)) }
}

struct NoemaMark: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    private var palette: MidnightIrisPalette { .init(dark: scheme == .dark, increasedContrast: contrast == .increased) }

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                artwork
            } else {
                artwork
                    .glassEffect(.regular, in: NoemaOrbitShape())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("noema")
    }

    private var artwork: some View {
        ZStack {
            NoemaOrbitShape(component: .orbit).fill(Color(nsColor: palette.foreground(.accentPrimary, on: .background).nsColor))
            NoemaOrbitShape(component: .satellites).fill(Color(nsColor: palette.foreground(.accentSecondary, on: .background).nsColor))
            NoemaOrbitShape(component: .nucleus).fill(Color(nsColor: palette.foreground(.graphHighlight, on: .background).nsColor))
        }
    }
}
