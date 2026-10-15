import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

@Suite(.serialized) @MainActor struct InlineMathRuntimeTests {
    private func equation(_ source: String, text: String) -> RichRun {
        var style = InlineStyle(); style.math = true; style.rawMath = source
        return RichRun(text, style: style)
    }

    private func fixture(_ document: BlockDocument) -> (RichArticleView.Coordinator, ArticleTextView, NSWindow) {
        _ = NSApplication.shared
        let parent = RichArticleView(document: .constant(document), editable: true, locked: false,
            action: nil, onWikiLink: { _ in })
        let coordinator = parent.makeCoordinator()
        let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        view.isEditable = true; view.isSelectable = true; view.isRichText = true; view.allowsUndo = true
        view.textContainerInset = NSSize(width: 20, height: 20)
        view.textContainer?.containerSize = NSSize(width: 640, height: 10000)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.orderFront(nil); window.makeFirstResponder(view)
        view.undoManager?.groupsByEvent = false
        coordinator.view = view; view.delegate = coordinator; coordinator.load(document)
        return (coordinator, view, window)
    }

    private func retire(_ coordinator: RichArticleView.Coordinator, _ view: ArticleTextView, _ window: NSWindow) {
        view.inlineMathProjection?.invalidate(); coordinator.invalidatePublication()
        view.delegate = nil; window.close(); MathTypesetter.shared.removeAllCachedResults()
    }

    private func rendered(_ view: ArticleTextView, count: Int) async throws -> MathLayoutProjection {
        let projection = try #require(view.inlineMathProjection)
        for _ in 0..<300 {
            if projection.renderedRanges.count == count { return projection }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(projection.renderedRanges.count == count, "Offline inline typesetting did not finish within 15 seconds")
        return projection
    }

    @Test func separateAdjacentEquationsPreserveExactRichRunsAndGlyphGeometry() async throws {
        var run = equation(#"x^{2}"#, text: "x²")
        run.unknownFields["futureRun"] = .string("untouched")
        run.style.unknownFields["futureStyle"] = .string("kept")
        run.style.highlight = true
        let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("Before "), run, run, RichRun(" after.")])])
        let (coordinator, view, window) = fixture(document)
        defer { retire(coordinator, view, window) }
        let original = view.string
        let projection = try await rendered(view, count: 2)
        let ranges = projection.renderedRanges
        #expect(ranges == [NSRange(location: 7, length: 2), NSRange(location: 9, length: 2)])
        let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let first = try #require(projection.presentationRect(at: 7))
        let second = try #require(projection.presentationRect(at: 9))
        #expect(first.width > 1 && first.height > 1)
        #expect(abs(second.minX - first.maxX) < 2)
        #expect(abs(second.minY - first.minY) < 1)
        for range in ranges {
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            #expect(layout.propertyForGlyph(at: glyph).contains(.controlCharacter))
            #expect(layout.propertyForGlyph(at: glyph + 1).contains(.null))
        }
        let storage = try #require(view.textStorage)
        #expect(BlockTextStorage.capture(storage, previous: document) == document)
        #expect(view.string == original)
        view.setSelectedRange(NSRange(location: 4, length: 10))
        coordinator.capture()
        #expect(coordinator.document == document)
        #expect(view.selectedRange() == NSRange(location: 4, length: 10))
    }

    @Test func tallFractionReservesLineHeightAndKeepsSentenceBaseline() async throws {
        let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("A "),
            equation(#"\frac{\sum_{i=1}^{n} i}{\sqrt{x^{2}+1}}"#, text: "fraction"), RichRun(" follows.\nNext line.")])])
        let (coordinator, view, window) = fixture(document)
        defer { retire(coordinator, view, window) }
        let projection = try await rendered(view, count: 1)
        let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let image = try #require(projection.presentationRect(at: 2))
        let glyph = layout.glyphIndexForCharacter(at: 2)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let sourceBaseline = line.minY + layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: 0)).y
        let mathBaseline = line.minY + layout.location(forGlyphAt: glyph).y
        #expect(abs(sourceBaseline - mathBaseline) < 1)
        #expect(image.minY >= line.minY + view.textContainerOrigin.y - 1)
        #expect(image.maxY <= line.maxY + view.textContainerOrigin.y + 1)
        let next = (view.string as NSString).range(of: "Next line.").location
        let nextLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: next), effectiveRange: nil)
        #expect(nextLine.minY >= image.maxY - view.textContainerOrigin.y)
    }

    @Test func sourcePopoverCommitsUndoAndCancelsEscape() async throws {
        let run = equation(#"x^{2}"#, text: "x²")
        let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("A "), run, RichRun(" end")])])
        let (coordinator, view, window) = fixture(document)
        defer { retire(coordinator, view, window) }
        let projection = try await rendered(view, count: 1)
        let frame = try #require(projection.presentationRect(at: 2))
        #expect(projection.activate(at: NSPoint(x: frame.midX, y: frame.midY)))
        let editor = try #require(projection.sourceEditingView)
        #expect(editor.string == #"x^{2}"#)
        editor.string = #"\frac{a}{b}"#
        #expect(projection.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        for _ in 0..<40 where projection.sourceEditingView != nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(coordinator.document.blocks[0].runs[1].style.rawMath == #"\frac{a}{b}"#)
        #expect(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        #expect(coordinator.document == document)
        coordinator.refreshMathPresentation()
        let restored = try await rendered(view, count: 1)
        let restoredFrame = try #require(restored.presentationRect(at: 2))
        #expect(restored.activate(at: NSPoint(x: restoredFrame.midX, y: restoredFrame.midY)))
        let cancelled = try #require(restored.sourceEditingView)
        cancelled.string = "changed"
        #expect(restored.textView(cancelled, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        for _ in 0..<40 where restored.sourceEditingView != nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(coordinator.document == document)
    }

    @Test func stalePopoverRevisionCannotChangeAnotherEquationAndLockClearsGlyphs() async throws {
        let run = equation("x^2", text: "x²")
        let document = BlockDocument(blocks: [EditorBlock(runs: [run, run])])
        let (coordinator, view, window) = fixture(document)
        defer { retire(coordinator, view, window) }
        let projection = try await rendered(view, count: 2)
        let frame = try #require(projection.presentationRect(at: 0))
        #expect(projection.activate(at: NSPoint(x: frame.midX, y: frame.midY)))
        let editor = try #require(projection.sourceEditingView)
        editor.string = "stale"
        coordinator.transaction("Change document while source editor is open") {
            coordinator.document.update(document.blocks[0].id) { $0.runs.append(RichRun(" elsewhere")) }
            return nil
        }
        let changed = coordinator.document
        #expect(projection.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        for _ in 0..<40 where projection.sourceEditingView != nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(coordinator.document == changed)
        view.locked = true
        projection.refresh()
        #expect(projection.renderedRanges.isEmpty)
        let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: 0)
        #expect(!layout.propertyForGlyph(at: glyph).contains(.controlCharacter))
        #expect(!projection.activate(at: NSPoint(x: frame.midX, y: frame.midY)))
    }
}
