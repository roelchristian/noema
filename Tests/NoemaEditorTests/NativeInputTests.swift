import SwiftUI
import AppKit
import Testing
import VaultCore
@testable import noema

@MainActor private func nativeInputView(_ source: String) -> ArticleTextView {
    _ = NSApplication.shared
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.isEditable = true
    view.isSelectable = true
    view.textStorage?.setAttributedString(BlockTextStorage.render(BlockDocumentCodec.decode(source), theme: NoemaTheme()))
    return view
}

@Test @MainActor func nativeInputSelectionDistinguishesReadingAndBlockEditing() {
    let view = nativeInputView("First\n\nSecond")
    let range = BlockTextStorage.ranges(view.textStorage!)[0].1
    view.setSelectedRange(NSRange(location: 2, length: 0))
    view.selectAll(nil)
    #expect(view.selectedRange() == NSRange(location: range.location, length: range.length - 1))
    view.selectEntireDocument(nil)
    #expect(view.selectedRange() == NSRange(location: 0, length: view.string.utf16.count))
    view.isEditable = false
    view.selectAll(nil)
    #expect(view.selectedRange() == NSRange(location: 0, length: view.string.utf16.count))
}

@Test @MainActor func nativeInputExplicitEditingPreservesPartialSelectionAndHonoursLock() {
    let view = nativeInputView("Selectable article")
    view.isEditable = false
    let selection = NSRange(location: 2, length: 5)
    view.setSelectedRange(selection)
    var starts = 0
    view.begin = { starts += 1 }
    view.beginEditingArticle(nil)
    #expect(view.isEditable)
    #expect(view.selectedRange() == selection)
    #expect(starts == 1)
    view.isEditable = false
    view.locked = true
    view.beginEditingArticle(nil)
    #expect(!view.isEditable)
    #expect(starts == 1)
}

@Test @MainActor func nativeInputMarkedTextCommitsCJKWithoutDroppingSurroundingText() {
    let view = nativeInputView("prefix suffix")
    view.setSelectedRange(NSRange(location: 7, length: 0))
    view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.hasMarkedText())
    view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!view.hasMarkedText())
    #expect(view.string == "prefix 日本語suffix\n")
    #expect(view.selectedRange() == NSRange(location: 10, length: 0))
}

@Test @MainActor func nativeInputPartialUTF16ReplacementPreservesAccentsAndEmoji() {
    let view = nativeInputView("a👩🏽‍💻 café z")
    let range = (view.string as NSString).range(of: "café")
    view.setSelectedRange(range)
    view.insertText("日本 e\u{301} 😀", replacementRange: range)
    #expect(view.string == "a👩🏽‍💻 日本 e\u{301} 😀 z\n")
    #expect(view.selectedRange().location == range.location + "日本 e\u{301} 😀".utf16.count)
    #expect(view.selectedRange().length == 0)
}


@MainActor private func nativeSessionEditor(_ source: String) -> (RichArticleView.Coordinator, ArticleTextView, NSWindow) {
    _ = NSApplication.shared
    var body = source
    let parent = RichArticleView(text: Binding(get: { body }, set: { body = $0 }), reading: false, locked: false, action: nil,
        onBegin: {}, onEnd: {}, onWikiLink: { _ in })
    let coordinator = parent.makeCoordinator()
    let view = nativeInputView(source)
    view.allowsUndo = true; view.isRichText = true
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view; window.makeFirstResponder(view)
    view.undoManager?.groupsByEvent = false
    view.delegate = coordinator; coordinator.view = view; coordinator.load(source)
    return (coordinator, view, window)
}

@Test @MainActor func nativeInputCompositionFlushPreservesCandidateAndCommit() {
    let (coordinator, view, window) = nativeSessionEditor("prefix suffix")
    defer { coordinator.invalidatePublication(); window.close() }
    let originalID = coordinator.document.blocks[0].id
    view.setSelectedRange(NSRange(location: 7, length: 0))
    view.undoManager?.beginUndoGrouping()
    view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.hasMarkedText())
    coordinator.flushPublication()
    #expect(coordinator.document.blocks[0].text == "prefix 日本suffix")
    #expect(view.hasMarkedText())
    view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
    view.undoManager?.endUndoGrouping()
    #expect(coordinator.document.blocks[0].text == "prefix 日本語suffix")
    #expect(coordinator.document.blocks[0].id == originalID)
    #expect(view.selectedRange() == NSRange(location: 10, length: 0))
    #expect(!view.hasMarkedText())
}

