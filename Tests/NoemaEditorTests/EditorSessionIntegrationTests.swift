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
        var parent = RichArticleView(text: Binding(get: { source }, set: { source = $0 }), editable: true,
            locked: false, action: nil, onWikiLink: { _ in })
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
        let parent = RichArticleView(text: Binding(get: { source }, set: { source = $0; writes += 1 }), editable: true,
            locked: false, action: nil, onWikiLink: { _ in }, noteID: UUID(), vaultID: UUID(), sessionID: UUID())
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
        let parent = RichArticleView(text: Binding(get: { source }, set: { source = $0 }), editable: true,
            locked: false, action: nil, onWikiLink: { _ in })
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
        let parent = RichArticleView(document: article.editorDocument, editable: true, locked: false, action: nil,
            onWikiLink: { _ in }, noteID: page.id,
            vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID, onSnapshot: model.acceptEditorSnapshot)
        let (coordinator, view, window) = editor(parent)
        defer { window.close(); model.flushEditorPublication = nil }
        model.registerEditorSession(coordinator.session)
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
    @Test func annotationAppModelCommandSaveUndoRedoAndReopenRemainCoherent() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SEM-INL01-model-" + UUID().uuidString)
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let page = try await repository.create(title: "Annotation fixture", body: "Ada Lovelace")
        let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(page.id)
        for _ in 0..<100 {
            if model.currentNote?.id == page.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.currentNote?.id == page.id)
                let parent = RichArticleView(document: SummarizedArticleView(model: model).editorDocument,
            editable: true, locked: false, action: nil, onWikiLink: { _ in },
            noteID: page.id, vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID,
            onSnapshot: model.acceptEditorSnapshot,
            onSemanticLoad: model.configureSemanticEditor, annotationChoices: model.annotationChoices,
            onAnnotate: model.annotateSelection)
        let (coordinator, view, window) = editor(parent)
        defer { window.close(); model.flushEditorPublication = nil }
        model.flushEditorPublication = { [weak coordinator] in coordinator?.flushPublication() }
        for _ in 0..<100 {
            if coordinator.session.semanticEdit != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(coordinator.session.semanticEdit != nil)
        view.setSelectedRange(NSRange(location: 0, length: 3))
        let selection = try #require(coordinator.annotationSelection())
        try await model.annotateSelection(coordinator, selection.0, selection.1,
            .newObject(typeKey: "definition", text: "A pioneer"), coordinator.session.revision)
        #expect(model.dirty)
        #expect(await model.saveCurrent())
        let saved = try await repository.sqliteBlockStore.loadSemanticPage(pageID: page.id)
        #expect(saved.annotations.count == 1 && saved.objects.count == 1)
        #expect(saved.snapshot.document.blocks[0].text == "Ada Lovelace")
        let undo = try #require(view.undoManager)
        undo.undo()
        #expect(await model.saveCurrent())
        let undone = try await repository.sqliteBlockStore.loadSemanticPage(pageID: page.id)
        #expect(undone.annotations.allSatisfy { $0.annotation.anchorDisposition == .deleted })
        #expect(undone.objects[0].object.lifecycle == .live)
        undo.redo()
        #expect(await model.saveCurrent())
        let redone = try await repository.sqliteBlockStore.loadSemanticPage(pageID: page.id)
        #expect(redone.annotations[0].annotation.anchorDisposition == .resolved)
        #expect(redone.objects[0].object.id == saved.objects[0].object.id)
        view.undoManager?.beginUndoGrouping()
        view.insertText("!", replacementRange: NSRange(location: view.string.utf16.count - 1, length: 0))
        view.undoManager?.endUndoGrouping()
        coordinator.flushPublication()
        #expect(model.editorDocument.blocks[0].text == "Ada Lovelace!")
        #expect(await model.saveCurrent())
        let typed = try await repository.sqliteBlockStore.loadSemanticPage(pageID: page.id)
        #expect(typed.snapshot.document.blocks[0].text == "Ada Lovelace!")
        #expect(typed.annotations[0].annotation.id == saved.annotations[0].annotation.id)
        #expect(typed.annotations[0].annotation.anchorDisposition == .stale)
        coordinator.load(model.editorDocument)
        for _ in 0..<100 {
            if coordinator.session.semanticEdit != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.session.semanticEdit?.annotations.first?.id == saved.annotations.first?.annotation.id)
    }

    @Test func semanticInspectionCanonicalEditReplaceAndRemoveKeepSharedTargetsIndependent() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SEM-inspect-" + UUID().uuidString)
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true), store = repository.sqliteBlockStore
        let person = try await store.createEntity(.init(typeKey: "person", label: "Ada", description: "A pioneer", aliases: [.init(label: "Countess")]), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let place = try await store.createEntity(.init(typeKey: "place", label: "London"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let concept = try await store.createEntity(.init(typeKey: "concept", label: "Computing"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let question = try await store.createObject(.init(typeKey: "question", properties: .init(properties: ["questionText": .string("Who was Ada?")]), questionStatus: .answered, answerText: "A pioneer"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let definition = try await store.createObject(.init(typeKey: "definition", definitionText: "A computing pioneer", term: "Ada", subjectEntityID: person.entity.id), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let page = try await repository.create(title: "Inspection", body: "Ada in London"), second = try await repository.create(title: "Another occurrence", body: "Ada\n\nAda")
        let initial = try await store.loadSemanticPage(pageID: page.id)
        let identities = [EntityIdentity(kind: "person", id: person.entity.id), .init(kind: "place", id: place.entity.id), .init(kind: "concept", id: concept.entity.id), .init(kind: "question", id: question.object.id), .init(kind: "definition", id: definition.object.id)]
        let annotations = try identities.map { identity in
            SemanticAnnotation(location: .inline(pageID: page.id, blockID: initial.snapshot.document.blocks[0].id, target: try InlineAnnotationTarget(text: "Ada in London", range: .init(location: 0, length: 3), revision: initial.snapshot.revision.token)), referent: .init(identity: identity), designation: identity.kind, expectedRevision: initial.snapshot.revision.token)
        }
        let saved = try await store.saveSemanticPage(.init(pageID: page.id, document: initial.snapshot.document, annotations: annotations), condition: .replace(expected: initial.snapshot.revision), expectedObjectRevisions: [question.object.id: question.revision, definition.object.id: definition.revision], expectedEntityRevisions: [person.entity.id: person.revision, place.entity.id: place.revision, concept.entity.id: concept.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let other = try await store.loadSemanticPage(pageID: second.id)
        let occurrence = SemanticAnnotation(location: .inline(pageID: second.id, blockID: other.snapshot.document.blocks.last(where: { $0.text == "Ada" })!.id, target: try InlineAnnotationTarget(text: "Ada", range: .init(location: 0, length: 3), revision: other.snapshot.revision.token)), referent: .init(identity: identities[0]), designation: "person", expectedRevision: other.snapshot.revision.token)
        _ = try await store.saveSemanticPage(.init(pageID: second.id, document: other.snapshot.document, annotations: [occurrence]), condition: .replace(expected: other.snapshot.revision), expectedObjectRevisions: [:], expectedEntityRevisions: [person.entity.id: person.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local"); model.persistSecurityScopedBookmark = false
        await model.open(root, create: false); model.select(page.id)
        for _ in 0..<100 { if model.currentNote?.id == page.id { break }; try await Task.sleep(for: .milliseconds(10)) }
                let parent = RichArticleView(text: SummarizedArticleView(model: model).editorText, editable: true, locked: false, action: nil,
            onWikiLink: { _ in }, noteID: page.id, vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID,
            onSemanticLoad: model.configureSemanticEditor, annotationChoices: model.annotationChoices, onAnnotate: model.annotateSelection,
            onInspectAssociation: model.inspectSemanticAssociation, onSemanticSelection: model.semanticSelectionChanged)
        let (coordinator, view, window) = editor(parent)
        defer { window.close(); model.flushEditorPublication = nil }
        model.flushEditorPublication = { [weak coordinator] in coordinator?.flushPublication() }
        for _ in 0..<100 { if coordinator.session.semanticEdit != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(coordinator.session.semanticEdit != nil)
        await model.refreshSemanticInspection(pageID: page.id)
        #expect(model.semanticInspectionRecords.count == 5)
        let personRow = try #require(model.semanticInspectionRecords.first { $0.id == annotations[0].id })
        #expect(personRow.target.title == "Ada" && personRow.occurrences.count == 2)
        if case .entity(let entity) = personRow.target { #expect(entity.entity.description == "A pioneer" && entity.entity.aliases.map(\.label) == ["Countess"]) }
        let questionRow = try #require(model.semanticInspectionRecords.first { $0.id == annotations[3].id })
        #expect(questionRow.target.title == "Who was Ada?")
        if case .object(let object) = questionRow.target { #expect(object.object.questionStatus == .answered && object.object.answerText == "A pioneer") }
        let definitionRow = try #require(model.semanticInspectionRecords.first { $0.id == annotations[4].id })
        #expect(definitionRow.subject?.entity.id == person.entity.id)
        model.inspectSemanticAssociation(personRow.id)
        #expect(model.semanticInspectionFocusID == personRow.id)
        #expect(await model.saveInspectedTarget(personRow.target, name: "Ada Lovelace", detail: "Shared description", answered: false, answer: ""))
        #expect(try await store.loadEntity(id: person.entity.id).entity.label == "Ada Lovelace")
        #expect(try await store.loadSemanticPage(pageID: page.id).annotations == saved.annotations)
        #expect(try await store.loadSemanticPage(pageID: second.id).annotations[0].annotation.id == occurrence.id)
        #expect(model.semanticInspectionRecords.first { $0.id == personRow.id }?.target.title == "Ada Lovelace")
        #expect(!(await model.saveInspectedTarget(personRow.target, name: "Stale overwrite", detail: "", answered: false, answer: "")))
        #expect(try await store.loadEntity(id: person.entity.id).entity.label == "Ada Lovelace")
        #expect(await model.saveInspectedTarget(questionRow.target, name: "Who was Ada Lovelace?", detail: "", answered: true, answer: "A computing pioneer"))
        #expect(try await store.loadObject(id: question.object.id).object.answerText == "A computing pioneer")
        #expect(await model.saveInspectedTarget(definitionRow.target, name: "Ada Lovelace", detail: "A pioneer of computing", answered: false, answer: ""))
        let editedDefinition = try await store.loadObject(id: definition.object.id)
        #expect(editedDefinition.object.term == "Ada Lovelace" && editedDefinition.object.definitionText == "A pioneer of computing")
        #expect(editedDefinition.object.subjectEntityID == person.entity.id)
        #expect(await model.replaceInspectedAssociation(personRow.id, choice: .entity(place)))
        let changed = try await store.loadSemanticPage(pageID: page.id)
        #expect(changed.annotations.first { $0.annotation.id == personRow.id }?.annotation.referent.identity.id == place.entity.id)
        #expect(try await store.loadEntity(id: person.entity.id).entity.label == "Ada Lovelace")
        #expect(await model.removeInspectedAssociation(personRow.id))
        #expect(try await store.loadSemanticPage(pageID: page.id).annotations.first { $0.annotation.id == personRow.id }?.annotation.anchorDisposition == .deleted)
        #expect(try await store.loadEntity(id: place.entity.id).entity.lifecycle == .live)
        view.undoManager?.undo()
        #expect(await model.saveCurrent())
        #expect(try await store.loadSemanticPage(pageID: page.id).annotations.first { $0.annotation.id == personRow.id }?.annotation.anchorDisposition == .resolved)
        #expect(await model.navigateSemanticOccurrence(occurrence))
        #expect(model.currentNote?.id == second.id)
        coordinator.parent.noteID = second.id; coordinator.parent.editable = false
        coordinator.load(model.body)
        for _ in 0..<100 { if model.pendingSemanticOccurrence == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let intendedBlock = try #require(occurrence.location.blockID)
        let intendedRange = try #require(coordinator.rangeIndex?.range(for: intendedBlock))
        #expect(view.selectedRange() == NSRange(location: intendedRange.location, length: 3))
        #expect(intendedRange.location > 0)
        #expect(model.semanticInspectionFocusID == occurrence.id)
        await model.refreshSemanticInspection(pageID: second.id)
        let shared = try #require(model.semanticInspectionRecords.first)
        #expect(shared.target.title == "Ada Lovelace")
        #expect(shared.occurrencePreviews.contains { $0.pageTitle == second.title && $0.canNavigate && $0.context == "Ada" })
        let beforeRemoval = try await store.loadSemanticPage(pageID: second.id)
        var remove = beforeRemoval.edit; remove.annotations[0].anchorDisposition = .deleted
        let currentPerson = try await store.loadEntity(id: person.entity.id)
        _ = try await store.saveSemanticPage(remove, condition: .replace(expected: beforeRemoval.snapshot.revision), expectedObjectRevisions: [:], expectedEntityRevisions: [person.entity.id: currentPerson.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        #expect(!(await model.navigateSemanticOccurrence(occurrence)))
        #expect(model.semanticInspectionError?.contains("Deleted association") == true)
        await model.refreshSemanticInspection(pageID: second.id)
        #expect(model.semanticInspectionRecords.first?.occurrencePreviews.contains { $0.id == occurrence.id && $0.state == .deleted } == true)
        #expect(try await store.occurrences(entityID: person.entity.id).contains { $0.annotation.id == occurrence.id })
        #expect(await model.lockVault())
        #expect(model.semanticInspectionRecords.isEmpty && model.semanticInspectionPageID == nil)
    }

    @Test func semanticDraftSurvivesRapidRevisitAndSuccessorSave() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-navigation-\(UUID())")
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let first = try await repository.create(title: "Annotated", body: "Ada Lovelace")
        let second = try await repository.create(title: "Destination", body: "Other page")
        let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(first.id);         func parent() -> RichArticleView {
            RichArticleView(document: SummarizedArticleView(model: model).editorDocument,
                editable: true, locked: false, action: nil, onWikiLink: { _ in },
                noteID: first.id, vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID,
                onSnapshot: model.acceptEditorSnapshot,
                onSemanticLoad: model.configureSemanticEditor, annotationChoices: model.annotationChoices,
                onAnnotate: model.annotateSelection)
        }
        let (original, view, window) = editor(parent())
        defer { window.close(); model.flushEditorPublication = nil }
        model.flushEditorPublication = { original.flushPublication() }
        for _ in 0..<100 {
            if original.session.semanticEdit != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(original.session.semanticEdit != nil)
        view.setSelectedRange(NSRange(location: 0, length: 3))
        let selection = try #require(original.annotationSelection())
        try await model.annotateSelection(original, selection.0, selection.1,
            .newObject(typeKey: "definition", text: "Pioneer"), original.session.revision)
        let entered = AsyncStream.makeStream(of: Void.self), release = AsyncStream.makeStream(of: Void.self)
        defer { release.continuation.finish() }
        var preparationCount = 0
        model.pageSavePreparation = {
            preparationCount += 1
            if preparationCount == 1 {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
        }
        model.select(second.id)
        for await _ in entered.stream { break }
        model.select(first.id);         let (resumed, _, resumedWindow) = editor(parent())
        defer { resumedWindow.close() }
        model.flushEditorPublication = { resumed.flushPublication() }
        #expect(resumed.session.semanticEdit?.annotations.count == 1)
        #expect(resumed.session.pageRevision == original.session.pageRevision)
        let block = try #require(resumed.document.blocks.first?.id)
        resumed.session.updateRuns(block, runs: [RichRun("Ada Lovelace extended")], selection: .init(location: 0, length: 0))
        resumed.flushPublication()
        model.select(second.id)
        release.continuation.yield(())
        #expect(await model.flushPendingEdits())
        let saved = try await repository.sqliteBlockStore.loadSemanticPage(pageID: first.id)
        #expect(saved.snapshot.document.blocks.first?.text == "Ada Lovelace extended")
        #expect(saved.annotations.count == 1 && saved.objects.count == 1)
        #expect(model.pageSaveFailures.isEmpty)
        #expect(await model.closeVault())
    }

}

@Suite("Structured editor publication", .serialized)
@MainActor struct StructuredEditorPublicationTests {
    @Test func revisionsAndGenerationsGuardStructuredRecoveryAndSave() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("structured-editor-" + UUID().uuidString)
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let page = try await repository.create(title: "Structured snapshot", body: "Original")
        let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(page.id)
        for _ in 0..<100 {
            if model.currentNote?.id == page.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.currentNote?.id == page.id)
        let session = EditorSession(document: model.editorDocument, identity: model.editorIdentity)
        model.registerEditorSession(session)
        let id = try #require(session.document.blocks.first?.id)
        session.updateRuns(id, runs: [RichRun("First revision")], selection: .init(location: 2, length: 0))
        let old = session.snapshot()
        var rich = session.document
        rich.blocks[0].children = [EditorBlock(kind: .callout, runs: [RichRun("Nested 😀")])]
        rich.setAISummary("Preserved summary")
        session.replaceDocument(rich)
        let latest = session.snapshot()
        model.acceptEditorSnapshot(latest)
        model.acceptEditorSnapshot(old)
        #expect(model.editorDocument == latest.document)
        #expect(model.dirty)

        model.title = ""
        #expect(!(await model.saveCurrent()))
        let draft = try #require(model.recoveredDrafts.first(where: { $0.id == page.id }))
        #expect(draft.document == latest.document)
        #expect(draft.body.isEmpty)
        let bytes = try JSONEncoder().encode(draft)
        #expect(try JSONDecoder().decode(DraftRecord.self, from: bytes).document == latest.document)

        model.title = page.title
        #expect(await model.saveCurrent())
        let saved = try #require(try await repository.scan().notes.first(where: { $0.id == page.id }))
        #expect(saved.document?.blocks == latest.document.blocks)
        #expect(!model.dirty)

        session.load(model.editorDocument, identity: model.editorIdentity, selection: .init(location: 0, length: 0))
        model.registerEditorSession(session)
        model.acceptEditorSnapshot(latest)
        #expect(!model.dirty)
        #expect(await model.lockVault())
        model.acceptEditorSnapshot(latest)
        #expect(model.currentNote == nil)
    }
}
