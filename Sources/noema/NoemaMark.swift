import SwiftUI
import NoemaBrand

struct NoemaOrbitShape: Shape {
    var component: OrbitComponent? = nil
    func path(in rect: CGRect) -> Path { Path(OrbitGeometry.path(in: rect, component: component)) }
}

struct NoemaMark: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.noemaTheme) private var theme

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
            NoemaOrbitShape(component: .orbit).fill(theme.text(.accentPrimary, on: .background))
            NoemaOrbitShape(component: .satellites).fill(theme.text(.accentSecondary, on: .background))
            NoemaOrbitShape(component: .nucleus).fill(theme.text(.graphHighlight, on: .background))
        }
    }
}