@Test @MainActor func nativeInputCrossBlockReplacementRestoresDocumentAndSelection() {
    let (coordinator, view, window) = nativeSessionEditor("First\nSecond\n    - Child remains\nLast")
    defer { coordinator.invalidatePublication(); window.close() }
    let original = coordinator.document
    let ranges = BlockTextStorage.ranges(view.textStorage!)
    let selection = NSRange(location: 2, length: ranges[1].1.location + 3 - 2)
    view.setSelectedRange(selection)
    view.insertText("😀 e\u{301}", replacementRange: selection)
    #expect(coordinator.document.blocks[0].text == "Fi😀 e\u{301}ond")
    #expect(coordinator.document.flattened.contains { $0.text == "Child remains" })
    #expect(coordinator.document.blocks[0].id == original.blocks[0].id)
    #expect(view.selectedRange().location == 2 + "😀 e\u{301}".utf16.count)
    view.undoManager?.undo()
    #expect(coordinator.document == original)
    #expect(view.selectedRange() == selection)
    view.undoManager?.redo()
    #expect(coordinator.document.blocks[0].text == "Fi😀 e\u{301}ond")
}

@Test @MainActor func nativeInputCrossBlockPlainClipboardPreservesSuffixAndUndo() {
    let (coordinator, view, window) = nativeSessionEditor("First\nSecond\n    - Child remains\nLast")
    defer { coordinator.invalidatePublication(); window.close() }
    let original = coordinator.document
    let ranges = BlockTextStorage.ranges(view.textStorage!)
    let selection = NSRange(location: 2, length: ranges[1].1.location + 3 - 2)
    view.setSelectedRange(selection)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("日本 e\u{301} 😀", forType: .string)
    coordinator.paste(pasteboard)
    #expect(coordinator.document.blocks[0].text == "Fi日本 e\u{301} 😀ond")
    #expect(coordinator.document.flattened.contains { $0.text == "Child remains" })
    #expect(view.selectedRange().location == 2 + "日本 e\u{301} 😀".utf16.count)
    view.undoManager?.undo()
    #expect(coordinator.document == original)
    #expect(view.selectedRange() == selection)
}


@Test @MainActor func nativeInputCommandAUsesBlockAndExplicitDocumentSelection() throws {
    let (coordinator, view, window) = nativeSessionEditor("First\nSecond")
    defer { coordinator.invalidatePublication(); window.close() }
    view.setSelectedRange(NSRange(location: 2, length: 1))
    let block = BlockTextStorage.ranges(view.textStorage!)[0].1
    let blockEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    #expect(coordinator.handleKey(blockEvent))
    #expect(view.selectedRange() == NSRange(location: block.location, length: block.length - 1))
    let documentEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.command, .option], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    #expect(coordinator.handleKey(documentEvent))
    #expect(view.selectedRange() == NSRange(location: 0, length: view.string.utf16.count))
}


@Test @MainActor func nativeInputCompositionReplacingAcrossBlocksKeepsSurvivingContent() {
    let (coordinator, view, window) = nativeSessionEditor("First\nSecond\nLast")
    defer { coordinator.invalidatePublication(); window.close() }
    let originalID = coordinator.document.blocks[0].id
    let lastID = coordinator.document.blocks[2].id
    let ranges = BlockTextStorage.ranges(view.textStorage!)
    let selection = NSRange(location: 2, length: ranges[1].1.location + 3 - 2)
    view.setSelectedRange(selection)
    view.undoManager?.beginUndoGrouping()
    view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: selection)
    #expect(view.hasMarkedText())
    view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
    view.undoManager?.endUndoGrouping()
    #expect(!view.hasMarkedText())
    #expect(view.string == "Fi日本語ond\nLast\n")
    #expect(coordinator.document.blocks.first?.id == originalID)
    #expect(coordinator.document.block(lastID)?.text == "Last")
    #expect(coordinator.document.flattened.map(\.text).joined() == "Fi日本語ondLast")
    #expect(BlockDocumentCodec.valid(coordinator.document))
}
