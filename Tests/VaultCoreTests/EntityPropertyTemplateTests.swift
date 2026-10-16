import Foundation
import SQLite3
import Testing
@testable import VaultCore

private struct TemplateFixture {
    let root: URL
    let url: URL
    let vaultID: UUID
    let store: SQLiteBlockStore
}

private func templateFixture() throws -> TemplateFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("entity-template-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeTemplateStagingStore(url: url, vaultID: vaultID)
    return .init(root: root, url: url, vaultID: vaultID, store: store)
}

private func templateDefinition(_ f: TemplateFixture, label: String = "Note", kind: EntityPropertyKind = .text) async throws -> EntityPropertyDefinitionSnapshot {
    try await f.store.savePropertyDefinition(.init(vaultID: f.vaultID, label: label, kind: kind, cardinality: .many), expected: nil, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
}

private func templateSave(_ f: TemplateFixture, type: String = "person", ids: [UUID], expected: BlockStoreRevision? = nil) async throws -> EntityPropertyTemplateSnapshot {
    try await f.store.savePropertyTemplate(typeKey: type, definitionIDs: ids, expected: expected, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
}

@discardableResult private func templateSQL(_ url: URL, _ sql: String) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw VaultError.storage("Test database open failed") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK else { throw VaultError.storage("Test FK setup failed") }
    var query: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { throw VaultError.storage(String(cString: sqlite3_errmsg(db))) }
    defer { sqlite3_finalize(query) }
    let result = sqlite3_step(query)
    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw VaultError.storage(String(cString: sqlite3_errmsg(db))) }
    return result == SQLITE_ROW ? Int(sqlite3_column_int(query, 0)) : 0
}

@Test func entityTemplateAllFiveTypesShareDefinitionsAndReopenInOrder() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(KnowledgeEntityType.initial.map(\.key) == ["person", "place", "concept", "event", "creativeWork"])
    let first = try await templateDefinition(f), second = try await templateDefinition(f, label: "Created by", kind: .entityReference)
    var saved: [EntityPropertyTemplateSnapshot] = []
    for type in KnowledgeEntityType.initial.map(\.key) {
        let absent = try await f.store.loadPropertyTemplate(typeKey: type)
        #expect(absent.typeKey == type && absent.definitionIDs.isEmpty && absent.revision == nil)
        let initial = try await templateSave(f, type: type, ids: [first.definition.id, second.definition.id])
        saved.append(try await templateSave(f, type: type, ids: [second.definition.id, first.definition.id], expected: initial.revision))
    }
    #expect(try await f.store.listPropertyDefinitions().count == 2)
    try await f.store.close()
    let reopened = try VaultStorageProvider.plaintext.makeTemplateStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    for snapshot in saved { #expect(try await reopened.loadPropertyTemplate(typeKey: snapshot.typeKey) == snapshot) }
    try await reopened.close()
}

@Test func entityTemplateEmptyHasRevisionAndRejectsAbsentOrStaleReplacement() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let definition = try await templateDefinition(f)
    let saved = try await templateSave(f, ids: [])
    #expect(saved.definitionIDs.isEmpty && saved.revision != nil)
    let before = try await f.store.canonicalVaultRevision()
    await #expect(throws: (any Error).self) { try await templateSave(f, ids: [definition.definition.id]) }
    #expect(try await f.store.canonicalVaultRevision() == before)
    let populated = try await templateSave(f, ids: [definition.definition.id], expected: saved.revision)
    await #expect(throws: KnowledgeStoreError.staleRevision) { try await templateSave(f, ids: [], expected: saved.revision) }
    #expect(try await f.store.loadPropertyTemplate(typeKey: "person") == populated)
    try await f.store.close()
    let reopened = try VaultStorageProvider.plaintext.makeTemplateStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    let empty = try await reopened.savePropertyTemplate(typeKey: "person", definitionIDs: [], expected: populated.revision, expectedVaultRevision: reopened.canonicalVaultRevision(), operationID: UUID()).value
    #expect(empty.revision != nil && empty.revision != populated.revision)
    try await reopened.close()
}

