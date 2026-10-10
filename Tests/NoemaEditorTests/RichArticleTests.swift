import SwiftUI
import AppKit
import Testing
import VaultCore
@testable import noema

@Test func libraryPreviewPrefersPersistedAISummaryAndFallsBackToContent() throws {
    var note = try NoteCodec.decode(Data("# Opening\n\nFirst **content** line.\nSecond line.".utf8), path: "Wiki/Preview.md", vaultID: UUID())
    note.updatedAt = "2026-10-10T08:30:00Z"
    let fallback = LibraryRow(note: note)
    #expect(!fallback.hasAISummary)
    #expect(fallback.excerpt == "Opening First content line. Second line.")
    #expect(fallback.updatedAt != nil)
    var document = BlockDocumentCodec.decode(note.body)
    document.setAISummary("A generated synopsis.")
    note.body = BlockDocumentCodec.encode(document)
    let summary = LibraryRow(note: note)
    #expect(summary.hasAISummary)
    #expect(summary.excerpt == "A generated synopsis.")
    document.setAISummary("  ")
    note.body = BlockDocumentCodec.encode(document)
    note.updatedAt = ""
    let empty = LibraryRow(note: note)
    #expect(!empty.hasAISummary)
    #expect(empty.excerpt == fallback.excerpt)
    #expect(empty.updatedAt == nil)
}

