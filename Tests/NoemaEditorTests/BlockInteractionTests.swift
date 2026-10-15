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

@Test @MainActor func handleMenuSplitsFormatFromSemanticAndUsesHandleModifiedTime() throws {
    let locale = Locale(identifier: "en_US")
    var metadata = BlockMetadata(); metadata.semantic = "idea"
    var heading = EditorBlock(kind: .heading2, runs: [RichRun("Heading")], metadata: metadata)
    let headingEdited = Date(timeIntervalSince1970: 1_700_000_000)
    heading.createdAt = headingEdited; heading.modifiedAt = headingEdited
    var body = EditorBlock(runs: [RichRun("Body")])
    let bodyEdited = Date(timeIntervalSince1970: 1_800_000_000)
    body.createdAt = bodyEdited; body.modifiedAt = bodyEdited
    let (coordinator, _, window) = blockInteractionEditor(BlockDocument(blocks: [heading, body]))
    defer { coordinator.invalidatePublication(); window.close() }
    let loadedHeading = coordinator.document.blocks[0]
    let loadedBody = coordinator.document.blocks[1]
    #expect(abs(loadedHeading.modifiedAt.timeIntervalSince(headingEdited)) < 1)
    #expect(abs(loadedBody.modifiedAt.timeIntervalSince(bodyEdited)) < 1)
    let model = try #require(coordinator.handleMenuModel(for: loadedHeading.id, locale: locale))
    let stamp = BlockHandleMenuModel.timestamp(loadedHeading.modifiedAt, locale: locale)
    #expect(model.rows == [.turnInto, .semantic, .insertBelow, .delete, .timestamp(stamp)])
    #expect(stamp != BlockHandleMenuModel.timestamp(loadedBody.modifiedAt, locale: locale))
    #expect(model.formatChoices.allSatisfy { choice in BlockCommand.all.first { $0.id == choice.commandID }?.semantic == nil })
    #expect(model.semanticChoices.filter(\.enabled).allSatisfy { choice in BlockCommand.all.first { $0.id == choice.commandID }?.semantic != nil })
    #expect(model.formatChoices.first { $0.commandID == "h2" }?.mark == .on)
    #expect(model.formatChoices.first { $0.commandID == "text" }?.mark == .off)
    #expect(model.semanticChoices.first { $0.commandID == "idea" }?.mark == .on)
    #expect(model.semanticChoices.first { $0.commandID == "clear-tag" }?.mark == .off)
    #expect(model.semanticChoices.allSatisfy { $0.commandID != nil })

    coordinator.selectBlock(loadedHeading.id, modifiers: [])
    coordinator.selectBlock(loadedBody.id, modifiers: .shift)
    let mixed = try #require(coordinator.handleMenuModel(for: loadedHeading.id, locale: locale))
    #expect(mixed.formatChoices.first { $0.commandID == "h2" }?.mark == .mixed)
    #expect(mixed.formatChoices.first { $0.commandID == "text" }?.mark == .mixed)
    #expect(mixed.semanticChoices.first { $0.commandID == "idea" }?.mark == .mixed)
    #expect(mixed.rows.last == .timestamp(stamp))

    var preserved = BlockMetadata(); preserved.semantic = "future-tag"
    let (unknownCoordinator, _, unknownWindow) = blockInteractionEditor(BlockDocument(blocks: [EditorBlock(runs: [RichRun("Future")], metadata: preserved)]))
    defer { unknownCoordinator.invalidatePublication(); unknownWindow.close() }
    let unknownModel = try #require(unknownCoordinator.handleMenuModel(for: unknownCoordinator.document.blocks[0].id))
    let unknown = try #require(unknownModel.semanticChoices.first { $0.commandID == nil })
    #expect(unknown.title == "future-tag")
    #expect(unknown.mark == .on)
    #expect(!unknown.enabled)
}

@Test @MainActor func handleMenuInsertBelowKeepsSubtreeAndPlacesCaret() throws {
    let child = EditorBlock(runs: [RichRun("Child")])
    let root = EditorBlock(runs: [RichRun("Root")], children: [child])
    let tail = EditorBlock(runs: [RichRun("Tail")])
    let (coordinator, view, window) = blockInteractionEditor(BlockDocument(blocks: [root, tail]))
    defer { coordinator.invalidatePublication(); window.close() }
    let rootID = coordinator.document.blocks[0].id
    let tailID = coordinator.document.blocks[1].id
    let childID = coordinator.document.blocks[0].children[0].id
    coordinator.selectBlock(rootID, modifiers: [])
    coordinator.selectBlock(tailID, modifiers: .shift)
    let before = coordinator.document
    coordinator.performHandleMenu(.insertBelow)
    #expect(coordinator.document == before)
    #expect(coordinator.beginHandleMenu(for: rootID) != nil)
    coordinator.performHandleMenu(.insertBelow)
    #expect(coordinator.document.blocks.count == 3)
    #expect(coordinator.document.blocks[0].id == rootID)
    #expect(coordinator.document.blocks[0].children.map(\.id) == [childID])
    let inserted = coordinator.document.blocks[1]
    #expect(inserted.kind == .paragraph)
    #expect(inserted.text.isEmpty)
    #expect(coordinator.document.blocks[2].id == tailID)
    #expect(coordinator.selectedBlockIDs.isEmpty)
    let range = try #require(coordinator.rangeIndex?.range(for: inserted.id))
    #expect(view.selectedRange() == NSRange(location: range.location, length: 0))
    view.undoManager?.undo()
    #expect(coordinator.document.blocks.map(\.id) == [rootID, tailID])
}

