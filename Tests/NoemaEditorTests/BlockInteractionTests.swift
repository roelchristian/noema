import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

@MainActor private func blockInteractionEditor(_ document: BlockDocument) -> (RichArticleView.Coordinator, ArticleTextView, NSWindow) {
    _ = NSApplication.shared
    var source = BlockDocumentCodec.encode(document)
    let parent = RichArticleView(text: Binding(get: { source }, set: { source = $0 }), editable: true, locked: false,
        action: nil, onWikiLink: { _ in })
    let coordinator = parent.makeCoordinator()
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.isEditable = true; view.isSelectable = true; view.isRichText = true; view.allowsUndo = true
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.makeFirstResponder(view)
    view.undoManager?.groupsByEvent = false
    coordinator.view = view; view.delegate = coordinator; coordinator.load(source)
    return (coordinator, view, window)
}

@Test @MainActor func blockHandleSelectionPreservesCaretAndNativeSelectionRemainsIndependent() {
    let blocks = [EditorBlock(runs: [RichRun("First")]), EditorBlock(runs: [RichRun("Second")]), EditorBlock(runs: [RichRun("Third")])]
    let (coordinator, view, window) = blockInteractionEditor(BlockDocument(blocks: blocks))
    defer { coordinator.invalidatePublication(); window.close() }
    let ids = coordinator.document.blocks.map(\.id)
    let caret = NSRange(location: 2, length: 0); view.setSelectedRange(caret)
    coordinator.selectBlock(ids[0], modifiers: [])
    coordinator.selectBlock(ids[2], modifiers: .shift)
    #expect(coordinator.selectedBlockIDs == Set(ids))
    #expect(view.selectedRange() == caret)
    coordinator.selectBlock(ids[1], modifiers: .command)
    #expect(coordinator.selectedBlockIDs == Set([ids[0], ids[2]]))
    view.setSelectedRange(NSRange(location: 1, length: 8))
    coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
    #expect(coordinator.selectedBlockIDs.isEmpty)
    #expect(view.selectedRange() == NSRange(location: 1, length: 8))
}

@Test @MainActor func selectedBlocksMoveAtomicallyAndUndoRestoresUUIDSelection() throws {
    let blocks = ["A", "B", "C", "D"].map { EditorBlock(runs: [RichRun($0)]) }
    let (coordinator, view, window) = blockInteractionEditor(BlockDocument(blocks: blocks))
    defer { coordinator.invalidatePublication(); window.close() }
    let ids = coordinator.document.blocks.map(\.id)
    coordinator.selectBlock(ids[1], modifiers: [])
    coordinator.selectBlock(ids[2], modifiers: .shift)
    coordinator.mutate(.move(1), name: "Move blocks")
    #expect(coordinator.document.blocks.map(\.id) == [ids[0], ids[3], ids[1], ids[2]])
    #expect(coordinator.selectedBlockIDs == Set([ids[1], ids[2]]))
    let undo = try #require(view.undoManager)
    undo.undo()
    #expect(coordinator.document.blocks.map(\.id) == ids)
    #expect(coordinator.selectedBlockIDs == Set([ids[1], ids[2]]))
    undo.redo()
    #expect(coordinator.document.blocks.map(\.id) == [ids[0], ids[3], ids[1], ids[2]])
}

@Test @MainActor func handleReorderKeepsCaretInOriginalTextAndUndoRestoresIt() throws {
    let blocks = ["First", "Second"].map { EditorBlock(runs: [RichRun($0)]) }
    let (coordinator, view, window) = blockInteractionEditor(BlockDocument(blocks: blocks))
    defer { coordinator.invalidatePublication(); window.close() }
    let ids = coordinator.document.blocks.map(\.id)
    view.setSelectedRange(NSRange(location: 2, length: 0))
    coordinator.selectBlock(ids[1], modifiers: [])
    coordinator.mutate(.reorder(before: ids[0]), id: ids[1], name: "Drag block")
    #expect(coordinator.document.blocks.map(\.id) == [ids[1], ids[0]])
    let movedRange = try #require(coordinator.rangeIndex?.range(for: ids[0]))
    #expect(view.selectedRange() == NSRange(location: movedRange.location + 2, length: 0))
    #expect(coordinator.selectedBlockIDs == [ids[1]])
    let undo = try #require(view.undoManager)
    undo.undo()
    #expect(coordinator.document.blocks.map(\.id) == ids)
    #expect(view.selectedRange() == NSRange(location: 2, length: 0))
}

