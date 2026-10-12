import Foundation
import Testing
@testable import VaultCore

struct SemanticRecoveryTests {
    @Test @MainActor func stagedObjectRecoveryPublishesFreshPageAndObjectTogether() async throws {
        let (root, repository) = try await CanonicalRepositoryTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await repository.create(title: "Original", body: "What is Ada?")
        let store = repository.sqliteBlockStore
        let baseline = try await store.loadSemanticPage(pageID: note.id)
        let session = EditorSession()
        session.load(baseline, identity: .init(pageID: note.id), selection: .init(location: 0, length: 4))
        let object = SemanticObject(typeKey: "question", properties: .init(properties: ["questionText": .string("What is Ada?")]))
        try session.stageAnnotationObject(object)
        try session.applyAnnotation(.create(blockID: baseline.snapshot.document.blocks[0].id, range: .init(location: 0, length: 4), referent: .init(identity: .init(kind: "question", id: object.id)), designation: "question"), expectedLocalRevision: session.revision)
        let draft = DraftRecord(note: note, title: note.title, body: note.body, tags: ["recovered"], semanticEdit: session.semanticEdit)
        let decoded = try JSONDecoder().decode(DraftRecord.self, from: JSONEncoder().encode(draft))
        let recovered = try await repository.recoverSemanticDraft(decoded)
        let saved = try await store.loadSemanticPage(pageID: recovered.id)
        #expect(recovered.id != note.id && recovered.tags == ["recovered"])
        #expect(saved.annotations.count == 1 && saved.objects.count == 1)
        #expect(saved.objects[0].object.id != object.id)
        #expect(saved.objects[0].object.properties.properties["questionText"] == .string("What is Ada?"))
        #expect(saved.annotations[0].annotation.referent.identity.id == saved.objects[0].object.id)
        #expect(saved.snapshot.document.blocks[0].text == "What is Ada?")
        #expect(try await store.loadSemanticPage(pageID: note.id).annotations.isEmpty)
        await #expect(throws: KnowledgeStoreError.self) { _ = try await store.loadObject(id: object.id) }
        #expect(!FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects.contains { ($0 as? URL)?.pathExtension == "md" })
        try await store.close()
        let (_, _, reopened) = try await VaultSessionManager().openRepository(root: root)
        let reopenedPage = try await reopened.sqliteBlockStore.loadSemanticPage(pageID: recovered.id)
        #expect(reopenedPage.annotations == saved.annotations)
        #expect(reopenedPage.objects == saved.objects)
    }

    @Test @MainActor func semanticEditorStaleWritePublishesNoObjectAndUndoRedoReusesPublishedIdentity() async throws {
        let (root, repository) = try await CanonicalRepositoryTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await repository.create(title: "Editor", body: "Ada")
        let store = repository.sqliteBlockStore
        let initial = try await store.loadSemanticPage(pageID: note.id)
        let session = EditorSession()
        session.load(initial, identity: .init(pageID: note.id), selection: .init(location: 0, length: 3))
        let before = session.snapshot(), object = SemanticObject(typeKey: "definition", definitionText: "A person", term: "Ada")
        try session.stageAnnotationObject(object)
        try session.applyAnnotation(.create(blockID: initial.snapshot.document.blocks[0].id, range: .init(location: 0, length: 3), referent: .init(identity: .init(kind: "definition", id: object.id)), designation: "definition"), expectedLocalRevision: session.revision)
        let annotated = session.snapshot(), edit = try #require(annotated.semanticEdit)
        let vault = try await store.canonicalVaultRevision()
        await #expect(throws: (any Error).self) {
            _ = try await repository.saveSemantic(note: note, title: "Changed", tags: [], edit: edit, expectedPageRevision: .init(token: Data("stale".utf8)), expectedEntityRevisions: [:], expectedObjectRevisions: [:], expectedVaultRevision: vault)
        }
        #expect(try await store.loadSemanticPage(pageID: note.id) == initial)
        await #expect(throws: KnowledgeStoreError.self) { _ = try await store.loadObject(id: object.id) }
        let (savedNote, saved) = try await repository.saveSemantic(note: note, title: "Changed", tags: [], edit: edit, expectedPageRevision: initial.snapshot.revision, expectedEntityRevisions: [:], expectedObjectRevisions: [:], expectedVaultRevision: vault)
        #expect(session.acceptSemanticPublication(saved, for: annotated))
        session.restore(before, name: "Undo")
        let undone = try #require(session.semanticEdit)
        let (undoNote, undoPage) = try await repository.saveSemantic(note: savedNote, title: savedNote.title, tags: [], edit: undone, expectedPageRevision: saved.snapshot.revision, expectedEntityRevisions: [:], expectedObjectRevisions: session.expectedObjectRevisions, expectedVaultRevision: store.canonicalVaultRevision())
        #expect(session.acceptSemanticPublication(undoPage, for: session.snapshot()))
        #expect(undoPage.annotations.allSatisfy { $0.annotation.anchorDisposition == .deleted })
        #expect(try await store.loadObject(id: object.id).object.lifecycle == .live)
        session.restore(annotated, name: "Redo")
        let redo = try #require(session.semanticEdit)
        #expect(redo.objects.isEmpty)
        let (_, redoPage) = try await repository.saveSemantic(note: undoNote, title: undoNote.title, tags: [], edit: redo, expectedPageRevision: undoPage.snapshot.revision, expectedEntityRevisions: [:], expectedObjectRevisions: session.expectedObjectRevisions, expectedVaultRevision: store.canonicalVaultRevision())
        #expect(redoPage.annotations.first?.annotation.anchorDisposition == .resolved)
        #expect(redoPage.objects.first?.object.id == object.id)
    }
}