@Test @MainActor func handleMenuDeleteUndoesAndStaleContextDoesNotMutate() throws {
    let blocks = ["First", "Second"].map { EditorBlock(runs: [RichRun($0)]) }
    let (coordinator, view, window) = blockInteractionEditor(BlockDocument(blocks: blocks))
    defer { coordinator.invalidatePublication(); window.close() }
    let ids = coordinator.document.blocks.map(\.id)
    coordinator.selectBlock(ids[0], modifiers: [])
    coordinator.selectBlock(ids[1], modifiers: .shift)
    #expect(coordinator.beginHandleMenu(for: ids[0]) != nil)
    coordinator.performHandleMenu(.command("quote"))
    #expect(coordinator.document.blocks.map(\.kind) == [.quote, .quote])
    coordinator.clearBlockSelection()
    #expect(coordinator.beginHandleMenu(for: ids[0]) != nil)
    coordinator.performHandleMenu(.delete)
    #expect(coordinator.document.blocks.map(\.id) == [ids[1]])
    let undo = try #require(view.undoManager)
    undo.undo()
    #expect(coordinator.document.blocks.map(\.id) == ids)

    let retained = coordinator.document
    #expect(coordinator.beginHandleMenu(for: ids[0]) != nil)
    coordinator.mutate(.transform(.heading1), id: ids[0], name: "Heading")
    let headed = coordinator.document
    coordinator.performHandleMenu(.delete)
    #expect(coordinator.document == headed)
    #expect(coordinator.document != retained)

    let (retiredCoordinator, _, retiredWindow) = blockInteractionEditor(BlockDocument(blocks: [EditorBlock(runs: [RichRun("Only")])]))
    defer { retiredCoordinator.invalidatePublication(); retiredWindow.close() }
    let retiredID = retiredCoordinator.document.blocks[0].id
    let retiredBefore = retiredCoordinator.document
    #expect(retiredCoordinator.beginHandleMenu(for: retiredID) != nil)
    retiredCoordinator.contextualInteractionsRetired = true
    retiredCoordinator.performHandleMenu(.insertBelow)
    #expect(retiredCoordinator.document == retiredBefore)
}

@Test @MainActor func handleMenuNativeItemsPreserveStatesIconsAndDispatch() throws {
    _ = NSApplication.shared
    let controller = BlockHandleMenuController()
    let model = BlockHandleMenuModel(
        rows: [.turnInto, .semantic, .insertBelow, .delete, .timestamp("Edited today")],
        formatChoices: [
            .init(title: "Text", symbol: "text.alignleft", commandID: "text", mark: .mixed, enabled: true),
            .init(title: "Heading", symbol: "textformat", commandID: "h2", mark: .off, enabled: true)
        ],
        semanticChoices: [
            .init(title: "Idea", symbol: "lightbulb", commandID: "idea", mark: .on, enabled: true),
            .init(title: "future-tag", symbol: "tag", commandID: nil, mark: .on, enabled: false)
        ])
    let menu = controller.makeMenu(model: model)
    let format = try #require(menu.items[0].submenu)
    let semantic = try #require(menu.items[1].submenu)
    #expect(!menu.autoenablesItems && !format.autoenablesItems && !semantic.autoenablesItems)
    #expect(format.items.map(\.state) == [.mixed, .off])
    #expect(semantic.items.map(\.state) == [.on, .on])
    #expect(!semantic.items[1].isEnabled)
    #expect((menu.items + format.items + semantic.items).filter { !$0.isSeparatorItem && $0.title != "Edited today" }.allSatisfy { $0.image != nil })
    #expect(menu.items.last?.title == "Edited today")
    #expect(menu.items.last?.isEnabled == false)
    var actions: [BlockHandleMenuAction] = []
    controller.onAction = { actions.append($0) }
    format.performActionForItem(at: 0)
    semantic.performActionForItem(at: 0)
    menu.performActionForItem(at: 2)
    menu.performActionForItem(at: 4)
    #expect(actions == [.command("text"), .command("idea"), .insertBelow, .delete])
}
