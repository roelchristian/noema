import Foundation
import Testing
@testable import VaultCore

@Test @MainActor func editorSessionNativeReplacementAdvancesRevisionWithoutChangingIdentity() {
    let block = EditorBlock(runs: [RichRun("a😀研究")])
    let session = EditorSession(document: BlockDocument(blocks: [block]))
    let stale = session.snapshot()
    session.replaceText(block.id, range: NSRange(location: 1, length: 2), runs: [RichRun("é")], selection: NSRange(location: 2, length: 0))
    #expect(session.document.block(block.id)?.text == "aé研究")
    #expect(session.revision == 1)
    #expect(session.changedBlockIDs == [block.id])
    #expect(session.selection == NSRange(location: 2, length: 0))
    #expect(!session.markPublished(stale))
    #expect(session.markPublished(session.snapshot()))
    #expect(session.changedBlockIDs.isEmpty)
}

@Test @MainActor func editorSessionStructuralUndoRestoresDocumentAndSelectionAtNewRevision() {
    let block = EditorBlock(runs: [RichRun("first second")])
    let session = EditorSession(document: BlockDocument(blocks: [block]))
    session.selection = NSRange(location: 5, length: 0)
    let before = session.snapshot()
    let next = session.apply(.split(5), to: block.id)
    #expect(next != nil)
    #expect(session.document.blocks[0].id == block.id)
    let after = session.snapshot()
    session.restore(before, name: "Undo split")
    #expect(session.document == before.document)
    #expect(session.selection == before.selection)
    #expect(session.revision > after.revision)
    session.restore(after, name: "Redo split")
    #expect(session.document == after.document)
    #expect(session.mutationHistory.map(\.name) == ["Edit block", "Undo split", "Redo split"])
}

@Test @MainActor func editorSessionRejectsSnapshotsAcrossNavigationAndVaultSessions() {
    let page = UUID(), vault = UUID()
    let session = EditorSession(identity: .init(pageID: page, vaultID: vault, sessionID: UUID()))
    let old = session.snapshot()
    session.load(old.document, identity: .init(pageID: page, vaultID: vault, sessionID: UUID()), selection: .init(location: 0, length: 0))
    #expect(!session.accepts(old))
    let otherVault = session.snapshot()
    session.load(otherVault.document, identity: .init(pageID: page, vaultID: UUID()), selection: .init(location: 0, length: 0))
    #expect(!session.accepts(otherVault))
    let otherPage = session.snapshot()
    session.load(otherPage.document, identity: .init(pageID: UUID(), vaultID: vault), selection: .init(location: 0, length: 0))
    #expect(!session.accepts(otherPage))
    session.restore(old, name: "Stale undo")
    #expect(session.revision == 0)
}

@Test @MainActor func editorSessionPublishesOnlyChangedUnpublishedRevisions() {
    let block = EditorBlock(runs: [RichRun("Untouched Markdown")])
    let session = EditorSession(document: .init(blocks: [block]))
    #expect(!session.accepts(session.snapshot()))
    #expect(!session.markPublished(session.snapshot()))
    session.updateRuns(block.id, runs: [RichRun("Edited")], selection: .init(location: 6, length: 0))
    let first = session.snapshot()
    #expect(session.markPublished(first))
    #expect(!session.markPublished(first))
    session.updateRuns(block.id, runs: [RichRun("Edited again")], selection: .init(location: 12, length: 0))
    let second = session.snapshot()
    #expect(!session.markPublished(first))
    #expect(session.markPublished(second))
    #expect(session.publishedRevision == 2)
}

@Test @MainActor func editorSessionNoOpTypingAndUnknownBlockDoNotAdvanceRevision() {
    let block = EditorBlock(runs: [RichRun("😀é研究")])
    let session = EditorSession(document: .init(blocks: [block]))
    let selection = NSRange(location: 2, length: 1)
    session.updateRuns(block.id, runs: block.runs, selection: selection)
    session.updateRuns(UUID(), runs: [RichRun("Lost block")], selection: selection)
    #expect(session.revision == 0)
    #expect(session.document.blocks == [block])
    #expect(session.selection == selection)
    #expect(session.changedBlockIDs.isEmpty)
}

@Test @MainActor func editorSessionReloadRejectsSnapshotsEvenForSamePageAndVault() {
    let block = EditorBlock(runs: [RichRun("Original")])
    let identity = EditorSession.Identity(pageID: UUID(), vaultID: UUID(), sessionID: UUID())
    let session = EditorSession(document: .init(blocks: [block]), identity: identity)
    session.updateRuns(block.id, runs: [RichRun("Previous edit")], selection: .init(location: 4, length: 0))
    let obsolete = session.snapshot()
    session.load(.init(blocks: [block]), identity: identity, selection: .init(location: 0, length: 0))
    #expect(!session.markPublished(obsolete))
    session.restore(obsolete, name: "Stale undo")
    #expect(session.document.blocks == [block])
    #expect(session.mutationHistory.isEmpty)
    #expect(session.revision == 0)
}

@Test @MainActor func editorSessionStructuralAndMetadataMutationsPreserveExistingUUIDs() {
    let first = EditorBlock(runs: [RichRun("first")])
    let second = EditorBlock(runs: [RichRun("second")])
    let session = EditorSession(document: .init(blocks: [first, second]))
    _ = session.apply(.indent, to: second.id)
    #expect(session.document.block(first.id)?.children.first?.id == second.id)
    _ = session.apply(.outdent, to: second.id)
    _ = session.apply(.reorder(before: first.id), to: second.id)
    #expect(session.document.blocks.map(\.id) == [second.id, first.id])
    _ = session.apply(.transform(.heading2), to: first.id)
    _ = session.apply(.semantic("question"), to: first.id)
    _ = session.apply(.status("open"), to: first.id)
    #expect(session.document.block(first.id)?.kind == .heading2)
    #expect(session.document.block(first.id)?.metadata.status == "open")
    let duplicate = session.apply(.duplicate, to: first.id)
    #expect(duplicate?.id != first.id)
    #expect(session.document.block(first.id)?.text == "first")
    #expect(session.document.block(second.id)?.text == "second")
    #expect(session.changedBlockIDs.contains(first.id))
    #expect(session.changedBlockIDs.contains(second.id))
}

@Test @MainActor func editorSessionMarksReparentedBlockEvenWhenFlattenedOrderIsUnchanged() {
    let first = EditorBlock(runs: [RichRun("Parent")])
    let second = EditorBlock(runs: [RichRun("Child")])
    let session = EditorSession(document: BlockDocument(blocks: [first, second]))
    session.apply(.indent, to: second.id)
    #expect(session.document.blocks.first?.children.first?.id == second.id)
    #expect(session.changedBlockIDs.contains(second.id))
    #expect(session.changedBlockIDs.contains(first.id))
}
