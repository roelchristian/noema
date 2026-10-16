import Foundation
import SQLite3
import Testing
@testable import VaultCore

private func knowledgeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-sqlite-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func knowledgeSQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw VaultError.storage("Test open failed") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(database))) }
}
@Test func knowledgeSQLiteIdentityAliasesRelationsAndLifecycleSurviveReopen() async throws {
    let root = try knowledgeRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: url, vaultID: vaultID)
    var snapshots: [KnowledgeEntitySnapshot] = []
    for entity in KnowledgeFixtures.entities {
        let result = try await store.createEntity(entity, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        snapshots.append(result.value)
        #expect(result.vaultRevision == (try await store.canonicalVaultRevision()))
        #expect(try await store.committedKnowledgeEntityOperation(id: result.operationID) == result)
    }
    #expect(try await store.searchEntities(query: "Napoleon", limit: 10).count == 2)
    let source = snapshots[0], target = snapshots[1]
    let relation = try await store.createRelation(.init(sourceID: source.entity.id, targetID: target.entity.id), expectedSource: source.revision, expectedTarget: target.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(try await store.committedKnowledgeRelationOperation(id: relation.operationID) == relation)
    let renamed = try await store.updateEntity(id: source.entity.id, patch: .init(label: "Napoleon I"), expected: source.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(try await store.queryRelations(entityID: source.entity.id, direction: .outgoing).first?.relation == relation.value.relation)
    let removed = try await store.transitionEntity(id: source.entity.id, to: .tombstoned, expected: renamed.value.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(try await store.resolveEntity(id: source.entity.id) == .tombstoned(removed.value))
    await #expect(throws: KnowledgeStoreError.tombstoned(source.entity.id)) {
        try await store.updateEntity(id: source.entity.id, patch: .init(label: "invalid"), expected: removed.value.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    }
    let restored = try await store.transitionEntity(id: source.entity.id, to: .live, expected: removed.value.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let alias = KnowledgeAlias(label: "Emperor")
    let aliased = try await store.addAlias(entityID: source.entity.id, alias: alias, expected: restored.value.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(aliased.value.revision != restored.value.revision)
    #expect(try await store.searchEntities(query: "Emperor", limit: 1).first?.entity.id == source.entity.id)
    let unaliased = try await store.removeAlias(entityID: source.entity.id, aliasID: alias.id, expected: aliased.value.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    try await store.close()
    let reopen = try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopen.loadEntity(id: source.entity.id) == unaliased.value)
    #expect(try await reopen.queryRelations(entityID: source.entity.id, direction: .outgoing) == [relation.value])
    #expect(try await reopen.resolveEntity(id: UUID()) != .live(unaliased.value))
    try await reopen.close()
}
@Test func knowledgeSQLiteStaleWritesAndInjectedRollbackLeaveNoEvidence() async throws {
    let root = try knowledgeRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    let store = try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: url, vaultID: UUID())
    let beforeVault = try await store.canonicalVaultRevision()
    let created = try await store.createEntity(KnowledgeFixtures.entities[0], expectedVaultRevision: beforeVault, operationID: UUID())
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await store.createEntity(KnowledgeFixtures.entities[1], expectedVaultRevision: beforeVault, operationID: UUID())
    }
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await store.updateEntity(id: created.value.entity.id, patch: .init(label: "stale"), expected: beforeVault, expectedVaultRevision: created.vaultRevision, operationID: UUID())
    }
    try knowledgeSQL(url, "CREATE TRIGGER fail_knowledge_evidence BEFORE INSERT ON knowledge_operations BEGIN SELECT RAISE(ABORT,'injected rollback'); END")
    let failedOperation = UUID(), alias = KnowledgeAlias(label: "must roll back")
    await #expect(throws: VaultError.self) {
        try await store.addAlias(entityID: created.value.entity.id, alias: alias, expected: created.value.revision, expectedVaultRevision: created.vaultRevision, operationID: failedOperation)
    }
    #expect(try await store.loadEntity(id: created.value.entity.id) == created.value)
    #expect(try await store.canonicalVaultRevision() == created.vaultRevision)
    #expect(try await store.committedKnowledgeEntityOperation(id: failedOperation) == nil)
    try await store.close()
}
@Test func knowledgeSQLiteSchemaThreeAndCapabilityMismatchRejectWithoutUpgrade() async throws {
    let root = try knowledgeRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let oldURL = root.appendingPathComponent("old.sqlite"), vaultID = UUID()
    let old = try VaultStorageProvider.plaintext.makeCanonicalStagingStore(url: oldURL, vaultID: vaultID)
    let revision = try await old.canonicalVaultRevision()
    await #expect(throws: KnowledgeStoreError.transitionRequired) {
        try await old.createEntity(KnowledgeFixtures.entities[0], expectedVaultRevision: revision, operationID: UUID())
    }
    #expect(try await old.canonicalVaultRevision() == revision)
    try await old.close()
    #expect(throws: VaultError.self) { try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: oldURL, vaultID: vaultID, createIfMissing: false) }
    let unchanged = try VaultStorageProvider.plaintext.makeCanonicalStagingStore(url: oldURL, vaultID: vaultID, createIfMissing: false)
    #expect(try await unchanged.canonicalVaultRevision() == revision)
    try await unchanged.close()
    let url = root.appendingPathComponent("knowledge.sqlite")
    let knowledge = try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: url, vaultID: vaultID)
    try await knowledge.close()
    try knowledgeSQL(url, "UPDATE vault_state SET required_capabilities='[\"canonicalMetadataV1\"]'")
    #expect(throws: VaultError.self) { try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: url, vaultID: vaultID, createIfMissing: false) }
    var declaration = VaultCanonicalStorageDeclaration(); declaration.schemaVersion = 4; declaration.requiredCapabilities = SQLiteBlockStore.knowledgeRequiredCapabilities
    #expect(!declaration.isSupported)
    declaration.requiredCapabilities.reverse(); #expect(!declaration.isSupported)
}

