import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

@MainActor private func annotationEditor() -> (RichArticleView.Coordinator, ArticleTextView) {
    _ = NSApplication.shared
    let source = "Alice 👩🏽‍💻\n\nSecond page phrase"
    let parent = RichArticleView(text: .constant(source), reading: false, locked: false, action: nil,
        onBegin: {}, onEnd: {}, onWikiLink: { _ in }, noteID: UUID(), vaultID: UUID(), sessionID: UUID(),
        annotationChoices: { [] }, onAnnotate: { _, _, _, _, _ in })
    let coordinator = parent.makeCoordinator()
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.isEditable = true; view.isSelectable = true
    coordinator.view = view; coordinator.load(source)
    let document = coordinator.document
    let pageID = coordinator.parent.noteID!
    coordinator.session.load(SemanticPageSnapshot(snapshot: .init(pageID: pageID, document: document,
        revision: .init(token: Data("page".utf8))), annotations: []), identity: coordinator.session.identity,
        selection: NSRange(location: 0, length: 0))
    return (coordinator, view)
}

@Test @MainActor func annotationNativeSelectionRejectsCrossBlockAndPartialGraphemes() throws {
    let (coordinator, view) = annotationEditor()
    view.setSelectedRange(NSRange(location: 0, length: 5))
    let selected = try #require(coordinator.annotationSelection())
    #expect(selected.0 == coordinator.document.blocks[0].id)
    #expect(selected.1 == NSRange(location: 0, length: 5))
    view.setSelectedRange(NSRange(location: 6, length: 2))
    #expect(coordinator.annotationSelection() == nil)
    let ranges = BlockTextStorage.ranges(view.textStorage!)
    let secondRange = try #require(ranges.first { coordinator.document.block($0.0)?.text == "Second page phrase" })
    view.setSelectedRange(NSRange(location: 0, length: secondRange.1.location + 2))
    #expect(coordinator.annotationSelection() == nil)
    view.setSelectedRange(NSRange(location: secondRange.1.location, length: 6))
    let second = try #require(coordinator.annotationSelection())
    #expect(second.0 == secondRange.0)
    #expect(second.1 == NSRange(location: 0, length: 6))
}

@Test @MainActor func annotationNativeSelectionRequiresWritableAvailableEditor() {
    let (coordinator, view) = annotationEditor()
    view.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(coordinator.annotationSelection() == nil)
    view.setSelectedRange(NSRange(location: 0, length: 5))
    view.locked = true
    #expect(coordinator.annotationSelection() == nil)
    view.locked = false; view.isEditable = false
    #expect(coordinator.annotationSelection() == nil)
    view.isEditable = true; coordinator.parent.vaultID = nil
    #expect(coordinator.annotationSelection() == nil)
}