@Test func slashCommandMatchingAndBoundaries() {
    #expect(BlockCommand.matching("h2").first?.id == "h2")
    #expect(BlockCommand.matching("ques").first?.id == "question")
    #expect(BlockCommand.matching("wrn").contains { $0.id == "warning" })
    #expect(BlockCommand.matching("zzzzzz").isEmpty)
    #expect(BlockCommand.all.filter { $0.semantic == nil }.count == 12)
    #expect(BlockCommand.all.filter { $0.semantic?.isEmpty == false }.count == 10)
    for source in ["/ques", "Some text /h2", "😀 /idea"] {
        let range = BlockCommand.slashRange(in: source, selection: NSRange(location: source.utf16.count, length: 0))
        #expect(range != nil); #expect((source as NSString).substring(with: range!).hasPrefix("/"))
    }
    for source in ["https://example.com", "word/ques", "/two words"] {
        #expect(BlockCommand.slashRange(in: source, selection: NSRange(location: source.utf16.count, length: 0)) == nil)
    }
    for prefix in ["# ", "## ", "### ", "- ", "* ", "1. ", "[] ", "[ ] ", "> ", "---", "```"] { #expect(BlockCommand.shortcut(prefix) != nil) }
}

@Test @MainActor func richTextRenderingRetainsFormattingAndCollapsedChildren() {
    var style = InlineStyle(); style.bold = true; style.italic = true; style.underline = true; style.strike = true; style.highlight = true; style.link = "https://example.com"
    var metadata = BlockMetadata(); metadata.semantic = "starred"; metadata.collapsed = true
    let block = EditorBlock(kind: .toggle, runs: [RichRun("Visible😀", style: style)], metadata: metadata, children: [EditorBlock(runs: [RichRun("Hidden")])])
    let document = BlockDocument(blocks: [block])
    for dark in [false, true] {
        let rich = BlockTextStorage.render(document, theme: NoemaTheme(dark: dark))
        #expect(rich.string == "Visible😀\n")
        #expect(BlockTextStorage.capture(rich, previous: document).blocks == document.blocks)
        #expect(rich.attribute(.semanticTag, at: 0, effectiveRange: nil) as? String == "starred")
        let paragraph = rich.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        #expect(paragraph.headIndent >= 24) // Leave room inside the margin for the toggle marker.
        #expect(paragraph.paragraphSpacingBefore > 0)
        #expect(paragraph.paragraphSpacing > 10)
    }
}

@Test @MainActor func semanticHeadingsReserveSpaceWithoutChangingContent() {
    let (coordinator, view, window) = editor("Initial")
    defer { window.close() }
    #expect(!view.showSemanticHeadings)
    for semantic in SemanticPresentation.all {
        for kind in [BlockKind.paragraph, .heading2, .bullet, .task, .toggle, .quote, .code] {
            var metadata = BlockMetadata(); metadata.semantic = semantic.id
            let block = EditorBlock(kind: kind, runs: [RichRun("First line\nSecond line😀")], metadata: metadata)
            let document = BlockDocument(blocks: [block, EditorBlock(runs: [RichRun("Following")])])
            coordinator.document = document
            for enabled in [false, true, false] {
                view.showSemanticHeadings = enabled
                let selection = NSRange(location: 3, length: 4)
                coordinator.render(selection: selection)
                view.layoutManager?.ensureLayout(for: view.textContainer!)
                let storage = view.textStorage!
                #expect(view.selectedRange() == selection)
                #expect(storage.string == "First line\nSecond line😀\nFollowing\n")
                #expect(BlockTextStorage.capture(storage, previous: document).blocks == document.blocks)
                let range = BlockTextStorage.ranges(storage)[0].1
                let heading = view.semanticHeadingRect(for: range)
                #expect((heading != nil) == enabled)
                if let heading {
                    #expect(heading.minY >= view.textContainerOrigin.y - view.semanticHeadingTopInset)
                    #expect(heading.maxY < view.rect(for: range).minY)
                    let native = view.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
                    let caret = view.convert(window.convertFromScreen(native), from: nil)
                    #expect(abs(heading.minX - caret.minX) < 0.01)
                }
                let first = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
                let second = storage.attribute(.paragraphStyle, at: 11, effectiveRange: nil) as! NSParagraphStyle
                #expect(first.paragraphSpacingBefore == 12 + (enabled ? BlockTextStorage.semanticHeadingSpace : 0))
                #expect(second.paragraphSpacingBefore == 12)
            }
        }
    }
}

@Test @MainActor func semanticHeadingsKeepEmptyCaretAndNativeEditingIntact() {
    let (coordinator, view, window) = editor("Initial")
    defer { window.close() }
    view.showSemanticHeadings = true
    var metadata = BlockMetadata(); metadata.semantic = "idea"
    for first in [true, false] {
        let empty = EditorBlock(metadata: metadata)
        coordinator.document = BlockDocument(blocks: first ? [empty] : [EditorBlock(runs: [RichRun("Previous")]), empty])
        coordinator.render(selection: NSRange(location: 0, length: 0))
        let range = BlockTextStorage.ranges(view.textStorage!).last!.1
        view.setSelectedRange(NSRange(location: range.location, length: 0))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let heading = view.semanticHeadingRect(for: range)!
        #expect(heading.minY >= view.textContainerOrigin.y - view.semanticHeadingTopInset)
        let before = view.rect(for: range)
        view.undoManager?.beginUndoGrouping()
        view.insertText("A", replacementRange: view.selectedRange())
        view.undoManager?.endUndoGrouping()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let after = view.rect(for: BlockTextStorage.ranges(view.textStorage!).last!.1)
        #expect(abs(before.minY - after.minY) < 0.5)
        #expect(coordinator.document.blocks.last?.text == "A")
        view.undoManager?.undo()
        #expect(coordinator.document.blocks.last?.text.isEmpty == true)
        view.undoManager?.removeAllActions()
    }
}

@Test @MainActor func blockSpacingAndNestedListAlignment() {
    for dark in [false, true] {
        let theme = NoemaTheme(dark: dark)
        let plain = BlockTextStorage.base(EditorBlock(), depth: 0, theme: theme)[.paragraphStyle] as! NSParagraphStyle
        for kind in [BlockKind.quote, .callout, .code] {
            let style = BlockTextStorage.base(EditorBlock(kind: kind), depth: 0, theme: theme)[.paragraphStyle] as! NSParagraphStyle
            #expect(style.paragraphSpacingBefore > plain.paragraphSpacingBefore)
            #expect(style.paragraphSpacing > plain.paragraphSpacing)
        }
        for kind in [BlockKind.bullet, .numbered, .task, .toggle] {
            let style = BlockTextStorage.base(EditorBlock(kind: kind), depth: 2, theme: theme)[.paragraphStyle] as! NSParagraphStyle
            #expect(style.firstLineHeadIndent == style.headIndent)
            #expect(style.headIndent >= 2 * 24 + 24) // Wrapped text clears its marker at every nesting depth.
        }
    }
}

@MainActor private func editor(_ source: String) -> (RichArticleView.Coordinator, ArticleTextView, NSWindow) {
    _ = NSApplication.shared
    let parent = RichArticleView(text: .constant(source), reading: false, locked: false, action: nil, onBegin: {}, onEnd: {}, onWikiLink: { _ in })
    let coordinator = parent.makeCoordinator()
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)); view.isEditable = true; view.allowsUndo = true; view.isRichText = true
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view; window.makeFirstResponder(view); view.undoManager?.groupsByEvent = false; view.delegate = coordinator; coordinator.view = view; coordinator.load(source)
    return (coordinator, view, window)
}

