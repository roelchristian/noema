import Foundation
import SQLite3
import Testing
@testable import VaultCore

private func semanticTestSQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw VaultError.storage("Test open failed") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(database))) }
}

private struct SemanticBoundaryFixture {
    let root: URL
    let url: URL
    let store: SQLiteBlockStore
    let entity: KnowledgeEntitySnapshot
    let object: SemanticObjectSnapshot
    let page: SemanticPageSnapshot
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("blocks.sqlite")
        let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: UUID())
        let entity = try await store.createEntity(KnowledgeFixtures.entities[0], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let object = try await store.createObject(.init(typeKey: "question"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let block = EditorBlock(runs: [RichRun("Napoleon")]), pageID = UUID()
        let raw = try await store.save(BlockDocument(blocks: [block]), pageID: pageID, condition: .createOnly)
        let annotation = SemanticAnnotation(location: .wholeBlock(pageID: pageID, blockID: block.id), referent: .init(identity: .init(kind: "question", id: object.object.id)), designation: "question", expectedRevision: raw.revision.token)
        let page = try await store.saveSemanticPage(.init(pageID: pageID, document: raw.document, annotations: [annotation]), condition: .replace(expected: raw.revision), expectedObjectRevisions: [object.object.id: object.revision], expectedEntityRevisions: [:], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        return .init(root: root, url: url, store: store, entity: entity, object: object, page: page)
    }
    func edit() -> SemanticPageEdit {
        .init(pageID: page.snapshot.pageID, document: page.snapshot.document, annotations: page.annotations.map(\.annotation), expectedAnnotationRevisions: Dictionary(uniqueKeysWithValues: page.annotations.map { ($0.annotation.id, $0.revision) }))
    }
}

@Test func semanticCompoundFailureRollsBackContentObjectsAnnotationsVaultAndEvidence() async throws {
    let f = try await SemanticBoundaryFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let vault = try await f.store.canonicalVaultRevision(), operationID = UUID()
    var edit = f.edit(); edit.document.blocks[0].runs = [RichRun("Changed text")]
    var answered = f.object.object; answered.questionStatus = .answered; answered.answerText = "Answer"; edit.objects = [answered]
    try semanticTestSQL(f.url, "CREATE TRIGGER fail_semantic_evidence BEFORE INSERT ON knowledge_operations BEGIN SELECT RAISE(ABORT,'injected compound failure'); END")
    await #expect(throws: VaultError.self) {
        try await f.store.saveSemanticPage(edit, condition: .replace(expected: f.page.snapshot.revision), expectedObjectRevisions: [f.object.object.id: f.object.revision], expectedEntityRevisions: [:], expectedVaultRevision: vault, operationID: operationID)
    }
    #expect(try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID) == f.page)
    #expect(try await f.store.loadObject(id: f.object.object.id) == f.object)
    #expect(try await f.store.canonicalVaultRevision() == vault)
    try semanticTestSQL(f.url, "DROP TRIGGER fail_semantic_evidence")
    // Reusing the operation proves rollback did not publish idempotency evidence.
    _ = try await f.store.saveSemanticPage(edit, condition: .replace(expected: f.page.snapshot.revision), expectedObjectRevisions: [f.object.object.id: f.object.revision], expectedEntityRevisions: [:], expectedVaultRevision: vault, operationID: operationID)
    #expect(try await f.store.loadObject(id: f.object.object.id).object.answerText == "Answer")
    try await f.store.close()
}

@Test func semanticCrossPageAnnotationIdentityCannotBeStolen() async throws {
    let f = try await SemanticBoundaryFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let otherID = UUID(), otherBlock = EditorBlock(runs: [RichRun("Other page")])
    let other = try await f.store.save(BlockDocument(blocks: [otherBlock]), pageID: otherID, condition: .createOnly)
    let vault = try await f.store.canonicalVaultRevision()
    var stolen = f.page.annotations[0].annotation; stolen.location = .wholeBlock(pageID: otherID, blockID: otherBlock.id)
    await #expect(throws: (any Error).self) {
        try await f.store.saveSemanticPage(.init(pageID: otherID, document: other.document, annotations: [stolen]), condition: .replace(expected: other.revision), expectedObjectRevisions: [f.object.object.id: f.object.revision], expectedEntityRevisions: [:], expectedVaultRevision: vault, operationID: UUID())
    }
    #expect(try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID) == f.page)
    #expect(try await f.store.load(pageID: otherID) == other)
    #expect(try await f.store.canonicalVaultRevision() == vault)
    try await f.store.close()
}

