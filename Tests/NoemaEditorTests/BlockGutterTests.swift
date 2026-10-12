import AppKit
import Testing
import VaultCore
@testable import noema

@MainActor private func gutterFixture() -> (ArticleTextView, BlockDocument, NSWindow) {
    let child = EditorBlock(runs: [RichRun("Nested paragraph")])
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("First paragraph")], children: [child]),
                                          EditorBlock(runs: [RichRun("Last paragraph")])])
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    view.isEditable = true
    view.textContainer?.widthTracksTextView = true
    view.textContainerInset.height = 24
    view.updateReadingGeometry()
    view.textStorage?.setAttributedString(BlockTextStorage.render(document, theme: NoemaTheme()))
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    return (view, document, window)
}

@Test @MainActor func gutterFollowsContentOriginIndentAndFontBaseline() throws {
    let (view, document, window) = gutterFixture()
    _ = window
    for size in [CGFloat(13), 20, 28] {
        view.typography = EditorTypography(size: size)
        view.textStorage?.setAttributedString(BlockTextStorage.render(document, theme: NoemaTheme(), typography: view.typography))
        for width in [CGFloat(1000), 500, 320, 1200] {
            view.setFrameSize(NSSize(width: width, height: 600))
            let container = try #require(view.textContainer)
            let manager = try #require(view.layoutManager)
            manager.ensureLayout(for: container)
            let ranges = BlockTextStorage.ranges(try #require(view.textStorage))
            for (_, range) in ranges {
                let depth = view.textStorage?.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
                let handle = view.gutterRect(for: range)
                #expect(handle.minX == max(0, view.textContainerOrigin.x - 72 + CGFloat(depth * 24)))
                #expect(handle.minY == view.firstBaseline(for: range) - 17)
                if let semantic = view.semanticSymbolRect(for: range, depth: depth, heading: nil) {
                    #expect(handle.maxX <= semantic.minX)
                }
            }
        }
    }
}

@Test @MainActor func gutterSelectionDoesNotMoveNativeCaretAndPreservesDragGroup() throws {
    let (view, _, window) = gutterFixture()
    view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
    let ranges = BlockTextStorage.ranges(try #require(view.textStorage))
    let (first, range) = try #require(ranges.first)
    let caret = NSRange(location: 5, length: 4)
    view.setSelectedRange(caret)
    var selected: [UUID] = []
    view.selectBlock = { id, _ in selected.append(id) }
    let handle = view.gutterRect(for: range)
    let location = view.convert(NSPoint(x: handle.midX, y: handle.midY), to: nil)
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    view.mouseDown(with: down)
    #expect(selected == [first])
    #expect(view.selectedRange() == caret)
    view.mouseUp(with: down)
    view.selectedBlockIDs = Set(ranges.map(\.0))
    view.mouseDown(with: down)
    #expect(selected == [first])
    #expect(view.selectedRange() == caret)
    view.mouseUp(with: down)
}

@Test @MainActor func focusRedrawToleratesStaleBlockRangesDuringStorageReplacement() throws {
    let (view, _, window) = gutterFixture()
    _ = window
    view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
    let storage = try #require(view.textStorage)
    view.blockRangeIndex = BlockTextStorage.RangeIndex(storage)
    view.setSelectedRange(NSRange(location: 5, length: 0))
    // AppKit adjusts the focus before the coordinator can rebuild the UUID index.
    storage.setAttributedString(NSAttributedString(string: "x\n"))
    view.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(view.rect(for: NSRange(location: 10, length: 20)) == .zero)
    #expect(view.rect(for: NSRange(location: 0, length: 20)).height >= 0)
}
