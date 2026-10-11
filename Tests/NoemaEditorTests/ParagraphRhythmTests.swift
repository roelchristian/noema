import AppKit
import Testing
import VaultCore
@testable import noema

@Test @MainActor func editorialLineMetricsUseNativeFontHeightWithoutClipping() {
    for family in ["", "Avenir Next", "Times New Roman", "Unavailable Noema Rhythm Font"] {
        for size in [10.0, 16, 32] {
            let typography = EditorTypography(family: family, size: size)
            for role in EditorTypography.Role.allCases {
                let metrics = typography.lineMetrics(for: role)
                let paragraph = typography.paragraphStyle(for: role)
                #expect(metrics.nativeHeight > 0)
                #expect(metrics.baselineSeparation >= metrics.nativeHeight)
                #expect(paragraph.lineSpacing >= 0)
                #expect(paragraph.maximumLineHeight == 0)
                #expect(paragraph.minimumLineHeight == 0)
                #expect(abs(metrics.nativeHeight + paragraph.lineSpacing - metrics.baselineSeparation) < 0.001)
            }
        }
    }
    let typography = EditorTypography()
    let storage = NSTextStorage(string: "Readable line\nReadable line\nReadable line", attributes: [
        .font: typography.font(for: .body), .paragraphStyle: typography.paragraphStyle(for: .body)
    ])
    let layout = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: 600, height: 2000))
    layout.addTextContainer(container); storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)
    func baseline(_ character: Int) -> CGFloat {
        let glyph = layout.glyphIndexForCharacter(at: character)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + layout.location(forGlyphAt: glyph).y
    }
    let separation = baseline(14) - baseline(0)
    #expect(separation >= 16 * 1.45)
    #expect(separation <= 16 * 1.55)
}

@Test @MainActor func incomingParagraphOwnsSingleHeadingAndListBoundary() {
    for size in [10.0, 16, 32] {
        let typography = EditorTypography(size: size)
        for role in EditorTypography.Role.allCases {
            #expect(typography.paragraphStyle(for: role).paragraphSpacingBefore == 0)
            for previous in EditorTypography.Role.allCases {
                let paragraph = typography.paragraphStyle(for: role, previous: previous)
                #expect(paragraph.paragraphSpacing == 0)
                #expect(paragraph.paragraphSpacingBefore == typography.boundarySpacing(before: role, after: previous))
            }
        }
        #expect(typography.boundarySpacing(before: .heading2, after: .heading1) == size * 0.9)
        #expect(typography.boundarySpacing(before: .body, after: .heading2) == size * 0.45)
        #expect(typography.boundarySpacing(before: .list, after: .list) < typography.boundarySpacing(before: .body, after: .body))
        #expect(typography.boundarySpacing(before: .quote, after: .quote) < typography.boundarySpacing(before: .body, after: .body))
    }
}

@Test @MainActor func multilineEmptyAndNestedBlocksShareRhythmWithoutRepeatedGaps() throws {
    let child = EditorBlock(kind: .bullet, runs: [RichRun("Nested\ncontinued")])
    let document = BlockDocument(blocks: [
        EditorBlock(runs: [RichRun("Opening\ncontinuation")]),
        EditorBlock(kind: .heading1, runs: [RichRun("First heading")]),
        EditorBlock(kind: .heading2, runs: [RichRun("Second heading")]),
        EditorBlock(),
        EditorBlock(kind: .bullet, runs: [RichRun("List item")], children: [child]),
        EditorBlock(kind: .quote, runs: [RichRun("Quotation\ncontinued")]),
        EditorBlock(kind: .quote, runs: [RichRun("Next quotation")])
    ])
    let typography = EditorTypography()
    let rendered = NSMutableAttributedString(attributedString: BlockTextStorage.render(document, theme: NoemaTheme(dark: false), typography: typography))
    var previous: EditorTypography.Role?
    let text = rendered.string as NSString
    for (id, range) in BlockTextStorage.ranges(rendered) {
        let block = try #require(document.block(id))
        let role = EditorTypography.role(for: block.kind)
        let first = text.paragraphRange(for: NSRange(location: range.location, length: 0))
        rendered.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
            let paragraph = value as! NSParagraphStyle
            #expect(paragraph.paragraphSpacing == 0)
            let expected = part.location < NSMaxRange(first) ? typography.boundarySpacing(before: role, after: previous) : 0
            #expect(paragraph.paragraphSpacingBefore == expected)
        }
        previous = role
    }
    let before = rendered.string
    // Simulate native typing inheriting a block boundary on a new paragraph.
    let inherited = typography.paragraphStyle(for: .body, previous: .heading1)
    rendered.addAttribute(.paragraphStyle, value: inherited, range: NSRange(location: 0, length: rendered.length))
    BlockTextStorage.updateParagraphRhythm(rendered, typography: typography)
    #expect(rendered.string == before)
    #expect(BlockTextStorage.capture(rendered, previous: document) == document)
    let continuation = try #require(rendered.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle)
    #expect(continuation.paragraphSpacingBefore == 0)
    #expect(continuation.paragraphSpacing == 0)
    let emptyRange = try #require(BlockTextStorage.ranges(rendered).first { $0.0 == document.blocks[3].id }?.1)
    #expect(emptyRange.length == 1) // An empty block retains a real native caret line.
}