@Test func semanticAffectedRecordAndVaultRevisionsAreRequiredAndScoped() async throws {
    let f = try await SemanticBoundaryFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let vault = try await f.store.canonicalVaultRevision()
    var edit = f.edit(); edit.objects = [f.object.object]
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await f.store.saveSemanticPage(edit, condition: .replace(expected: f.page.snapshot.revision), expectedObjectRevisions: [f.object.object.id: f.entity.revision], expectedEntityRevisions: [:], expectedVaultRevision: vault, operationID: UUID())
    }
    edit = f.edit(); edit.expectedAnnotationRevisions = [:]
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await f.store.saveSemanticPage(edit, condition: .replace(expected: f.page.snapshot.revision), expectedObjectRevisions: [f.object.object.id: f.object.revision], expectedEntityRevisions: [:], expectedVaultRevision: vault, operationID: UUID())
    }
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await f.store.saveSemanticPage(f.edit(), condition: .replace(expected: f.page.snapshot.revision), expectedObjectRevisions: [f.object.object.id: f.object.revision], expectedEntityRevisions: [:], expectedVaultRevision: f.entity.revision, operationID: UUID())
    }
    #expect(try await f.store.loadSemanticPage(pageID: f.page.snapshot.pageID) == f.page)
    #expect(try await f.store.canonicalVaultRevision() == vault)
    try await f.store.close()
}

@Test func semanticCorruptExistingObjectCannotBecomeCreateOnlyOverwrite() async throws {
    let f = try await SemanticBoundaryFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let vault = try await f.store.canonicalVaultRevision()
    try semanticTestSQL(f.url, "UPDATE semantic_objects SET payload='malformed' WHERE id='\(f.object.object.id.uuidString)'")
    await #expect(throws: (any Error).self) { try await f.store.loadObject(id: f.object.object.id) }
    await #expect(throws: (any Error).self) {
        try await f.store.createObject(f.object.object, expectedVaultRevision: vault, operationID: UUID())
    }
    #expect(try await f.store.canonicalVaultRevision() == vault)
    // The corruption itself remains preserved rather than replaced with a caller object.
    await #expect(throws: (any Error).self) { try await f.store.loadObject(id: f.object.object.id) }
    try await f.store.close()
}

@Test func semanticRelationalPayloadIdentityAndLifecycleShadowingRejects() async throws {
    for field in ["id", "typeKey", "lifecycle", "revision"] {
        let f = try await SemanticBoundaryFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        try semanticTestSQL(f.url, "UPDATE semantic_objects SET payload=json_set(CAST(payload AS TEXT),'$.\(field)','shadow') WHERE id='\(f.object.object.id.uuidString)'")
        await #expect(throws: (any Error).self) { try await f.store.loadObject(id: f.object.object.id) }
        try await f.store.close()
    }
}

@Test func semanticStandaloneAnnotationOwnerReferentCASAndCommitEvidence() async throws {
    let f = try await SemanticBoundaryFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let annotation = SemanticAnnotation(location: .entity(id: f.entity.entity.id), referent: .init(identity: .init(kind: "question", id: f.object.object.id)), designation: "question")
    let vault = try await f.store.canonicalVaultRevision(), operationID = UUID()
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await f.store.saveAnnotation(annotation, condition: .createOnly, expectedOwnerRevision: f.object.revision, expectedReferentRevision: f.object.revision, expectedVaultRevision: vault, operationID: UUID())
    }
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await f.store.saveAnnotation(annotation, condition: .createOnly, expectedOwnerRevision: f.entity.revision, expectedReferentRevision: f.entity.revision, expectedVaultRevision: vault, operationID: UUID())
    }
    let result = try await f.store.saveAnnotation(annotation, condition: .createOnly, expectedOwnerRevision: f.entity.revision, expectedReferentRevision: f.object.revision, expectedVaultRevision: vault, operationID: operationID)
    #expect(try await f.store.committedSemanticAnnotationOperation(id: operationID) == result)
    await #expect(throws: KnowledgeStoreError.identityConflict(annotation.id)) {
        try await f.store.saveAnnotation(annotation, condition: .createOnly, expectedOwnerRevision: f.entity.revision, expectedReferentRevision: f.object.revision, expectedVaultRevision: result.vaultRevision, operationID: UUID())
    }
    let deleted = try await f.store.transitionAnnotation(id: annotation.id, to: .deleted, expected: result.value.revision, expectedOwnerRevision: f.entity.revision, expectedVaultRevision: result.vaultRevision, operationID: UUID())
    #expect(deleted.value.annotation.anchorDisposition == .deleted)
    #expect(try await f.store.loadObject(id: f.object.object.id) == f.object)
    #expect(try await f.store.loadEntity(id: f.entity.entity.id) == f.entity)
    try await f.store.close()
}