@Test @MainActor func slashPaletteUsesCompactSectionsAndSemanticSymbols() {
    let palette = BlockPalette(); palette.update(BlockCommand.matching(""))
    #expect(palette.preferredContentSize.width == 240)
    #expect(palette.preferredContentSize.height == 405)
    #expect(palette.stack.arrangedSubviews.compactMap { $0 as? NSBox }.count == 1)
    let headings = palette.stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(headings == ["Basic blocks", "Semantic blocks"])
    let buttons = palette.stack.arrangedSubviews.compactMap { $0 as? NSButton }
    #expect(buttons.count == BlockCommand.all.count)
    #expect(palette.stack.spacing == 0)
    #expect(buttons.allSatisfy { button in
        abs((button.constraints.first(where: { $0.firstAttribute == .height })?.constant ?? 0) - 24) < 0.01
    })
    #expect(buttons.first(where: { $0.title == "Idea" })?.image != nil)
    for width in [CGFloat(200), 236] {
        let bounds = NSRect(x: 0, y: 0, width: width, height: 24)
        let cells = buttons.compactMap { $0.cell as? NSButtonCell }
        let titles = cells.map { $0.titleRect(forBounds: bounds) }
        #expect(Set(titles.map(\.minX)).count == 1)
        for cell in cells {
            #expect(cell.titleRect(forBounds: bounds).minX - cell.imageRect(forBounds: bounds).maxX >= 8)
            #expect(bounds.contains(cell.titleRect(forBounds: bounds)))
        }
    }
    palette.move(12)
    #expect(palette.commands[palette.selected].id == "question")
    palette.update(BlockCommand.matching("ques"))
    #expect(palette.commands.first?.id == "question")
}

@Test @MainActor func slashPaletteAlwaysFitsAboveOrBelowCaret() {
    let available = NSRect(x: 100, y: 100, width: 500, height: 600)
    let desired = NSSize(width: 260, height: 480)
    for caretY in [CGFloat(120), 350, 650] {
        let caret = NSRect(x: 200, y: caretY, width: 1, height: 21)
        let frame = BlockSuggestionPanel.frame(caret: caret, available: available, desired: desired)
        #expect(available.contains(frame))
        #expect(frame.maxY <= caret.minY - 6 || frame.minY >= caret.maxY + 6)
        #expect(frame.minX == caret.minX)
        #expect(frame.height <= desired.height)
    }
    let nearBottom = BlockSuggestionPanel.frame(caret: NSRect(x: 590, y: 120, width: 1, height: 21), available: available, desired: desired)
    #expect(nearBottom.minY == 147)
    #expect(nearBottom.maxX == available.maxX)
    let nearTop = BlockSuggestionPanel.frame(caret: NSRect(x: 200, y: 650, width: 1, height: 21), available: available, desired: desired)
    #expect(nearTop.maxY == 644)
    let narrow = BlockSuggestionPanel.frame(caret: NSRect(x: 120, y: 300, width: 1, height: 21), available: NSRect(x: 100, y: 100, width: 200, height: 400), desired: desired)
    #expect(narrow.width == 200)
}

@Test @MainActor func articleClickStartsEditingAndLockedClickShowsHint() {
    let view = ArticleTextView(); view.isEditable = false
    var starts = 0, lockedNotices = 0
    view.begin = { starts += 1 }; view.lockedClick = { lockedNotices += 1 }
    view.requestEditingFromClick()
    #expect(view.isEditable); #expect(starts == 1)
    view.requestEditingFromClick()
    #expect(starts == 1)
    view.isEditable = false; view.locked = true
    view.requestEditingFromClick()
    #expect(!view.isEditable); #expect(starts == 1); #expect(lockedNotices == 1)
    view.locked = false; view.requestEditingFromClick()
    #expect(view.isEditable); #expect(starts == 2)
}

