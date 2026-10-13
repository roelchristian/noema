import Foundation
import Testing
import SQLite3
@testable import VaultCore

private struct SemanticLifecycleFixture {
    let root: URL
    let url: URL
    let vaultID: UUID
    let store: SQLiteBlockStore
    let person: KnowledgeEntitySnapshot
    let question: SemanticObjectSnapshot
    let page: SemanticPageSnapshot
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
        let store = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: vaultID)
        let person = try await store.createEntity(KnowledgeFixtures.entities[0], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        var object = SemanticObject(typeKey: "question", relatedEntityIDs: [person.entity.id])
        object.unknownFields["futureObject"] = .string("preserved")
        let question = try await store.createObject(object, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let block = EditorBlock(runs: [RichRun("Napoleon in Russia")]), pageID = UUID()
        let raw = try await store.save(BlockDocument(blocks: [block]), pageID: pageID, condition: .createOnly)
        var personAnnotation = SemanticAnnotation(location: .inline(pageID: pageID, blockID: block.id, target: try InlineAnnotationTarget(text: block.text, range: .init(location: 0, length: 8), revision: raw.revision.token)), referent: .init(identity: .init(kind: "person", id: person.entity.id)), designation: "person", expectedRevision: raw.revision.token)
        personAnnotation.unknownFields["futureAnnotation"] = .bool(true)
        let questionAnnotation = SemanticAnnotation(location: .wholeBlock(pageID: pageID, blockID: block.id), referent: .init(identity: .init(kind: "question", id: question.object.id)), designation: "question", expectedRevision: raw.revision.token)
        let page = try await store.saveSemanticPage(.init(pageID: pageID, document: raw.document, annotations: [personAnnotation, questionAnnotation]), condition: .replace(expected: raw.revision), expectedObjectRevisions: [question.object.id: question.revision], expectedEntityRevisions: [person.entity.id: person.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        return .init(root: root, url: url, vaultID: vaultID, store: store, person: person, question: question, page: page)
    }
    func save(_ edit: SemanticPageEdit, replacing page: SemanticPageSnapshot, objects: [UUID: BlockStoreRevision]? = nil) async throws -> SemanticPageSnapshot {
        try await store.saveSemanticPage(edit, condition: .replace(expected: page.snapshot.revision), expectedObjectRevisions: objects ?? [question.object.id: question.revision], expectedEntityRevisions: [person.entity.id: person.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    }
}

@Test func semanticPersistedPageAndBlockCopiesAllocateObjectsAndAnnotationsOnly() async throws {
    let f = try await SemanticLifecycleFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let copy = try f.page.edit.duplicatedPage(objects: [f.question])
    let copied = try await f.store.saveSemanticPage(copy, condition: .createOnly, expectedObjectRevisions: [:], expectedEntityRevisions: [f.person.entity.id: f.person.revision], expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(copied.snapshot.pageID != f.page.snapshot.pageID)
    #expect(copied.snapshot.document.blocks[0].id != f.page.snapshot.document.blocks[0].id)
    #expect(Set(copied.annotations.map { $0.annotation.id }).isDisjoint(with: Set(f.page.annotations.map { $0.annotation.id })))
    let copiedQuestion = try #require(try await f.store.objects(pageID: copy.pageID).first)
    #expect(copiedQuestion.object.id != f.question.object.id)
    #expect(copiedQuestion.object.relatedEntityIDs == [f.person.entity.id])
    #expect(copiedQuestion.object.unknownFields == f.question.object.unknownFields)
    #expect(copied.annotations.contains { $0.annotation.referent.identity.id == copiedQuestion.object.id })
    #expect(copied.annotations.contains { $0.annotation.referent.identity.id == f.person.entity.id })
    var blockEdit = f.page.edit
    _ = try blockEdit.duplicateBlock(f.page.snapshot.document.blocks[0].id, objects: [f.question], expectedRevision: f.page.snapshot.revision)
    let duplicated = try await f.save(blockEdit, replacing: f.page)
    #expect(duplicated.snapshot.document.blocks.count == 2 && duplicated.annotations.count == 4)
    #expect(try await f.store.objects(pageID: f.page.snapshot.pageID).count == 2)
    #expect(try await f.store.searchEntities(query: "", limit: 100).count == 1)
    #expect(try await f.store.loadEntity(id: f.person.entity.id) == f.person)
    try await f.store.close()
    let reopened = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    #expect(try await reopened.loadSemanticPage(pageID: copy.pageID) == copied)
    #expect(try await reopened.loadSemanticPage(pageID: f.page.snapshot.pageID) == duplicated)
    #expect(try await reopened.loadObject(id: copiedQuestion.object.id) == copiedQuestion)
    #expect(try await reopened.searchEntities(query: "", limit: 100).count == 1)
    try await reopened.close()
}

@Test func semanticTrashRestoreRebasesIndependentAnnotationsAndSupportsPersistedUndo() async throws {
    let f = try await SemanticLifecycleFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let vaultBefore = try await f.store.canonicalVaultRevision()
    let trashed = try await f.store.setTrashed(pageID: f.page.snapshot.pageID, expected: f.page.snapshot.revision, trashed: true)
    let inTrash = try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID)
    #expect(trashed == inTrash.snapshot)
    #expect(try await f.store.canonicalVaultRevision() != vaultBefore)
    #expect(inTrash.annotations.allSatisfy { $0.annotation.expectedRevision == inTrash.snapshot.revision.token })
    #expect(zip(f.page.annotations, inTrash.annotations).allSatisfy { $0.revision != $1.revision })
    let restored = try await f.store.setTrashed(pageID: f.page.snapshot.pageID, expected: trashed.revision, trashed: false)
    let current = try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID)
    #expect(current.snapshot == restored)
    #expect(current.annotations.allSatisfy { $0.annotation.expectedRevision == restored.revision.token })
    let edited = try await f.save(current.replacingText(in: current.snapshot.document.blocks[0].id, range: .init(location: 0, length: 0), with: [RichRun("Emperor ")]), replacing: current)
    let undo = try edited.edit.restoring(current, expectedRevision: edited.snapshot.revision)
    let undone = try await f.save(undo, replacing: edited)
    #expect(undone.snapshot.document.blocks[0].text == current.snapshot.document.blocks[0].text)
    #expect(undone.annotations.allSatisfy { $0.annotation.anchorDisposition == .resolved })
    #expect(Set(undone.annotations.map { $0.annotation.id }) == Set(current.annotations.map { $0.annotation.id }))
    #expect(undone.annotations.allSatisfy { $0.annotation.expectedRevision == undone.snapshot.revision.token })
    try await f.store.close()
}

@Test func semanticObjectTombstoneAndRestoreDoNotChangeAnchorDispositionOrIdentity() async throws {
    let f = try await SemanticLifecycleFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let dead = try await f.store.transitionObject(id: f.question.object.id, to: .tombstoned, expected: f.question.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
    let page = try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID)
    let occurrence = try #require(page.annotations.first { $0.annotation.referent.identity.id == f.question.object.id })
    #expect(occurrence.annotation.anchorDisposition == .resolved && occurrence.annotation.referent.disposition == .tombstoned)
    #expect(try await f.store.annotationsNeedingReview().contains { $0.annotation.id == occurrence.annotation.id })
    #expect(try await f.store.questions(entityID: f.person.entity.id, association: .explicit).first?.object.lifecycle == .tombstoned)
    #expect(try await f.store.questions(entityID: f.person.entity.id, association: .derivedOccurrences).first?.object.id == f.question.object.id)
    await #expect(throws: KnowledgeStoreError.tombstoned(f.question.object.id)) { try await f.store.updateObject(id: f.question.object.id, patch: .init(answerText: "unsafe edit"), expected: dead.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()) }
    let live = try await f.store.transitionObject(id: f.question.object.id, to: .live, expected: dead.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(live.object.id == f.question.object.id && live.object.relatedEntityIDs == f.question.object.relatedEntityIDs)
    #expect(live.object.unknownFields == f.question.object.unknownFields)
    #expect(try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID).annotations.allSatisfy { $0.annotation.anchorDisposition == .resolved && $0.annotation.referent.disposition == .live })
    try await f.store.close()
}

@MainActor @Test func semanticLeasedStoreRevokesQueriesAndWritesWithoutDeletingAuthority() async throws {
    let f = try await SemanticLifecycleFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.close()
    let manager = VaultSessionManager()
    let session = try await manager.open(root: f.root) { _ in f.vaultID }
    let store = try SQLiteBlockStore(url: f.url, sessionLease: session.lease, accessGate: manager.accessGate, canonicalVaultID: f.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities, schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
    #expect(try await store.loadSemanticPage(pageID: f.page.snapshot.pageID) == f.page)
    try await manager.lock()
    await #expect(throws: VaultAccessError.self) { try await store.loadSemanticPage(pageID: f.page.snapshot.pageID) }
    await #expect(throws: VaultAccessError.self) { try await store.questions(entityID: f.person.entity.id, association: .explicit) }
    await #expect(throws: VaultAccessError.self) { try await store.updateObject(id: f.question.object.id, patch: .init(answerText: "denied"), expected: f.question.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()) }
    try await store.close()
    let reopened = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    #expect(try await reopened.loadSemanticPage(pageID: f.page.snapshot.pageID) == f.page)
    #expect(try await reopened.loadObject(id: f.question.object.id) == f.question)
    try await reopened.close()
}

@Test func semanticPlainStyledSaveRebasesWholeBlockAlongsideInlineBeforeCompoundEdit() async throws {
    let f = try await SemanticLifecycleFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    var document = f.page.snapshot.document
    var style = InlineStyle(); style.bold = true
    document.update(document.blocks[0].id) { $0.runs = [RichRun($0.text, style: style)] }
    let saved = try await f.store.save(document, pageID: f.page.snapshot.pageID, condition: .replace(expected: f.page.snapshot.revision))
    let semantic = try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID)
    #expect(semantic.snapshot == saved)
    #expect(semantic.annotations.allSatisfy { $0.annotation.expectedRevision == saved.revision.token })
    #expect(semantic.annotations.allSatisfy { $0.annotation.anchorDisposition == .resolved })
    let edited = try await f.save(semantic.replacingText(in: document.blocks[0].id, range: .init(location: 0, length: 0), with: [RichRun("Emperor ")]), replacing: semantic)
    #expect(edited.annotations.allSatisfy { $0.annotation.anchorDisposition == .resolved })
    #expect(edited.snapshot.document.blocks[0].text == "Emperor Napoleon in Russia")
    try await f.store.close()
}

@Test func semanticStaleAnchorsStillRejectUnknownVersionsAndRequiredPayloadsAtomically() async throws {
    let f = try await SemanticLifecycleFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let vault = try await f.store.canonicalVaultRevision()
    for variant in 0..<4 {
        var edit = f.page.edit
        let index = try #require(edit.annotations.firstIndex { if case .inline = $0.location { return true }; return false })
        edit.annotations[index].anchorDisposition = .stale
        if case .inline(let page, let block, var target) = edit.annotations[index].location {
            if variant == 0 { target.version = 99 }
            if variant == 1 { target.prefix = String(repeating: "x", count: 65) }
            edit.annotations[index].location = .inline(pageID: page, blockID: block, target: target)
        }
        if variant == 2 { edit.annotations[index].payload = .init(requiredFeatures: ["futureRequired"]) }
        if variant == 3 { edit.annotations[index].referent.payload = .init(version: 99) }
        await #expect(throws: (any Error).self) { try await f.save(edit, replacing: f.page) }
        #expect(try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID) == f.page)
        #expect(try await f.store.canonicalVaultRevision() == vault)
    }
    try await f.store.close()
}

private func lifecycleSQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw VaultError.storage("Test SQLite open failed") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(database))) }
}

@Test func semanticRegistryDescriptorMalformationAndUnknownRequiredMetadataDenyAdmission() async throws {
    for descriptor in ["malformed", "{\"metadata\":{\"version\":1,\"requiredFeatures\":[\"futureRequired\"],\"properties\":{}}}", "{\"metadata\":{\"version\":99,\"properties\":{}}}"] {
        let f = try await SemanticLifecycleFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.store.close()
        try lifecycleSQL(f.url, "UPDATE semantic_object_types SET descriptor='\(descriptor)' WHERE key='question'")
        #expect(throws: (any Error).self) { try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false) }
    }
}
