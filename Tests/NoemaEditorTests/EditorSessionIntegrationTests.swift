import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

@Suite("EDT incremental session integration", .serialized)
@MainActor struct EditorSessionIntegrationTests {
    private func editor(_ parent: RichArticleView) -> (RichArticleView.Coordinator, ArticleTextView, NSWindow) {
        _ = NSApplication.shared
        let coordinator = parent.makeCoordinator()
        let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = true; view.isSelectable = true; view.isRichText = true; view.allowsUndo = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeFirstResponder(view)
        view.undoManager?.groupsByEvent = false
        view.delegate = coordinator; coordinator.view = view; coordinator.load(parent.text)
        return (coordinator, view, window)
    }

    @Test func typingFlushKeepsSummaryAndUntouchedPlainMarkdown() throws {
        var source = "Unchanged plain text"
        var parent = RichArticleView(text: Binding(get: { source }, set: { source = $0 }), reading: false,
            locked: false, action: nil, onBegin: {}, onEnd: {}, onWikiLink: { _ in })
        let (plain, _, plainWindow) = editor(parent)
        defer { plainWindow.close() }
        plain.flushPublication()
        #expect(source == "Unchanged plain text")
        var document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("Personal text")])])
        document.setAISummary("Generated overview")
        source = BlockDocumentCodec.encode(document)
        parent.hidesAISummary = true
        let (coordinator, view, window) = editor(parent)
        defer { window.close() }
        #expect(!view.string.contains("Generated overview"))
        let before = source
        view.undoManager?.beginUndoGrouping()
        view.insertText("😀 ", replacementRange: NSRange(location: 0, length: 0))
        view.undoManager?.endUndoGrouping()
        #expect(source == before)
        #expect(coordinator.document.withoutAISummary.blocks.first?.text == "😀 Personal text")
        coordinator.flushPublication()
        let saved = BlockDocumentCodec.decode(source)
        #expect(saved.aiSummary == document.aiSummary)
        #expect(saved.withoutAISummary.blocks.first?.id == document.withoutAISummary.blocks.first?.id)
        #expect(saved.withoutAISummary.blocks.first?.text == "😀 Personal text")
        let published = source
        coordinator.flushPublication()
        #expect(source == published)
    }

    @Test func asynchronousPublicationRejectsSupersededRevisionAndNavigation() async throws {
        var source = "First"
        var writes = 0
        let parent = RichArticleView(text: Binding(get: { source }, set: { source = $0; writes += 1 }), reading: false,
            locked: false, action: nil, onBegin: {}, onEnd: {}, onWikiLink: { _ in }, noteID: UUID(), vaultID: UUID(), sessionID: UUID())
        let (coordinator, _, window) = editor(parent)
        defer { window.close() }
        let id = try #require(coordinator.document.blocks.first?.id)
        coordinator.session.updateRuns(id, runs: [RichRun("Old revision")], selection: .init(location: 0, length: 0))
        coordinator.publish()
        coordinator.session.updateRuns(id, runs: [RichRun("Newest revision")], selection: .init(location: 0, length: 0))
        coordinator.publish()
        #expect(source == "First")
        for _ in 0..<100 {
            if writes > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(writes == 1)
        #expect(BlockDocumentCodec.decode(source).blocks.first?.text == "Newest revision")
        coordinator.session.updateRuns(id, runs: [RichRun("Abandoned revision")], selection: .init(location: 0, length: 0))
        coordinator.publish()
        coordinator.parent.noteID = UUID()
        coordinator.flushPublication()
        try await Task.sleep(for: .milliseconds(100))
        #expect(writes == 1)
    }

    @Test func structuralUndoRedoRestoresSelectionAndStableIDs() throws {
        var source = "First second"
        let parent = RichArticleView(text: Binding(get: { source }, set: { source = $0 }), reading: false,
            locked: false, action: nil, onBegin: {}, onEnd: {}, onWikiLink: { _ in })
        let (coordinator, view, window) = editor(parent)
        defer { window.close() }
        let original = coordinator.document
        let selection = NSRange(location: 5, length: 0)
        view.setSelectedRange(selection)
        coordinator.mutate(.split(5), name: "Split block")
        let split = coordinator.document
        let splitSelection = view.selectedRange()
        #expect(split.blocks.count == 2)
        let undo = try #require(view.undoManager)
        undo.undo()
        #expect(coordinator.document == original)
        #expect(view.selectedRange() == selection)
        undo.redo()
        #expect(coordinator.document == split)
        #expect(view.selectedRange() == splitSelection)
    }

    @Test func saveAndLockFlushLatestNativeEditBeforePersistence() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("EDT-session-" + UUID().uuidString)
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let page = try await repository.create(title: "Session fixture", body: "Original")
        let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(page.id)
        for _ in 0..<100 {
            if model.currentNote?.id == page.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.currentNote?.id == page.id)
        let article = SummarizedArticleView(model: model)
        let binding = article.editorText
        let parent = RichArticleView(text: article.editorText, reading: false, locked: false, action: nil,
            onBegin: {}, onEnd: {}, onWikiLink: { _ in }, noteID: page.id,
            vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID)
        let (coordinator, view, window) = editor(parent)
        defer { window.close(); model.flushEditorPublication = nil }
        model.flushEditorPublication = { [weak coordinator] in coordinator?.flushPublication() }
        view.undoManager?.beginUndoGrouping()
        view.insertText("Saved ", replacementRange: NSRange(location: 0, length: 0))
        view.undoManager?.endUndoGrouping()
        #expect(BlockDocumentCodec.markdownBody(model.body) == "Original")
        #expect(await model.saveCurrent())
        var batch = try await repository.scan()
        #expect(BlockDocumentCodec.decode(try #require(batch.notes.first(where: { $0.id == page.id })).body).blocks.first?.text == "Saved Original")
        view.undoManager?.beginUndoGrouping()
        view.insertText("Locked ", replacementRange: NSRange(location: 0, length: 0))
        view.undoManager?.endUndoGrouping()
        #expect(await model.lockVault())
        batch = try await repository.scan()
        #expect(BlockDocumentCodec.decode(try #require(batch.notes.first(where: { $0.id == page.id })).body).blocks.first?.text == "Locked Saved Original")
        let lockedBody = model.body
        binding.wrappedValue = "stale result"
        #expect(model.body == lockedBody)
    }
}
