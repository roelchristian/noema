import AppKit
import Testing
import VaultCore
@testable import noema

@Test func readingMeasureCentersAndAdaptsToSplitPanes() {
    for width in [CGFloat(0), 80, 160, 240, 320, 500, 800, 832, 1000, 1600] {
        let geometry = ReadingGeometry(availableWidth: width, reservesEditorGutter: true)
        #expect(geometry.contentWidth <= 680)
        #expect(geometry.contentWidth >= 0)
        #expect(geometry.horizontalInset >= 0)
        #expect(geometry.contentWidth + 2 * geometry.horizontalInset == width)
        if width >= 800 {
            #expect(geometry.contentWidth == 680)
        } else if width >= 240 {
            #expect(geometry.contentWidth == width - 120)
            #expect(geometry.horizontalInset == 60)
            #expect(max(30, geometry.horizontalInset - 46) > 29) // Semantic icon clears drag controls.
        } else {
            #expect(geometry.contentWidth >= width / 2)
        }
    }
    #expect(ReadingGeometry(availableWidth: 500).contentWidth == 452)
    #expect(ReadingGeometry(availableWidth: .nan).contentWidth == 0)
    #expect(ReadingGeometry(availableWidth: -100).contentWidth == 0)
}

@Test @MainActor func articleMeasureReflowsWithoutChangingSelectionOrContent() throws {
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.textContainer?.widthTracksTextView = true
    view.textContainerInset = NSSize(width: 0, height: 24)
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun(String(repeating: "Readable prose reflows around the available width. ", count: 30))])])
    let rendered = BlockTextStorage.render(document, theme: NoemaTheme(), typography: EditorTypography(size: 16))
    view.textStorage?.setAttributedString(rendered)
    let selected = NSRange(location: 10, length: 17)
    view.setSelectedRange(selected)
    let container = try #require(view.textContainer)
    let manager = try #require(view.layoutManager)
    var heights: [CGFloat] = []

    // Inspector/sidebar changes only alter the width proposal, never the storage.
    for width in [CGFloat(1000), 500, 320, 1200] {
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        manager.ensureLayout(for: container)
        let geometry = ReadingGeometry(availableWidth: width, reservesEditorGutter: true, maximumContentWidth: view.typography.readingMeasureWidth)
        #expect(abs(container.size.width - geometry.contentWidth) < 0.01)
        // AppKit rounds the text origin to a native point when a centered inset is fractional.
        #expect(abs(view.textContainerOrigin.x - geometry.horizontalInset) <= 0.5)
        #expect(abs(view.textContainerInset.height - 24) < 0.001)
        #expect(view.selectedRange() == selected)
        #expect(view.textStorage?.string == rendered.string)
        let glyphs = manager.glyphRange(for: container)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            #expect(used.minX >= -0.01)
            #expect(used.maxX <= geometry.contentWidth + 0.01)
        }
        heights.append(manager.usedRect(for: container).height)
    }
    #expect(heights[1] > heights[0])
    #expect(heights[2] > heights[1])
    #expect(abs(heights[3] - heights[0]) < 0.01)
    #expect(BlockTextStorage.capture(try #require(view.textStorage), previous: document) == document)
}

@Test @MainActor func geometryResizingPreservesSemanticHeadingTopInset() {
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view.textContainerInset.height = 24
    var metadata = BlockMetadata(); metadata.semantic = "idea"
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("Semantic content")], metadata: metadata)])
    view.textStorage?.setAttributedString(BlockTextStorage.render(document, theme: NoemaTheme(), showSemanticHeadings: true))
    view.showSemanticHeadings = true
    view.updateSemanticHeadingTopInset()
    let height = view.textContainerInset.height
    #expect(height > 24)
    view.setFrameSize(NSSize(width: 400, height: 600))
    #expect(view.textContainerInset.height == height)
    view.showSemanticHeadings = false
    view.updateSemanticHeadingTopInset()
    #expect(abs(view.textContainerInset.height - 24) < 0.001)
}