@Test func entityTemplateRejectsUnknownTypeDuplicateMissingAndForeignIDsAtomically() async throws {
    let f = try templateFixture(), other = try templateFixture()
    defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: other.root) }
    let definition = try await templateDefinition(f), foreign = try await templateDefinition(other)
    let before = try await f.store.canonicalVaultRevision()
    for type in ["book", "source", "Person", "", " person"] {
        await #expect(throws: (any Error).self) { try await f.store.loadPropertyTemplate(typeKey: type) }
        await #expect(throws: (any Error).self) { try await templateSave(f, type: type, ids: [definition.definition.id]) }
    }
    for ids in [[definition.definition.id, definition.definition.id], [UUID()], [definition.definition.id, foreign.definition.id]] {
        await #expect(throws: (any Error).self) { try await templateSave(f, ids: ids) }
        #expect(try await f.store.canonicalVaultRevision() == before)
        #expect(try await f.store.loadPropertyTemplate(typeKey: "person").revision == nil)
    }
    try await f.store.close(); try await other.store.close()
}

@Test func entityTemplateSixteenCapDoesNotLimitExistingFactsOrChangeOwnerRevisions() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(EntityPropertyTemplateSnapshot.maximumEntries == 16)
    let entity = try await f.store.createEntity(.init(typeKey: "person", label: "Owner"), expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
    var definitions: [EntityPropertyDefinitionSnapshot] = []
    for index in 0..<17 { definitions.append(try await templateDefinition(f, label: "Field \(index)")) }
    let assignments = definitions.map { EntityPropertyAssignment(definitionID: $0.definition.id, value: .text("Preserved")) }
    let values = try await f.store.savePropertyValues(entityID: entity.entity.id, assignments: assignments, expectedEntity: entity.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
    let owner = try await f.store.loadEntity(id: entity.entity.id)
    let relationship = try await templateDefinition(f, label: "Related", kind: .entityReference)
    for index in 0..<17 {
        let target = try await f.store.createEntity(.init(typeKey: "concept", label: "Target \(index)"), expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
        _ = try await f.store.createPropertyRelationship(definitionID: relationship.definition.id, entityID: entity.entity.id, otherEntityID: target.entity.id, direction: .outgoing, expectedEntity: owner.revision, expectedOther: target.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    }
    let edges = try await f.store.queryPropertyRelationships(entityID: entity.entity.id)
    let definitionSnapshots = try await f.store.listPropertyDefinitions()
    let saved = try await templateSave(f, ids: Array(definitions.prefix(16).map { $0.definition.id }))
    let before = try await f.store.canonicalVaultRevision()
    await #expect(throws: (any Error).self) { try await templateSave(f, ids: definitions.map { $0.definition.id }, expected: saved.revision) }
    #expect(try await f.store.canonicalVaultRevision() == before)
    #expect(try await f.store.loadPropertyTemplate(typeKey: "person") == saved)
    _ = try await templateSave(f, ids: [], expected: saved.revision)
    #expect(try await f.store.loadEntity(id: entity.entity.id) == owner)
    #expect(try await f.store.loadPropertyValues(entityID: entity.entity.id) == values)
    #expect(try await f.store.queryPropertyRelationships(entityID: entity.entity.id) == edges)
    #expect(edges.count == 17)
    #expect(try await f.store.listPropertyDefinitions() == definitionSnapshots)
    try await f.store.close()
}

@Test func entityTemplateRenameAndRetirementRetainReferencesWithoutNewRetiredSuggestions() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let first = try await templateDefinition(f), second = try await templateDefinition(f, label: "Second")
    let saved = try await templateSave(f, ids: [first.definition.id, second.definition.id])
    var retired = first.definition; retired.label = "Renamed"; retired.isRetired = true
    _ = try await f.store.savePropertyDefinition(retired, expected: first.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    #expect(try await f.store.loadPropertyTemplate(typeKey: "person") == saved)
    let reordered = try await templateSave(f, ids: [second.definition.id, first.definition.id], expected: saved.revision)
    await #expect(throws: (any Error).self) { try await templateSave(f, type: "place", ids: [first.definition.id]) }
    let removed = try await templateSave(f, ids: [second.definition.id], expected: reordered.revision)
    let before = try await f.store.canonicalVaultRevision()
    await #expect(throws: (any Error).self) { try await templateSave(f, ids: [second.definition.id, first.definition.id], expected: removed.revision) }
    #expect(try await f.store.canonicalVaultRevision() == before)
    #expect(try await f.store.loadPropertyTemplate(typeKey: "person") == removed)
    try await f.store.close()
}

@Test func entityTemplateOperationFailureAndStaleVaultRollbackCompleteReorder() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let first = try await templateDefinition(f), second = try await templateDefinition(f, label: "Second")
    let saved = try await templateSave(f, ids: [first.definition.id, second.definition.id])
    let before = try await f.store.canonicalVaultRevision()
    try templateSQL(f.url, "CREATE TRIGGER fail_template_operation BEFORE INSERT ON knowledge_operations BEGIN SELECT RAISE(ABORT,'injected template failure'); END")
    await #expect(throws: (any Error).self) { try await templateSave(f, ids: [second.definition.id, first.definition.id], expected: saved.revision) }
    #expect(try await f.store.loadPropertyTemplate(typeKey: "person") == saved)
    #expect(try await f.store.canonicalVaultRevision() == before)
    try templateSQL(f.url, "DROP TRIGGER fail_template_operation")
    _ = try await templateSave(f, type: "place", ids: [])
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await f.store.savePropertyTemplate(typeKey: "person", definitionIDs: [], expected: saved.revision, expectedVaultRevision: before, operationID: UUID())
    }
    #expect(try await f.store.loadPropertyTemplate(typeKey: "person") == saved)
    try await f.store.close()
}

@Test func entityTemplateOperationIDsCannotReplayAsASecondMutation() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let operation = UUID(), before = try await f.store.canonicalVaultRevision()
    let saved = try await f.store.savePropertyTemplate(typeKey: "person", definitionIDs: [], expected: nil, expectedVaultRevision: before, operationID: operation)
    await #expect(throws: (any Error).self) {
        try await f.store.savePropertyTemplate(typeKey: "place", definitionIDs: [], expected: nil, expectedVaultRevision: saved.vaultRevision, operationID: operation)
    }
    #expect(try await f.store.canonicalVaultRevision() == saved.vaultRevision)
    #expect(try await f.store.loadPropertyTemplate(typeKey: "place").revision == nil)
    try await f.store.close()
}

