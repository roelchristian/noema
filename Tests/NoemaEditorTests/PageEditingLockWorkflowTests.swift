import AppKit
import Foundation
import SwiftUI
import Testing
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
    @Suite(.serialized) @MainActor
    struct PageEditingLockWorkflowTests {
        @Test(arguments: [false, true], [false, true])
        func annotatedPageLockKeepsNavigationAndSubsequentEditingAvailable(createNewPage: Bool, createEntity: Bool) async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaPageLockWorkflow-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let page = try await repository.create(title: "Untitled", body: "Ada Lovelace")
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("Local")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            model.select(page.id)

            _ = NSApplication.shared
            let parent = RichArticleView(text: SummarizedArticleView(model: model).editorText,
                editable: true, locked: false, action: nil, onWikiLink: { _ in },
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
            #expect(model.canEditPage)
            #expect(view.isEditable)
            model.aiClient = .init(unavailabilityReason: { nil }, summarize: { _ in "Summary" },
                inferLCC: { _ in "QA291" }, lccCode: { _ in "QA291" }, pageTitle: { _ in "Generated title" },
                pageFromTopic: { _, _ in "" }, pageFromSource: { _ in "" }, researchTopic: { _ in [] })
            model.prepareUntitledPageForNaming()
            #expect(await model.finishCurrentPage(waitForTitles: true))
            #expect(model.currentNote?.title == "Generated title")
            #expect(coordinator.session.pageRevision?.token.base64EncodedString() == model.currentNote?.contentHash)
            model.setPageLCC("QA292")
            for _ in 0..<200 {
                if model.saveStatus == "Saved locally" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.saveStatus == "Saved locally")
            #expect(coordinator.session.pageRevision?.token.base64EncodedString() == model.currentNote?.contentHash)
            view.setSelectedRange(NSRange(location: 0, length: 3))
            let selection = try #require(coordinator.annotationSelection())
            try await model.annotateSelection(coordinator, selection.0, selection.1,
                createEntity ? .newEntity(typeKey: "person", label: "Ada") : .newObject(typeKey: "definition", text: "A pioneer"), coordinator.session.revision)
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
                #expect(model.canEditPage)
                #expect(view.isEditable)
                #expect(!view.locked)
                coordinator.parent.locked = false
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

extension VaultUIIntegrationTests.PageEditingLockWorkflowTests {
    @Test func hostedPageBecomesEditableWithoutModeTransitionAndKeepsNavigationFocus() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaContinuous-\(UUID())")
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let page = try await repository.create(title: "Continuous", body: "Native paragraph")
        let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false); model.select(page.id)
        #expect(!model.canEditPage) // Semantic authority is not loaded yet.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SummarizedArticleView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let navigation = NSTextField(); host.addSubview(navigation); window.makeFirstResponder(navigation)
        defer { window.close() }
        func editor(in view: NSView) -> ArticleTextView? {
            if let article = view as? ArticleTextView { return article }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if model.canEditPage, editor(in: host)?.isEditable == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try #require(editor(in: host))
        try #require(model.canEditPage && view.isEditable)
        #expect(window.firstResponder !== view)
        window.makeFirstResponder(view)
        view.insertText("Immediate ", replacementRange: NSRange(location: 0, length: 0))
        model.flushEditorPublication?()
        #expect(model.editorDocument.blocks.first?.text == "Immediate Native paragraph")
        let selection = view.selectedRange(), undo = view.undoManager
        model.select(page.id)
        #expect(view.selectedRange() == selection)
        #expect(view.undoManager === undo)
        #expect(model.canEditPage)
        model.showSettings = true
        #expect(!model.canEditPage && !model.canFormatDocument)
        model.showSettings = false
        #expect(model.canEditPage)
        model.editorReadOnly = true
        #expect(!model.canEditPage)
        model.editorReadOnly = false
        #expect(await model.flushPendingEdits())
        #expect(view.selectedRange() == selection)
        #expect(await model.closeVault())
        #expect(!model.canEditPage)
    }
}


extension VaultUIIntegrationTests.PageEditingLockWorkflowTests {
    @Test func externalMetadataRevisionCannotGrantStaleEditorAuthority() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaReadiness-\(UUID())")
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let page = try await repository.create(title: "Original", body: "Same text")
        let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false); model.select(page.id)
        _ = try await repository.save(note: page, title: "External metadata", body: page.body, tags: ["external"])
        let parent = RichArticleView(document: SummarizedArticleView(model: model).editorDocument,
            editable: false, locked: false, action: nil, onWikiLink: { _ in }, noteID: page.id,
            vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID,
            onSemanticLoad: model.configureSemanticEditor)
        let coordinator = parent.makeCoordinator(), view = ArticleTextView()
        view.isEditable = false; coordinator.view = view; view.delegate = coordinator
        coordinator.load(parent.document)
        for _ in 0..<200 {
            if model.externalChange { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.externalChange)
        #expect(coordinator.session.semanticEdit == nil)
        #expect(!model.canEditPage && !view.isEditable)
        #expect(model.title == "Original")
        #expect(await model.closeVault())
    }
}