@Test func semanticLegacyUnknownReferentAndOpaqueAnchorFieldsSurvivePlainSave() async throws {
    let f = try await SemanticBoundaryFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let pageID = UUID(), block = EditorBlock(runs: [RichRun("Unknown legacy anchor")])
    var target = try InlineAnnotationTarget(text: block.text, range: NSRange(location: 0, length: 7), revision: Data())
    target.unknownFields["futureAnchor"] = .object(["opaque": .string("kept")])
    var annotation = InlineAnnotation(pageID: pageID, blockID: block.id, designation: "futureDesignation", expectedRevision: Data(), target: target)
    annotation.targetEntity = .init(kind: "page", id: UUID())
    annotation.payload = .init(properties: ["unknownOptional": .array([.bool(true)])])
    var raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(annotation))
    if case .object(var fields) = raw { fields["futureLegacy"] = .string("opaque"); raw = .object(fields) }
    var document = BlockDocument(blocks: [block]); document.extensions = .init(requiredFeatures: ["annotationsV1"], properties: ["annotations": .array([raw])])
    let saved = try await f.store.save(document, pageID: pageID, condition: .createOnly)
    var stored = try await f.store.loadSemanticPage(pageID: pageID)
    #expect(stored.annotations[0].annotation.referent.disposition == .unresolved)
    #expect(stored.annotations[0].annotation.referent.identity == annotation.targetEntity)
    #expect(stored.annotations[0].annotation.unknownFields["futureLegacy"] == .string("opaque"))
    var styled = saved.document; var bold = InlineStyle(); bold.bold = true
    styled.update(block.id) { $0.runs = [RichRun(block.text, style: bold)] }
    _ = try await f.store.save(styled, pageID: pageID, condition: .replace(expected: saved.revision))
    stored = try await f.store.loadSemanticPage(pageID: pageID)
    #expect(stored.annotations[0].annotation.referent.disposition == .unresolved)
    #expect(stored.annotations[0].annotation.payload == annotation.payload)
    #expect(stored.annotations[0].annotation.unknownFields["futureLegacy"] == .string("opaque"))
    guard case .inline(_, _, let preserved) = stored.annotations[0].annotation.location else { Issue.record("Expected inline preserved location"); return }
    #expect(preserved.unknownFields == target.unknownFields)
    try await f.store.close()
}

@Test func semanticUnicodeInteriorAnchorRejectsWithoutCompoundPublication() async throws {
    let f = try await SemanticBoundaryFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
    let pageID = UUID(), block = EditorBlock(runs: [RichRun("e\u{301}👩🏽‍🚀")])
    let page = try await f.store.save(BlockDocument(blocks: [block]), pageID: pageID, condition: .createOnly)
    let vault = try await f.store.canonicalVaultRevision()
    var target = try InlineAnnotationTarget(text: block.text, range: NSRange(location: 0, length: 2), revision: page.revision.token)
    target.start = 1; target.quote = (block.text as NSString).substring(with: NSRange(location: 1, length: 1)); target.digest = InlineAnnotationTarget.evidence(quote: target.quote, revision: page.revision.token)
    let annotation = SemanticAnnotation(location: .inline(pageID: pageID, blockID: block.id, target: target), referent: .init(identity: .init(kind: "person", id: f.entity.entity.id)), designation: "person", expectedRevision: page.revision.token)
    await #expect(throws: PersistencePayloadError.self) {
        try await f.store.saveSemanticPage(.init(pageID: pageID, document: page.document, annotations: [annotation]), condition: .replace(expected: page.revision), expectedObjectRevisions: [:], expectedEntityRevisions: [f.entity.entity.id: f.entity.revision], expectedVaultRevision: vault, operationID: UUID())
    }
    #expect(try await f.store.load(pageID: pageID) == page)
    #expect(try await f.store.canonicalVaultRevision() == vault)
    try await f.store.close()
}