@Test func entityTemplateConcurrentWritersPublishOnlyOneRevision() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let other = try VaultStorageProvider.plaintext.makeTemplateStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    let before = try await f.store.canonicalVaultRevision()
    let successes = await withTaskGroup(of: Bool.self) { group in
        for store in [f.store, other] {
            group.addTask {
                do { _ = try await store.savePropertyTemplate(typeKey: "person", definitionIDs: [], expected: nil, expectedVaultRevision: before, operationID: UUID()); return true }
                catch { return false }
            }
        }
        var successes = 0
        for await success in group { if success { successes += 1 } }
        return successes
    }
    #expect(successes == 1)
    #expect(try await f.store.loadPropertyTemplate(typeKey: "person").revision != nil)
    try await other.close(); try await f.store.close()
}

@Test func entityTemplateExplicitEightUpgradePreservesFactsAndOptionalPayloadsAndRollsBack() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.close()
    // Use a separate schema-8 database: opening it never upgrades implicitly.
    let oldURL = f.root.appendingPathComponent("old.sqlite")
    let old = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: oldURL, vaultID: f.vaultID)
    var entity = KnowledgeEntity(typeKey: "creativeWork", label: "Retained")
    entity.unknownFields["futureEntity"] = .object(["keep": .bool(true)])
    let created = try await old.createEntity(entity, expectedVaultRevision: old.canonicalVaultRevision(), operationID: UUID()).value
    let definition = try EntityPropertyDefinition(vaultID: f.vaultID, label: "Text", kind: .text)
    let savedDefinition = try await old.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: old.canonicalVaultRevision(), operationID: UUID()).value
    let assignment = EntityPropertyAssignment(definitionID: definition.id, value: .text("Preserved"))
    let values = try await old.savePropertyValues(entityID: entity.id, assignments: [assignment], expectedEntity: created.revision, expectedVaultRevision: old.canonicalVaultRevision(), operationID: UUID()).value
    let owner = try await old.transitionEntity(id: entity.id, to: .tombstoned, expected: values.entityRevision, expectedVaultRevision: old.canonicalVaultRevision(), operationID: UUID()).value
    try templateSQL(oldURL, "UPDATE vault_state SET extensions=CAST('{\"futureVault\":{\"retain\":[true,1]}}' AS BLOB)")
    let before = try await old.canonicalVaultRevision()
    await #expect(throws: KnowledgeStoreError.transitionRequired) { try await old.loadPropertyTemplate(typeKey: "person") }
    await #expect(throws: KnowledgeStoreError.staleRevision) { try await old.upgradeEntityPropertyTemplateSchema(expectedVaultRevision: .init(token: Data("stale".utf8))) }
    try templateSQL(oldURL, "CREATE TRIGGER fail_template_migration BEFORE UPDATE ON vault_state BEGIN SELECT RAISE(ABORT,'injected template migration failure'); END")
    await #expect(throws: (any Error).self) { try await old.upgradeEntityPropertyTemplateSchema(expectedVaultRevision: before) }
    #expect(try templateSQL(oldURL, "PRAGMA user_version") == 8)
    #expect(try await old.canonicalVaultRevision() == before)
    try templateSQL(oldURL, "DROP TRIGGER fail_template_migration")
    let revision = try await old.upgradeEntityPropertyTemplateSchema(expectedVaultRevision: before)
    #expect(revision != before)
    try await old.close()
    let reopened = try VaultStorageProvider.plaintext.makeTemplateStagingStore(url: oldURL, vaultID: f.vaultID, createIfMissing: false)
    #expect(try await reopened.loadEntity(id: entity.id) == owner)
    #expect(try await reopened.loadPropertyValues(entityID: entity.id).assignments == [assignment])
    #expect(try await reopened.listPropertyDefinitions() == [savedDefinition])
    _ = try await reopened.savePropertyTemplate(typeKey: "creativeWork", definitionIDs: [definition.id], expected: nil, expectedVaultRevision: revision, operationID: UUID())
    #expect(try templateSQL(oldURL, "SELECT json_extract(CAST(extensions AS TEXT),'$.futureVault.retain[0]') FROM vault_state") == 1)
    #expect(try await reopened.loadEntity(id: entity.id) == owner)
    try await reopened.close()
}