@Test func knowledgeEventAnnotationSurvivesOldRegistrySaveAndReopen() async throws {
    let root = try knowledgeRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID(), pageID = UUID()
    let fresh = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    try await fresh.close()
    // Simulate a pre-Event schema-5 vault without upgrading its admission contract.
    try knowledgeSQL(url, "DELETE FROM knowledge_entity_types WHERE key='event'")
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    let event = KnowledgeEntity(typeKey: "event", label: "The launch", aliases: [.init(label: "Launch")], properties: .init(properties: ["future": .string("preserved")]))
    let created = try await store.createEntity(event, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let block = EditorBlock(runs: [RichRun("The launch happened.")])
    let page = try await store.save(.init(blocks: [block]), pageID: pageID, condition: .createOnly)
    let annotation = SemanticAnnotation(location: .inline(pageID: pageID, blockID: block.id, target: try InlineAnnotationTarget(text: block.text, range: .init(location: 0, length: 10), revision: page.revision.token)), referent: .init(identity: .init(kind: "event", id: event.id)), designation: "event", expectedRevision: page.revision.token)
    let saved = try await store.saveSemanticPage(.init(pageID: pageID, document: page.document, annotations: [annotation]), condition: .replace(expected: page.revision), expectedObjectRevisions: [:], expectedEntityRevisions: [event.id: created.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(saved.snapshot.document.block(block.id)?.text == block.text)
    #expect(try await store.occurrences(entityID: event.id).map(\.annotation.id) == [annotation.id])
    try await store.close()
    let reopen = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopen.loadEntity(id: event.id) == created)
    #expect(try await reopen.loadSemanticPage(pageID: pageID) == saved)
    #expect(try await reopen.occurrences(entityID: event.id).first?.annotation.referent.disposition == .live)
    #expect(try await reopen.searchEntities(query: "Launch", limit: 10).first == created)
    try await reopen.close()
}

@Test func knowledgeEventRegistryInsertionRollsBackOnFailedCreation() async throws {
    let root = try knowledgeRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    try knowledgeSQL(url, "DELETE FROM knowledge_entity_types WHERE key='event'; CREATE TRIGGER fail_event BEFORE INSERT ON knowledge_entities BEGIN SELECT RAISE(ABORT,'injected failure'); END")
    let revision = try await store.canonicalVaultRevision()
    await #expect(throws: VaultError.self) {
        try await store.createEntity(.init(typeKey: "event", label: "Launch"), expectedVaultRevision: revision, operationID: UUID())
    }
    #expect(try await store.canonicalVaultRevision() == revision)
    // This trigger fails if the registry row escaped the failed entity transaction.
    try knowledgeSQL(url, "DROP TRIGGER fail_event; CREATE TRIGGER registry_was_retained BEFORE INSERT ON knowledge_entity_types WHEN EXISTS(SELECT 1 FROM knowledge_entity_types WHERE key='event') BEGIN SELECT RAISE(ABORT,'registry leaked'); END")
    _ = try await store.createEntity(.init(typeKey: "event", label: "Retry"), expectedVaultRevision: revision, operationID: UUID())
    try await store.close()
}

@Test func knowledgeCreativeWorkRegistryAndIdentitySurviveReopen() async throws {
    let root = try knowledgeRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    try knowledgeSQL(url, "DELETE FROM knowledge_entity_types WHERE key='creativeWork'")
    let entity = KnowledgeEntity(typeKey: "creativeWork", label: "A work")
    let created = try await store.createEntity(entity, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    try await store.close()
    let reopened = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopened.loadEntity(id: entity.id) == created)
    #expect(try JSONDecoder().decode(KnowledgeEntity.self, from: JSONEncoder().encode(entity)) == entity)
    #expect(KnowledgeEntityType.initial.map(\.key) == ["person", "place", "concept", "event", "creativeWork"])
    try await reopened.close()
}