@Test @MainActor func semanticDecorationExcludesBlockTerminatorAfterSplit() {
    let (coordinator, view, window) = editor("Thought")
    defer { window.close() }
    coordinator.mutate(.semantic("idea"), name: "Idea")
    view.setSelectedRange(NSRange(location: 7, length: 0))
    coordinator.mutate(.split(7), name: "New block")
    #expect(coordinator.document.blocks.count == 2)
    #expect(coordinator.document.blocks[0].text == "Thought")
    #expect(coordinator.document.blocks[1].text.isEmpty)
    view.layoutManager?.ensureLayout(for: view.textContainer!)
    let range = BlockTextStorage.ranges(view.textStorage!)[0].1
    #expect(view.rect(for: range) == view.rect(for: NSRange(location: range.location, length: range.length - 1)))
    #expect(BlockTextStorage.capture(view.textStorage!, previous: coordinator.document).blocks == coordinator.document.blocks)
}

@Test @MainActor func editorCommandUndoRedoAndSlashQueryRemoval() {
    let (coordinator, view, window) = editor("Hello **bold** /h2")
    defer { window.close() }
    view.setSelectedRange(NSRange(location: view.string.utf16.count - 1, length: 0))
    coordinator.slashRange = BlockCommand.slashRange(in: view.string, selection: view.selectedRange())
    let original = coordinator.document
    coordinator.apply(BlockCommand.matching("h2")[0], removingQuery: true)
    #expect(coordinator.document.blocks[0].kind == .heading2)
    #expect(coordinator.document.blocks[0].text == "Hello bold ")
    #expect(coordinator.document.blocks[0].runs.contains { $0.style.bold })
    view.undoManager?.undo()
    #expect(coordinator.document == original)
    view.undoManager?.redo()
    #expect(coordinator.document.blocks[0].kind == .heading2)
    coordinator.mutate(.duplicate, name: "Duplicate")
    #expect(coordinator.document.blocks.count == 2)
    let duplicateID = coordinator.document.blocks[1].id
    coordinator.mutate(.delete, name: "Delete")
    #expect(coordinator.document.blocks.count == 1)
    view.undoManager?.undo()
    #expect(coordinator.document.blocks[1].id == duplicateID)
    view.undoManager?.undo()
    #expect(coordinator.document.blocks.count == 1)
    view.undoManager?.redo()
    #expect(coordinator.document.blocks[1].id == duplicateID)
    coordinator.mutate(.reorder(before: coordinator.document.blocks[0].id), id: duplicateID, name: "Reorder")
    #expect(coordinator.document.blocks[0].id == duplicateID)
    view.undoManager?.undo()
    #expect(coordinator.document.blocks[1].id == duplicateID)
    view.undoManager?.redo()
    #expect(coordinator.document.blocks[0].id == duplicateID)
}

@Test @MainActor func editorFormattingAndPastePreserveSelectionAndContent() {
    let (coordinator, view, window) = editor("Hello world")
    defer { window.close() }
    let selection = NSRange(location: 6, length: 5); view.setSelectedRange(selection)
    coordinator.format("underline")
    #expect(view.selectedRange() == selection)
    #expect(coordinator.document.blocks[0].runs.last?.style.underline == true)
    coordinator.format("link", link: "https://example.com")
    #expect(coordinator.document.blocks[0].runs.last?.style.link == "https://example.com")
    view.setSelectedRange(NSRange(location: 5, length: 0))
    let pasteboard = NSPasteboard.withUniqueName(); pasteboard.setString("\n- first\n    - nested\n```swift\nlet x = 1\n```", forType: .string)
    coordinator.paste(pasteboard)
    let all = coordinator.document.flattened
    #expect(all.contains { $0.text == "first" && $0.children.first?.text == "nested" })
    #expect(all.contains { $0.kind == .code && $0.text == "let x = 1" })
    #expect(all.last?.text == " world")
    #expect(BlockDocumentCodec.valid(coordinator.document))
}

