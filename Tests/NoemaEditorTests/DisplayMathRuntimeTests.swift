import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

/// Uses an in-memory document and a hosted native editor; never opens a vault.
@Suite(.serialized) @MainActor struct DisplayMathRuntimeTests {
    private let projectionAttribute = NSAttributedString.Key("noema.displayMathOriginalPresentation")

    private func editor(_ source: String) -> (RichArticleView.Coordinator, ArticleTextView, NSWindow) {
        _ = NSApplication.shared
        let document = BlockDocument(blocks: [
            EditorBlock(kind: .math, runs: [RichRun(source)]),
            EditorBlock(runs: [RichRun("Following prose")])
        ])
        let parent = RichArticleView(document: .constant(document), editable: true,
            locked: false, action: nil, onWikiLink: { _ in })
        let coordinator = parent.makeCoordinator()
        let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.isEditable = true; view.isRichText = true; view.allowsUndo = true
        view.drawsBackground = true; view.backgroundColor = .white
        view.appearance = NSAppearance(named: .aqua)
        view.textContainerInset = NSSize(width: 0, height: 24)
        view.updateReadingGeometry()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = view
        window.contentView = scroll
        view.delegate = coordinator; coordinator.view = view
        coordinator.load(document)
        window.makeFirstResponder(nil)
        view.undoManager?.groupsByEvent = false
        view.undoManager?.removeAllActions()
        coordinator.refreshMathPresentation()
        return (coordinator, view, window)
    }

