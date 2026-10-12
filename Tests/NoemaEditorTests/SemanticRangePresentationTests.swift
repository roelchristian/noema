import AppKit
import Testing
import VaultCore
@testable import noema

@MainActor private struct SemanticPresentationFixture {
    let page = UUID(), revision = BlockStoreRevision(token: Data("presentation-revision".utf8))
    var block = EditorBlock(runs: [RichRun("Alice and Bob")])
    var document: BlockDocument { .init(blocks: [block]) }
    func annotation(_ range: NSRange, disposition: AnnotationDisposition = .resolved) throws -> SemanticAnnotation {
        .init(location: .inline(pageID: page, blockID: block.id,
            target: try InlineAnnotationTarget(text: block.text, range: range, revision: revision.token)),
            referent: .init(identity: .init(kind: "person", id: UUID())), designation: "person",
            anchorDisposition: disposition, expectedRevision: revision.token)
    }
}

@Test @MainActor func semanticRangePresentationPreservesIdenticalNestedCrossingAssociationsAndNativeStyles() throws {
    let f = SemanticPresentationFixture(), storage = NSTextStorage(attributedString: BlockTextStorage.render(f.document, theme: NoemaTheme()))
    let original = NSAttributedString(attributedString: storage), blocks = BlockTextStorage.RangeIndex(storage)
    let index = BlockTextStorage.SemanticRangeIndex()
    let annotations = try [f.annotation(.init(location: 0, length: 5)), f.annotation(.init(location: 0, length: 5)),
        f.annotation(.init(location: 0, length: 9)), f.annotation(.init(location: 3, length: 7))]
    #expect(!index.update(document: f.document, annotations: annotations, pageID: f.page, revision: f.revision, storage: storage, blocks: blocks).isEmpty)
    #expect(Set(index.associations(in: .init(location: 3, length: 0), blocks: blocks).map { $0.annotation.id }) == Set(annotations.map(\.id)))
    #expect(index.associations(in: .init(location: 5, length: 0), blocks: blocks).count == 2)
    #expect(index.associations(in: .init(location: 13, length: 0), blocks: blocks).isEmpty)
    #expect(storage.isEqual(to: original))
    #expect(BlockTextStorage.capture(storage, previous: f.document).blocks[0].runs == f.block.runs)
    let generation = index.generation
    for caret in 0..<13 { _ = index.associations(in: .init(location: caret, length: 0), blocks: blocks) }
    #expect(index.generation == generation)
    #expect(index.update(document: f.document, annotations: Array(annotations.reversed()), pageID: f.page, revision: f.revision, storage: storage, blocks: blocks).isEmpty)
}

@Test @MainActor func semanticRangePresentationRejectsStaleRevisionQuoteDigestAndChangedDisplay() throws {
    let f = SemanticPresentationFixture(), storage = NSTextStorage(attributedString: BlockTextStorage.render(f.document, theme: NoemaTheme()))
    let blocks = BlockTextStorage.RangeIndex(storage), index = BlockTextStorage.SemanticRangeIndex()
    let good = try f.annotation(.init(location: 0, length: 5))
    var wrongRevision = good; wrongRevision.id = UUID(); wrongRevision.expectedRevision = Data("wrong".utf8)
    var wrongQuote = good; wrongQuote.id = UUID()
    if case .inline(let page, let block, var target) = wrongQuote.location {
        target.quote = "Other"; wrongQuote.location = .inline(pageID: page, blockID: block, target: target)
    }
    var wrongDigest = good; wrongDigest.id = UUID()
    if case .inline(let page, let block, var target) = wrongDigest.location {
        target.digest = "invalid"; wrongDigest.location = .inline(pageID: page, blockID: block, target: target)
    }
    let stale = try f.annotation(.init(location: 0, length: 5), disposition: .stale)
    let deleted = try f.annotation(.init(location: 0, length: 5), disposition: .deleted)
    index.update(document: f.document, annotations: [good, wrongRevision, wrongQuote, wrongDigest, stale, deleted], pageID: f.page, revision: f.revision, storage: storage, blocks: blocks)
    #expect(index.associations(in: .init(location: 0, length: 5), blocks: blocks).map { $0.annotation.id } == [good.id])
    storage.replaceCharacters(in: .init(location: 0, length: 5), with: "Other")
    #expect(!index.update(document: f.document, annotations: [good], pageID: f.page, revision: f.revision, storage: storage, blocks: blocks).isEmpty)
    #expect(index.entriesByBlock.isEmpty)
}