@Test @MainActor func editorLongDocumentRenderAndReload() {
    let blocks = (0..<1000).map { EditorBlock(runs: [RichRun("Paragraph \($0) with sufficient content for wrapping and editing.")]) }
    let document = BlockDocument(blocks: blocks)
    let start = Date()
    let rich = BlockTextStorage.render(document, theme: NoemaTheme())
    let captured = BlockTextStorage.capture(rich, previous: document)
    #expect(captured.blocks == blocks)
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(captured)).blocks == blocks)
    print("1,000-block render/capture/serialization: \(Date().timeIntervalSince(start)) s")
}

@Test @MainActor func editorCrossBlockReplacementPreservesSurvivingChildren() {
    let (coordinator, view, window) = editor("First\nSecond\n    - Child remains\nLast")
    defer { window.close() }
    let ranges = BlockTextStorage.ranges(view.textStorage!)
    let selection = NSRange(location: 2, length: ranges[1].1.location + 3 - 2)
    view.setSelectedRange(selection)
    coordinator.transaction("Delete selection") { coordinator.replaceSelection(with: []) }
    #expect(coordinator.document.blocks[0].text == "Fiond")
    #expect(coordinator.document.flattened.contains { $0.text == "Child remains" })
    #expect(BlockDocumentCodec.valid(coordinator.document))
    view.undoManager?.undo()
    #expect(coordinator.document.blocks[0].text == "First")
    #expect(coordinator.document.blocks[1].children.first?.text == "Child remains")
}

@Test @MainActor func editorNativeTypingCaretSplitMergeAndUndo() {
    let (coordinator, view, window) = editor("")
    defer { window.close() }
    view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
    #expect(view.selectedRange().location == 0)
    view.undoManager?.beginUndoGrouping()
    view.insertText("hello😀", replacementRange: view.selectedRange())
    view.undoManager?.endUndoGrouping()
    #expect(coordinator.document.blocks[0].text == "hello😀")
    coordinator.mutate(.split(5), name: "Split")
    #expect(coordinator.document.blocks.count == 2)
    #expect(coordinator.document.blocks[1].text == "😀")
    #expect(view.selectedRange().location == 6)
    coordinator.mutate(.mergeBackward, name: "Merge")
    #expect(coordinator.document.blocks[0].text == "hello😀")
    view.undoManager?.undo()
    #expect(coordinator.document.blocks.count == 2)
    view.undoManager?.undo()
    #expect(coordinator.document.blocks.count == 1)
    view.undoManager?.undo()
    #expect(view.string == "\n")
    #expect(coordinator.document.blocks[0].text.isEmpty)
}

@Test @MainActor func editorRichPasteAndSemanticStatusPreserveFormatting() throws {
    let (coordinator, view, window) = editor("Initial")
    defer { window.close() }
    view.setSelectedRange(NSRange(location: 7, length: 0))
    let rich = NSAttributedString(string: " Rich", attributes: [.font: NSFont.boldSystemFont(ofSize: 16), .underlineStyle: 1, .link: URL(string: "https://example.com")!])
    let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let pasteboard = NSPasteboard.withUniqueName(); pasteboard.setData(data, forType: .rtf)
    coordinator.paste(pasteboard)
    #expect(coordinator.document.blocks[0].runs.last?.style.bold == true)
    #expect(coordinator.document.blocks[0].runs.last?.style.underline == true)
    #expect(coordinator.document.blocks[0].runs.last?.style.link == "https://example.com")
    coordinator.mutate(.semantic("question"), name: "Question")
    coordinator.mutate(.status("answered"), name: "Answered")
    coordinator.mutate(.transform(.heading2), name: "Heading")
    #expect(coordinator.document.blocks[0].metadata.status == "answered")
    #expect(coordinator.document.blocks[0].runs.last?.style.bold == true)
}

@Test @MainActor func semanticAccentsExcludeTrailingBlankLinesAndSpacing() {
    let (coordinator, view, window) = editor("Initial")
    defer { window.close() }
    for kind in [BlockKind.paragraph, .heading2, .quote, .code] {
        var metadata = BlockMetadata(); metadata.semantic = "idea"
        let block = EditorBlock(kind: kind, runs: [RichRun("One line\n \n\n")], metadata: metadata)
        coordinator.document = BlockDocument(blocks: [block, EditorBlock(runs: [RichRun("Next block")])])
        coordinator.render(selection: NSRange(location: 0, length: 0))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let range = BlockTextStorage.ranges(view.textStorage!)[0].1
        let bounds = view.rect(for: range)
        let font = view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        #expect(abs(bounds.height - (font.ascender - font.descender)) < 0.01)
        #expect(BlockTextStorage.capture(view.textStorage!, previous: coordinator.document).blocks == coordinator.document.blocks)
        #expect(coordinator.document.blocks[0].text == "One line\n \n\n")
    }
}

