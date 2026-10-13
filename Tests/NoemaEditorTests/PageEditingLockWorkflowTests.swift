import AppKit
import Foundation
import SwiftUI
import Testing
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
    @Suite(.serialized) @MainActor
    struct PageEditingLockWorkflowTests {
        @Test(arguments: [false, true])
        func annotatedPageLockKeepsNavigationAndSubsequentEditingAvailable(createNewPage: Bool) async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaPageLockWorkflow-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let page = try await repository.create(title: "Annotated page", body: "Ada Lovelace")
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("Local")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            model.select(page.id)
            model.reading = false

            _ = NSApplication.shared
            let parent = RichArticleView(text: SummarizedArticleView(model: model).editorText,
                reading: false, locked: false, action: nil, onBegin: {}, onEnd: {}, onWikiLink: { _ in },
                noteID: page.id, vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID,
                onSemanticLoad: model.configureSemanticEditor, annotationChoices: model.annotationChoices,
                onAnnotate: model.annotateSelection)
            let coordinator = parent.makeCoordinator()
            let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            view.isEditable = true; view.isSelectable = true; view.isRichText = true; view.allowsUndo = true
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.makeFirstResponder(view)
            view.undoManager?.groupsByEvent = false
            view.delegate = coordinator; coordinator.view = view; coordinator.load(parent.text)
            model.flushEditorPublication = { [weak coordinator] in coordinator?.flushPublication() }
            defer { model.flushEditorPublication = nil; window.close() }
            for _ in 0..<100 {
                if coordinator.session.semanticEdit != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(coordinator.session.semanticEdit != nil)
            view.setSelectedRange(NSRange(location: 0, length: 3))
            let selection = try #require(coordinator.annotationSelection())
            try await model.annotateSelection(coordinator, selection.0, selection.1,
                .newObject(typeKey: "definition", text: "A pioneer"), coordinator.session.revision)
            #expect(await model.saveCurrent())
            #expect(!model.dirty)
            view.undoManager?.beginUndoGrouping()
            view.insertText("Pending ", replacementRange: NSRange(location: 0, length: 0))
            view.undoManager?.endUndoGrouping()

            model.toggleEditingLock(page.id)
            #expect(!view.isEditable)
            #expect(model.editingLocked)
            for _ in 0..<200 {
                if model.editingLockOperations.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(model.currentNote?.isEditingLocked == true)
            #expect(!model.dirty)
            #expect(model.body == model.currentNote?.body)
            #expect(coordinator.session.pageRevision?.token.base64EncodedString() == model.currentNote?.contentHash)
            #expect(!view.isEditable)
            #expect(coordinator.document.blocks.first?.text == "Pending Ada Lovelace")
            #expect(model.canPerformWorkspaceCommand(.newPage))
            #expect(model.canPerformWorkspaceCommand(.quickOpen))

            if createNewPage {
                model.newPage(named: "New after locking")
                for _ in 0..<200 {
                    if model.currentNote?.id != page.id { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(model.currentNote?.title == "New after locking")
                #expect(!model.editingLocked)
                #expect(model.errorMessage == nil)
            } else {
                model.toggleEditingLock(page.id)
                for _ in 0..<200 {
                    if model.editingLockOperations.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(!model.editingLocked)
                #expect(!model.dirty)
                model.beginEditing()
                coordinator.parent.reading = false; coordinator.parent.locked = false
                view.locked = false; view.isEditable = true
                view.undoManager?.beginUndoGrouping()
                view.insertText("Edited ", replacementRange: NSRange(location: 0, length: 0))
                view.undoManager?.endUndoGrouping()
                #expect(await model.saveCurrent())
                let saved = try await repository.sqliteBlockStore.loadSemanticPage(pageID: page.id)
                #expect(saved.snapshot.document.blocks.first?.text == "Edited Pending Ada Lovelace")
                #expect(saved.annotations.count == 1)
                #expect(model.errorMessage == nil)
            }
            model.flushEditorPublication = nil
            #expect(await model.closeVault())
        }
    }
}