private struct TemplateManifestFailureStore: VaultContentStore {
    let base: any VaultContentStore
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data { try base.read(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        if path == "vault.json" { throw VaultError.storage("Injected template manifest publication failure") }
        try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

@Test func entityTemplateManifestMismatchRequiresExplicitResumeAndMatchingLease() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.close()
    let root = f.root.appendingPathComponent("legacy")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: f.vaultID)
    let revision = try await database.canonicalVaultRevision()
    try await database.close()
    var manifest = VaultManifest(id: f.vaultID)
    manifest.storage?.schemaVersion = 8
    manifest.storage?.requiredCapabilities = SQLiteBlockStore.relationshipRequiredCapabilities
    manifest.unknownFields["futureManifest"] = .string("retain")
    let bytes = try JSONEncoder().encode(manifest)
    let content = try VaultStorageProvider.plaintext.makeStore(root: root)
    for directory in ["Sources", "Removed Pages", "Conflicts"] { try content.createDirectory(at: directory) }
    try content.write(bytes, at: "vault.json", condition: .createOnly)
    let session = VaultSession(vaultID: f.vaultID, root: root, generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    await #expect(throws: VaultError.self) {
        try await FileVaultRepository.upgradeEntityPropertyTemplates(root: root, sessionLease: session.lease, accessGate: gate, expectedVaultRevision: revision, contentStore: TemplateManifestFailureStore(base: content))
    }
    #expect(try content.read(at: "vault.json") == bytes)
    #expect(throws: VaultError.self) { try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate) }
    let recovered = try await FileVaultRepository.resumeEntityPropertyTemplatesUpgrade(root: root, sessionLease: session.lease, accessGate: gate)
    #expect(recovered.storage?.schemaVersion == 9)
    #expect(recovered.unknownFields == manifest.unknownFields)
    let repository = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
    #expect(try await repository.sqliteBlockStore.loadPropertyTemplate(typeKey: "creativeWork").revision == nil)
    let before = try await repository.sqliteBlockStore.canonicalVaultRevision()
    gate.updateState(.closed)
    await #expect(throws: (any Error).self) {
        try await repository.sqliteBlockStore.savePropertyTemplate(typeKey: "person", definitionIDs: [], expected: nil, expectedVaultRevision: before, operationID: UUID())
    }
    await #expect(throws: (any Error).self) { try await FileVaultRepository.resumeEntityPropertyTemplatesUpgrade(root: root, sessionLease: session.lease, accessGate: gate) }
    try await repository.sqliteBlockStore.close()
    gate.updateState(.open(session))
    let reopened = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
    #expect(try await reopened.sqliteBlockStore.canonicalVaultRevision() == before)
    #expect(try await reopened.sqliteBlockStore.loadPropertyTemplate(typeKey: "person").revision == nil)
    try await reopened.sqliteBlockStore.close()
}