@Test @MainActor func convertedBlockCaretKeepsBaselineWhenTypingBegins() {
    let (coordinator, view, window) = editor("Initial")
    defer { window.close() }
    for (kind, semantic) in [(BlockKind.paragraph, false), (.heading2, false), (.bullet, false), (.quote, false), (.code, false), (.paragraph, true)] {
        var metadata = BlockMetadata(); if semantic { metadata.semantic = "idea" }
        coordinator.document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("Previous")]), EditorBlock(kind: kind, metadata: metadata)])
        coordinator.render(selection: NSRange(location: 0, length: 0))
        let start = BlockTextStorage.ranges(view.textStorage!)[1].1.location
        view.setSelectedRange(NSRange(location: start, length: 0))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let bounds = view.rect(for: NSRange(location: start, length: 1))
        let nativeBefore = view.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
        let localBefore = view.convert(window.convertFromScreen(nativeBefore), from: nil)
        #expect(abs(bounds.minY - localBefore.minY) < 1)
        view.undoManager?.beginUndoGrouping()
        view.insertText("A", replacementRange: NSRange(location: start, length: 0))
        view.undoManager?.endUndoGrouping()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let nativeAfter = view.firstRect(forCharacterRange: NSRange(location: start + 1, length: 0), actualRange: nil)
        let localAfter = view.convert(window.convertFromScreen(nativeAfter), from: nil)
        let typed = view.rect(for: NSRange(location: start, length: 1))
        #expect(abs(localAfter.minY - localBefore.minY) < 0.5)
        #expect(abs(typed.minY - localAfter.minY) < 1)
        #expect(view.string == "Previous\nA\n")
    }
}


@Test(arguments: [true, false]) @MainActor func pinnedAISummaryIsExcludedFromEditingAndRetainedAfterReplacement(showsSummary: Bool) {
    let model = AppModel()
    var document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("Original content")])])
    document.setAISummary("Generated overview")
    model.body = BlockDocumentCodec.encode(document)
    let article = SummarizedArticleView(model: model, showsSummary: showsSummary)
    let editable = BlockDocumentCodec.decode(article.editorText.wrappedValue)
    #expect(editable.aiSummary == nil)
    #expect(editable.blocks.first?.text == "Original content")
    article.editorText.wrappedValue = "Replacement content"
    let saved = BlockDocumentCodec.decode(model.body)
    #expect(saved.blocks.first == document.aiSummary)
    #expect(saved.withoutAISummary.blocks.first?.text == "Replacement content")
}


@Test func summaryDisclosureCollapsesOnScrollAndHonorsManualShowHide() {
    var state = SummaryDisclosureState()
    state.scrolled(to: 0)
    #expect(!state.collapsed)
    state.scrolled(to: 25)
    #expect(state.collapsed)
    state.toggle()
    #expect(!state.collapsed)
    state.scrolled(to: 200)
    #expect(!state.collapsed)
    state.toggle()
    #expect(state.collapsed)
    state.scrolled(to: 10)
    #expect(state.collapsed)
    state.scrolled(to: 0)
    #expect(!state.collapsed)
    state.scrolled(to: 40)
    #expect(state.collapsed)
}

@Test func generatedPageTitleValidation() {
    #expect(OnDeviceSummary.cleanTitle("  “Roman History”  ") == "Roman History")
    #expect(OnDeviceSummary.cleanTitle("\n ") == nil)
    #expect(OnDeviceSummary.cleanTitle("Title\nExplanation") == nil)
    #expect(OnDeviceSummary.cleanTitle(String(repeating: "x", count: 121)) == nil)
}