@Test @MainActor func semanticRangePresentationStyleRefreshKeepsIDsAndNativeSelectionClipboard() throws {
    _ = NSApplication.shared
    var f = SemanticPresentationFixture()
    let annotations = try [f.annotation(.init(location: 0, length: 5)), f.annotation(.init(location: 0, length: 5))]
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    view.isEditable = true; view.isSelectable = true
    let storage = try #require(view.textStorage)
    storage.setAttributedString(BlockTextStorage.render(f.document, theme: NoemaTheme()))
    let blocks = BlockTextStorage.RangeIndex(storage); view.blockRangeIndex = blocks
    view.setSelectedRange(.init(location: 0, length: 5))
    view.semanticRangeIndex.update(document: f.document, annotations: annotations, pageID: f.page, revision: f.revision, storage: storage, blocks: blocks)
    let generation = view.semanticRangeIndex.generation
    f.block.runs[0].style.bold = true
    // Match refreshPresentation's attribute-only update; structural render restores selection separately.
    let styled = BlockTextStorage.render(f.document, theme: NoemaTheme())
    styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attributes, range, _ in
        storage.setAttributes(attributes, range: range)
    }
    #expect(view.semanticRangeIndex.update(document: f.document, annotations: annotations, pageID: f.page, revision: f.revision, storage: storage, blocks: blocks).isEmpty)
    #expect(view.semanticRangeIndex.generation == generation)
    #expect(view.selectedRange() == NSRange(location: 0, length: 5))
    #expect(Set(view.semanticAssociations(in: view.selectedRange()).map { $0.annotation.id }) == Set(annotations.map(\.id)))
    let menu = NSMenu(); view.addSemanticAssociations(to: menu, at: .zero)
    #expect(menu.items.first?.submenu?.items.count == 2)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
    #expect(pasteboard.string(forType: .string) == "Alice")
    #expect(BlockTextStorage.capture(storage, previous: f.document).blocks[0].runs[0].style.bold)
}

@Test @MainActor func semanticRangePresentationGlyphHitTestingReturnsAllAndIgnoresMarkedText() throws {
    _ = NSApplication.shared
    let f = SemanticPresentationFixture()
    let annotations = try [f.annotation(.init(location: 0, length: 5)), f.annotation(.init(location: 0, length: 5))]
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    view.isEditable = true; view.isSelectable = true
    let storage = try #require(view.textStorage)
    storage.setAttributedString(BlockTextStorage.render(f.document, theme: NoemaTheme()))
    let blocks = BlockTextStorage.RangeIndex(storage); view.blockRangeIndex = blocks
    view.semanticRangeIndex.update(document: f.document, annotations: annotations, pageID: f.page, revision: f.revision, storage: storage, blocks: blocks)
    let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
    layout.ensureLayout(for: container)
    let rect = layout.boundingRect(forGlyphRange: NSRange(location: 1, length: 1), in: container)
    let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
    #expect(view.semanticAssociations(at: point).count == 2)
    #expect(view.semanticAssociations(at: NSPoint(x: -100, y: -100)).isEmpty)
    view.setMarkedText("Changed", selectedRange: .init(location: 0, length: 0), replacementRange: .init(location: 0, length: 5))
    #expect(view.hasMarkedText())
    #expect(view.semanticAssociations(in: .init(location: 0, length: 1)).isEmpty)
    view.unmarkText()
}
