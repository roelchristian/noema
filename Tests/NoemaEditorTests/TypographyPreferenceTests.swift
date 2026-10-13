import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

@Suite("UI.TYP06 document typography preferences", .serialized)
@MainActor struct TypographyPreferenceTests {
    @Test func missingFamilyKeepsSavedChoiceAndValidatesSizesWithoutRewriting() throws {
        let suite = "NoemaPreferenceTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let missing = "Unavailable UI.TYP06 Family " + UUID().uuidString
        defaults.set(missing, forKey: EditorPreferences.fontFamilyKey)
        for (saved, expected) in [(15.0, 15.0), (5, 10), (80, 32), (.infinity, 16)] {
            defaults.set(saved, forKey: EditorPreferences.fontSizeKey)
            let typography = EditorTypography.load(defaults: defaults)
            #expect(!typography.isFamilyAvailable)
            #expect(typography.family == missing)
            #expect(typography.size == expected)
            #expect(typography.font(for: .body) == NSFont.systemFont(ofSize: expected))
            #expect(defaults.string(forKey: EditorPreferences.fontFamilyKey) == missing)
            #expect(defaults.double(forKey: EditorPreferences.fontSizeKey) == saved)
        }
        #expect(EditorTypography().isFamilyAvailable)
        let available = try #require(NSFontManager.shared.availableFontFamilies.first {
            EditorTypography(family: $0).isFamilyAvailable
        })
        #expect(EditorTypography(family: available).isFamilyAvailable)
    }

    @Test func presentationRefreshPreservesNativeSelectionViewportAndContent() throws {
        let source = (0..<80).map { "Paragraph \($0) contains several words for a long reading fixture." }.joined(separator: "\n\n")
        let (coordinator, view, scroll, window) = fixture(source)
        defer { window.close() }
        let before = coordinator.document
        let serialized = BlockDocumentCodec.encode(before)
        let text = view.string
        view.setSelectedRanges([
            NSValue(range: NSRange(location: 5, length: 18)),
            NSValue(range: NSRange(location: 120, length: 8))
        ], affinity: .upstream, stillSelecting: false)
        let selections = view.selectedRanges
        let affinity = view.selectionAffinity
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
        view.sizeToFit()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 160))
        let origin = scroll.contentView.bounds.origin
        for typography in [EditorTypography(family: "Helvetica", size: 32), EditorTypography(size: 10), EditorTypography(family: "Unavailable UI.TYP06", size: 16)] {
            coordinator.refreshPresentation(typography: typography)
            #expect(view.string == text)
            #expect(view.selectedRanges == selections)
            #expect(view.selectionAffinity == affinity)
            #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 0.5)
            #expect(coordinator.document == before)
            #expect(BlockDocumentCodec.encode(BlockTextStorage.capture(try #require(view.textStorage), previous: before)) == serialized)
            let font = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(abs(font.pointSize - CGFloat(typography.size)) < 0.001)
        }
        // A selection ending at the final storage character must not lose its
        // last character through the old render path's caret-only clamping.
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        let fullSelection = view.selectedRange()
        coordinator.refreshPresentation(typography: EditorTypography(size: 19))
        #expect(view.selectedRange() == fullSelection)
    }

    @Test func fontChangePreservesNativeUndoRedoAndSubsequentEditing() throws {
        let (coordinator, view, _, window) = fixture("Original document")
        defer { window.close() }
        let original = coordinator.document
        let originalText = view.string
        let undo = try #require(view.undoManager)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        undo.beginUndoGrouping()
        view.insertText("new ", replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        let edited = coordinator.document
        let editedText = view.string
        #expect(edited != original)
        let selection = NSRange(location: 4, length: 9)
        view.setSelectedRange(selection)
        let name = undo.undoActionName
        coordinator.refreshPresentation(typography: EditorTypography(family: "Helvetica", size: 23))
        #expect(view.selectedRange() == selection)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == name)
        #expect(coordinator.document == edited)
        undo.undo()
        #expect(view.string == originalText)
        #expect(normalizingModificationDates(coordinator.document, to: original) == original)
        try expectBodyFonts(view, size: 23)
        #expect(undo.canRedo)
        coordinator.refreshPresentation(typography: EditorTypography(size: 20))
        #expect(undo.canRedo)
        undo.redo()
        #expect(view.string == editedText)
        #expect(normalizingModificationDates(coordinator.document, to: edited) == edited)
        try expectBodyFonts(view, size: 20)
        coordinator.refreshPresentation(typography: EditorTypography(size: 20))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        undo.beginUndoGrouping()
        view.insertText("Next ", replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        #expect(coordinator.document.blocks.first?.text.hasPrefix("Next ") == true)
        #expect((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 20)
        undo.undo()
        #expect(normalizingModificationDates(coordinator.document, to: edited) == edited)
    }

    private func expectBodyFonts(_ view: ArticleTextView, size: CGFloat) throws {
        let storage = try #require(view.textStorage)
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            #expect((value as? NSFont)?.pointSize == size)
        }
    }

    /// Native undo is a real content edit and legitimately advances modifiedAt.
    /// Every other field, including IDs, runs, styles and metadata, must match.
    private func normalizingModificationDates(_ value: BlockDocument, to expected: BlockDocument) -> BlockDocument {
        var value = value
        func normalize(_ blocks: inout [EditorBlock], expected: [EditorBlock]) {
            for index in blocks.indices {
                guard let match = expected.first(where: { $0.id == blocks[index].id }) else { continue }
                blocks[index].modifiedAt = match.modifiedAt
                normalize(&blocks[index].children, expected: match.children)
            }
        }
        normalize(&value.blocks, expected: expected.blocks)
        return value
    }

    private func fixture(_ source: String) -> (RichArticleView.Coordinator, ArticleTextView, NSScrollView, NSWindow) {
        _ = NSApplication.shared
        let parent = RichArticleView(text: .constant(source), editable: true, locked: false,
            action: nil, onWikiLink: { _ in })
        let coordinator = parent.makeCoordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 740, height: 440))
        scroll.hasVerticalScroller = true
        let view = ArticleTextView(frame: scroll.bounds)
        view.isEditable = true; view.allowsUndo = true; view.isRichText = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(view)
        view.undoManager?.groupsByEvent = false
        view.delegate = coordinator
        coordinator.view = view
        coordinator.load(source)
        return (coordinator, view, scroll, window)
    }
}