@Test @MainActor func semanticContextAndSlashCommandsPreserveStructureMetadataAndIdentity() throws {
    var metadata = BlockMetadata(); metadata.semantic = "future-designation"; metadata.status = "future-status"; metadata.extra = ["future": "preserve"]
    let block = EditorBlock(kind: .heading2, runs: [RichRun("Heading /idea")], metadata: metadata)
    let (coordinator, view, window) = blockInteractionEditor(BlockDocument(blocks: [block]))
    defer { coordinator.invalidatePublication(); window.close() }
    let id = coordinator.document.blocks[0].id
    let idea = try #require(BlockCommand.all.first { $0.id == "idea" })
    let callout = try #require(BlockCommand.all.first { $0.id == "callout" })
    coordinator.apply(callout, removingQuery: false)
    #expect(coordinator.document.block(id)?.metadata == metadata)
    view.undoManager?.undo()
    view.setSelectedRange(NSRange(location: "Heading /idea".utf16.count, length: 0))
    coordinator.slashRange = NSRange(location: 8, length: 5)
    coordinator.apply(idea, removingQuery: true)
    #expect(coordinator.document.block(id)?.text == "Heading ")
    #expect(coordinator.document.block(id)?.kind == .heading2)
    #expect(coordinator.document.block(id)?.metadata.semantic == "idea")
    #expect(coordinator.document.block(id)?.metadata.extra == ["future": "preserve"])
    view.undoManager?.undo()
    #expect(coordinator.document.block(id)?.metadata == metadata)
    #expect(coordinator.document.block(id)?.text == "Heading /idea")
    coordinator.apply(idea, removingQuery: false)
    #expect(coordinator.document.block(id)?.text == "Heading /idea")
    #expect(coordinator.document.block(id)?.kind == .heading2)
}

@Test @MainActor func selectedParentCopyIncludesSubtreeOnceAndFutureDesignationMenuIsPreserved() throws {
    let child = EditorBlock(runs: [RichRun("Child")])
    var metadata = BlockMetadata(); metadata.semantic = "future-tag"; metadata.status = "future-state"
    let block = EditorBlock(runs: [RichRun("Parent")], metadata: metadata, children: [child])
    let (coordinator, _, window) = blockInteractionEditor(BlockDocument(blocks: [block]))
    defer { coordinator.invalidatePublication(); window.close() }
    let parent = coordinator.document.blocks[0]
    coordinator.selectBlock(parent.id, modifiers: [])
    coordinator.selectBlock(parent.children[0].id, modifiers: .command)
    let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
    coordinator.copyBlocks(to: pasteboard)
    let copied = try #require(pasteboard.string(forType: .string))
    #expect(copied.components(separatedBy: "Child").count == 2)
    let menu = coordinator.contextMenu()
    let tags = try #require(menu.items.first { $0.title == "Semantic tag" }?.submenu)
    #expect(tags.items.contains { $0.title == "future-tag" && $0.state == .on })
    let status = try #require(menu.items.first { $0.title == "Status" }?.submenu)
    #expect(status.items.contains { $0.title == "future-state" && $0.state == .on })
}

@Test @MainActor func contextualInsertionPreservesSubtreeTargetsCaretAndRejectsRetiredContext() throws {
    let child = EditorBlock(runs: [RichRun("Child")])
    let root = EditorBlock(runs: [RichRun("Root")], children: [child])
    let tail = EditorBlock(runs: [RichRun("Tail")])
    let (coordinator, view, window) = blockInteractionEditor(BlockDocument(blocks: [root, tail]))
    defer { coordinator.invalidatePublication(); window.close() }
    view.setSelectedRange(NSRange(location: 2, length: 0))
    let before = coordinator.document
    let context = try #require(coordinator.interactionContext)
    _ = coordinator.insertionMenu(after: root.id)
    #expect(coordinator.document == before)
    let heading = try #require(BlockCommand.all.first { $0.id == "h2" })
    coordinator.insert(heading, after: root.id, context: context)
    #expect(coordinator.document.blocks.count == 3)
    #expect(coordinator.document.blocks[0] == root)
    let inserted = coordinator.document.blocks[1]
    #expect(inserted.kind == .heading2)
    #expect(inserted.id != root.id && inserted.id != child.id)
    let range = try #require(coordinator.rangeIndex?.range(for: inserted.id))
    #expect(view.selectedRange() == NSRange(location: range.location, length: 0))
    let after = coordinator.document
    coordinator.insert(heading, after: tail.id, context: context)
    #expect(coordinator.document == after)
    let undo = try #require(view.undoManager)
    undo.undo()
    #expect(coordinator.document == before)
    #expect(view.selectedRange() == context.selection)
    coordinator.load(before)
    coordinator.insert(heading, after: root.id, context: context)
    #expect(coordinator.document == before)
    coordinator.contextualIdentitySuspended = true
    #expect(coordinator.interactionContext == nil)
    coordinator.insert(heading, after: root.id, context: context)
    #expect(coordinator.document == before)
    coordinator.contextualIdentitySuspended = false
    #expect(coordinator.interactionContext != nil)
    coordinator.contextualInteractionsRetired = true
    #expect(coordinator.interactionContext == nil)
    coordinator.insert(heading, after: root.id, context: context)
    #expect(coordinator.document == before)
    view.locked = true
    #expect(coordinator.interactionContext == nil)
}