@Test func entityTemplateNativeArchiveRoundTripRetainsTemplatesFactsAndOriginals() async throws {
    let f = try templateFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.store.close()
    let root = try await FileVaultRepository.createNewVault(parent: f.root, name: "Vault", encryptionRequested: false)
    let manager = VaultSessionManager()
    let (_, _, repository) = try await manager.openRepository(root: root)
    let store = repository.sqliteBlockStore
    let original = Data("Preserved source bytes".utf8)
    let source = try await repository.importSource(data: original, filename: "original.txt", title: "Evidence", originURL: nil)
    let definition = try await store.savePropertyDefinition(.init(vaultID: repository.manifest.id, label: "Note", kind: .text), expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let entity = try await store.createEntity(.init(typeKey: "creativeWork", label: "Work"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let values = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [.init(definitionID: definition.definition.id, value: .text("Existing fact"))], expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let template = try await store.savePropertyTemplate(typeKey: "creativeWork", definitionIDs: [definition.definition.id], expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let empty = try await store.savePropertyTemplate(typeKey: "person", definitionIDs: [], expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let archive = f.root.appendingPathComponent("Archive")
    _ = try await repository.archive(to: archive)
    let destination = f.root.appendingPathComponent("Restored")
    let session = VaultSession(vaultID: repository.manifest.id, root: destination, generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    _ = try await NativeVaultArchive.restore(from: archive, parent: f.root, name: "Restored", sessionLease: session.lease, accessGate: gate)
    let restoredManager = VaultSessionManager()
    let (_, _, restored) = try await restoredManager.openRepository(root: destination)
    #expect(try await restored.sqliteBlockStore.loadPropertyTemplate(typeKey: "creativeWork") == template)
    #expect(try await restored.sqliteBlockStore.loadPropertyTemplate(typeKey: "person") == empty)
    #expect(try await restored.sqliteBlockStore.loadPropertyValues(entityID: entity.entity.id) == values)
    #expect(try await restored.sqliteBlockStore.listPropertyDefinitions() == [definition])
    let originalPath = "Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)"
    #expect(try Data(contentsOf: destination.appendingPathComponent(originalPath)) == original)
    try await restored.sqliteBlockStore.close(); try await restoredManager.close()
    try await store.close(); try await manager.close()
}