@Test func generatedTitleStripsMarkdownAndChoosesLanguage() {
    #expect(OnDeviceSummary.cleanTitle("# **[Roman History](https://example.com)**") == "Roman History")
    #expect(OnDeviceSummary.cleanTitle("`Roman` *History*") == "Roman History")
    #expect(OnDeviceSummary.titleLanguage("", preferredLanguage: "fr") == "fr")
    #expect(OnDeviceSummary.titleLanguage("This article describes the history of ancient Rome and the lives of its emperors.", preferredLanguage: "fr") == "en")
}
@Test @MainActor func generatedTitleDoesNotRequireActivePage() throws {
    let note = try NoteCodec.decode(Data("---\ntitle: Untitled\n---\nSome article text".utf8), path: "Wiki/Untitled.md", vaultID: UUID())
    let model = AppModel()
    #expect(model.editorAllowsGeneratedTitle(for: note))
    model.currentNote = note; model.title = note.title; model.body = note.body
    #expect(model.editorAllowsGeneratedTitle(for: note))
    model.title = "User title"
    #expect(!model.editorAllowsGeneratedTitle(for: note))
    model.currentNote = nil
    #expect(model.editorAllowsGeneratedTitle(for: note))
}

@Test @MainActor func explicitSaveNamesReopenedUntitledPageAndPreservesUserTitle() throws {
    let note = try NoteCodec.decode(Data("---\ntitle: Untitled 2\n---\nSome article text".utf8), path: "Wiki/Untitled 2.md", vaultID: UUID())
    let model = AppModel()
    model.currentNote = note; model.title = note.title; model.body = note.body
    #expect(!model.needsTitle)
    model.prepareUntitledPageForNaming()
    #expect(model.needsTitle)
    model.title = "Untitled thoughts about Rome"
    #expect(!model.needsTitle)
    let named = AppModel()
    named.currentNote = note; named.title = "My own title"; named.body = note.body
    named.prepareUntitledPageForNaming()
    #expect(!named.needsTitle)
    named.title = " "
    named.prepareUntitledPageForNaming()
    #expect(named.needsTitle)
}

// Opt-in: semantic quality requires the real on-device model, rather than a mocked prompt.
@Test func onDeviceTopicTitleAcceptance() async throws {
    guard ProcessInfo.processInfo.environment["NOEMA_AI_TITLE_ACCEPTANCE"] == "1" else { return }
    guard OnDeviceSummary.unavailabilityReason == nil else {
        Issue.record("On-device model unavailable for title acceptance")
        return
    }
    let samples = [
        ("Pertinax", "Pertinax became Roman emperor in 193 after the assassination of Commodus. This page explores Pertinax's short reign, his attempts to restore discipline, and his assassination by the Praetorian Guard."),
        ("Composting", "This page records my composting routine. Composting kitchen scraps with dry leaves creates soil for the garden. I turn the compost pile weekly, keep it moist, and balance green material with dry brown material.")
    ]
    for (topic, content) in samples {
        let title = try #require(await OnDeviceSummary().pageTitle(content))
        print("Topic title acceptance: \(topic) → \(title)")
        #expect(title.localizedCaseInsensitiveContains(topic))
        #expect(title.split(whereSeparator: \.isWhitespace).count <= 8)
        #expect(!title.hasSuffix("."))
        #expect(!title.contains("\n"))
        #expect(OnDeviceSummary.cleanTitle(title) == title)
    }
}

@Test @MainActor func unseenRenameTracksOtherPagesAndInactiveAppUntilViewed() throws {
    let note = try NoteCodec.decode(Data("---\ntitle: Original\n---\nText".utf8), path: "Wiki/Original.md", vaultID: UUID())
    let model = AppModel(); model.currentNote = note
    model.recordPageRename(note.id, from: "Original", to: "New")
    #expect(!model.unseenRenamedPages.contains(note.id))
    let other = UUID()
    model.recordPageRename(other, from: "Original", to: "Original")
    #expect(!model.unseenRenamedPages.contains(other))
    model.recordPageRename(other, from: "Original", to: "New")
    #expect(model.unseenRenamedPages.contains(other))
    model.appIsActive = false
    model.recordPageRename(note.id, from: "Original", to: "New")
    model.markPageViewed(note.id)
    #expect(model.unseenRenamedPages.contains(note.id))
    model.appIsActive = true; model.markPageViewed(note.id)
    #expect(!model.unseenRenamedPages.contains(note.id))
    #expect(model.unseenRenamedPages.contains(other))
    model.markPageViewed(other)
    #expect(model.unseenRenamedPages.isEmpty)
}