    private func waitForReading(_ view: ArticleTextView) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            if let font = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
               font.pointSize < 1 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The local typesetter did not produce a display-math reading projection within 20 seconds")
    }

    private func capture(_ view: ArticleTextView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["NOEMA_MATH_CAPTURE_DIR"] else { return }
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.displayIfNeeded()
        let rectangle = NSIntersectionRect(view.bounds, NSRect(x: 0, y: 0, width: 900, height: 600))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rectangle))
        view.cacheDisplay(in: rectangle, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try png.write(to: destination.appendingPathComponent(name + ".png"), options: .atomic)
    }

    @Test func multilineReadingReservesImageHeightWithoutChangingSourceOrUndo() async throws {
        let source = "\\begin{aligned}\n\\frac{1}{2}&=a\\\\\n\\sum_{n=1}^{N}n&=b\n\\end{aligned}"
        let (coordinator, view, window) = editor(source)
        defer {
            view.invalidateDisplayMathPresentation(); view.inlineMathProjection?.invalidate()
            MathTypesetter.shared.removeAllCachedResults(); window.close()
        }
        let original = coordinator.document
        let text = view.string
        try await waitForReading(view)
        let storage = try #require(view.textStorage)
        let ranges = BlockTextStorage.ranges(storage)
        let range = try #require(ranges.first?.1)
        let projected = try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(projected.pointSize < 1)
        #expect(storage.attribute(projectionAttribute, at: range.location, effectiveRange: nil) != nil)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let equation = view.rect(for: range)
        let following = view.rect(for: ranges[1].1)
        #expect(equation.width > 10 && equation.height > 20)
        #expect(following.minY >= equation.maxY)
        try capture(view, name: "display-math-multiline-reading")
        let firstParagraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
        let continuation = try #require(storage.attribute(.paragraphStyle, at: NSMaxRange(firstParagraph), effectiveRange: nil) as? NSParagraphStyle)
        #expect(continuation.maximumLineHeight <= 0.01)
        for _ in 0..<3 { coordinator.refreshMathPresentation() }
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        #expect(abs(view.rect(for: range).height - equation.height) < 0.5)
        #expect(view.string == text)
        #expect(coordinator.document == original)
        #expect(BlockTextStorage.capture(storage, previous: original) == original)
        #expect(view.undoManager?.canUndo == false)
        view.invalidateDisplayMathPresentation()
        let restored = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(restored.pointSize > 1)
        #expect(storage.attribute(projectionAttribute, at: 0, effectiveRange: nil) == nil)
        #expect(view.string == text)
    }

    @Test func clickFocusSelectionAndNativeUndoPreserveAuthoritativeTeX() async throws {
        let source = #"\frac{1}{2}+x^2"#
        let (coordinator, view, window) = editor(source)
        defer {
            view.invalidateDisplayMathPresentation(); view.inlineMathProjection?.invalidate()
            MathTypesetter.shared.removeAllCachedResults(); window.close()
        }
        let original = coordinator.document
        try await waitForReading(view)
        let range = try #require(BlockTextStorage.ranges(view.textStorage!).first?.1)
        let equation = view.rect(for: range)
        let windowPoint = view.convert(NSPoint(x: equation.midX, y: equation.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        #expect(window.firstResponder === view)
        #expect(view.selectedRange() == NSRange(location: range.location, length: 0))
        let sourceFont = try #require(view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(sourceFont.pointSize > 1)
        try capture(view, name: "display-math-source-editing")
        view.setSelectedRange(NSRange(location: range.location, length: source.utf16.count))
        coordinator.refreshMathPresentation()
        let selectedFont = try #require(view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(selectedFont.pointSize > 1)
        #expect(coordinator.document == original)
        view.undoManager?.beginUndoGrouping()
        view.insertText("y+1", replacementRange: view.selectedRange())
        view.undoManager?.endUndoGrouping()
        #expect(coordinator.document.blocks[0].text == "y+1")
        #expect(coordinator.document.blocks[0].id == original.blocks[0].id)
        #expect(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        let afterUndo = coordinator.document
        // Native undo replays the source edit through EditorSession.updateRuns;
        // BlockDocument.update advances that block's modification timestamp.
        // Require every other document field, including IDs and rich runs, to
        // match exactly rather than treating undo as a historical timestamp restore.
        var expectedAfterUndo = original
        expectedAfterUndo.blocks[0].modifiedAt = afterUndo.blocks[0].modifiedAt
        #expect(afterUndo == expectedAfterUndo)
        #expect(afterUndo.blocks[0].modifiedAt >= original.blocks[0].modifiedAt)
        #expect(view.string.hasPrefix(source + "\n"))
        window.makeFirstResponder(nil)
        coordinator.refreshMathPresentation()
        try await waitForReading(view)
        #expect(coordinator.document == afterUndo)
        #expect(BlockTextStorage.capture(view.textStorage!, previous: afterUndo) == afterUndo)
    }
    @Test func repeatedNativeSourceTypingDoesNotAccumulatePreviewSpacing() async throws {
        let (coordinator, view, window) = editor("x+1")
        defer {
            view.invalidateDisplayMathPresentation(); view.inlineMathProjection?.invalidate()
            MathTypesetter.shared.removeAllCachedResults(); window.close()
        }
        try await waitForReading(view)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.refreshMathPresentation()
        let initial = try #require(view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(initial.paragraphSpacing > 8)
        for replacement in ["x+2", "x+3", "x+4"] {
            let range = try #require(BlockTextStorage.ranges(view.textStorage!).first?.1)
            view.setSelectedRange(NSRange(location: range.location, length: range.length - 1))
            view.undoManager?.beginUndoGrouping()
            view.insertText(replacement, replacementRange: view.selectedRange())
            view.undoManager?.endUndoGrouping()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(20))
            while view.textStorage?.attribute(projectionAttribute, at: 0, effectiveRange: nil) == nil, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(view.textStorage?.attribute(projectionAttribute, at: 0, effectiveRange: nil) != nil)
            let projected = try #require(view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            // These one-line expressions have the same typeset height. Their
            // previews must reserve one image, rather than each prior image.
            #expect(abs(projected.paragraphSpacing - initial.paragraphSpacing) < 3)
            #expect(coordinator.document.blocks[0].text == replacement)
        }
    }

}
