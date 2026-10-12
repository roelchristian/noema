import SwiftUI

/// The prose measure is independent of the editor's full-width scroll view.
struct ReadingGeometry {
    static let maximumContentWidth: CGFloat = 680
    static let horizontalInset: CGFloat = 24
    // Semantic icons begin 46 pt before the text; the drag-control hit area ends at 29 pt.
    static let editorHorizontalInset: CGFloat = 60

    let contentWidth: CGFloat
    let horizontalInset: CGFloat

    init(availableWidth: CGFloat, reservesEditorGutter: Bool = false, maximumContentWidth: CGFloat = Self.maximumContentWidth) {
        let width = availableWidth.isFinite ? max(0, availableWidth) : 0
        let preferredInset = reservesEditorGutter ? Self.editorHorizontalInset : Self.horizontalInset
        // Small split panes retain usable prose width instead of a fixed-width column.
        let minimumInset = min(preferredInset, width / 4)
        let limit = maximumContentWidth.isFinite ? min(Self.maximumContentWidth, max(0, maximumContentWidth)) : Self.maximumContentWidth
        contentWidth = min(limit, max(0, width - 2 * minimumInset))
        horizontalInset = (width - contentWidth) / 2
    }
}

/// Uses the same centered measure for SwiftUI prose and the native editor.
struct ReadingColumnLayout: Layout {
    var reservesEditorGutter = false
    var maximumContentWidth = ReadingGeometry.maximumContentWidth

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let outerInset = reservesEditorGutter ? ReadingGeometry.editorHorizontalInset : ReadingGeometry.horizontalInset
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? maximumContentWidth + 2 * outerInset
        let geometry = ReadingGeometry(availableWidth: width, reservesEditorGutter: reservesEditorGutter, maximumContentWidth: maximumContentWidth)
        let content = subviews.first?.sizeThatFits(ProposedViewSize(width: geometry.contentWidth, height: proposal.height)) ?? .zero
        return CGSize(width: max(0, width), height: content.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let geometry = ReadingGeometry(availableWidth: bounds.width, reservesEditorGutter: reservesEditorGutter, maximumContentWidth: maximumContentWidth)
        subviews.first?.place(at: CGPoint(x: bounds.minX + geometry.horizontalInset, y: bounds.minY),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: geometry.contentWidth, height: bounds.height))
    }
}

private struct ReadingColumnModifier: ViewModifier {
    var reservesEditorGutter: Bool
    @AppStorage(EditorPreferences.fontFamilyKey) private var family = ""
    @AppStorage(EditorPreferences.fontSizeKey) private var size = EditorTypography.defaultSize

    func body(content: Content) -> some View {
        ReadingColumnLayout(reservesEditorGutter: reservesEditorGutter,
                            maximumContentWidth: EditorTypography(family: family, size: size).readingMeasureWidth) { content }
    }
}

extension View {
    func readingColumn(reservesEditorGutter: Bool = false) -> some View {
        modifier(ReadingColumnModifier(reservesEditorGutter: reservesEditorGutter))
    }
}
