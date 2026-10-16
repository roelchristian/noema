import Foundation
import SQLite3
import Testing
@testable import VaultCore

private func propertyTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("entity-property-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func entityPropertyScalarKindsSurviveReopenWithoutChangingPages() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: url, vaultID: vaultID)
    let entity = try await store.createEntity(.init(typeKey: "creativeWork", label: "A work"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let pageID = UUID(), document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("An independent Page")])])
    let page = try await store.save(document, pageID: pageID, condition: .createOnly)
    let samples: [(EntityPropertyKind, EntityPropertyValue)] = [
        (.text, .text("  Original text  ")), (.number, .number(-1.25)),
        (.date, .date(try .init(year: 2024, month: 2, day: 29))),
        (.boolean, .boolean(false)), (.url, .url("https://example.com/a?q=1"))
    ]
    var assignments: [EntityPropertyAssignment] = []
    for (kind, value) in samples {
        let definition = try EntityPropertyDefinition(vaultID: vaultID, label: kind.rawValue, kind: kind)
        _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        assignments.append(.init(definitionID: definition.id, value: value))
    }
    let result = try await store.savePropertyValues(entityID: entity.entity.id, assignments: assignments, expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(result.value.assignments == assignments)
    #expect(result.value.entityRevision != entity.revision)
    #expect(try await store.load(pageID: pageID) == page)
    try await store.close()
    let reopen = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopen.loadPropertyValues(entityID: entity.entity.id) == result.value)
    #expect(try await reopen.listPropertyDefinitions().count == samples.count)
    #expect(try await reopen.load(pageID: pageID) == page)
    try await reopen.close()
}

@Test func entityPropertyRejectsForeignVaultDefinitionWithoutMutation() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: UUID())
    let vaultID = UUID()
    await #expect(throws: (any Error).self) {
        try await store.savePropertyDefinition(try .init(vaultID: vaultID, label: "Wrong vault", kind: .text), expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    }
    #expect(try await store.listPropertyDefinitions().isEmpty)
    try await store.close()
}

@Test func entityPropertyMultiValuesReorderUnsetAndConflictAreTransactional() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let vaultID = UUID(), store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    let entity = try await store.createEntity(.init(typeKey: "person", label: "Entity"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "  Display   Label ", kind: .text, cardinality: .many)
    let savedDefinition = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let before = try await store.canonicalVaultRevision()
    await #expect(throws: (any Error).self) {
        try await store.savePropertyDefinition(try .init(vaultID: vaultID, label: "display label", kind: .text), expected: nil, expectedVaultRevision: before, operationID: UUID())
    }
    #expect(try await store.canonicalVaultRevision() == before)
    #expect(try await store.listPropertyDefinitions() == [savedDefinition])
    let first = EntityPropertyAssignment(definitionID: definition.id, value: .text("first"))
    let second = EntityPropertyAssignment(definitionID: definition.id, value: .text("second"))
    let saved = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [first, second], expectedEntity: entity.revision, expectedVaultRevision: before, operationID: UUID())
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await store.savePropertyValues(entityID: entity.entity.id, assignments: [], expectedEntity: entity.revision, expectedVaultRevision: saved.vaultRevision, operationID: UUID())
    }
    #expect(try await store.loadPropertyValues(entityID: entity.entity.id) == saved.value)
    let reordered = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [second, first], expectedEntity: saved.value.entityRevision, expectedVaultRevision: saved.vaultRevision, operationID: UUID())
    #expect(reordered.value.assignments.map(\.id) == [second.id, first.id])
    let unset = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [], expectedEntity: reordered.value.entityRevision, expectedVaultRevision: reordered.vaultRevision, operationID: UUID())
    #expect(unset.value.assignments.isEmpty)
    try await store.close()
}

@Test func entityPropertyRejectsInvalidScalarsCardinalityAndMissingReferences() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let vaultID = UUID(), store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    let entity = try await store.createEntity(.init(typeKey: "concept", label: "Entity"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Number", kind: .number)
    _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let before = try await store.canonicalVaultRevision()
    for value: EntityPropertyValue in [.number(.infinity), .number(.nan), .url("relative"), .text("wrong kind")] {
        await #expect(throws: (any Error).self) {
            try await store.savePropertyValues(entityID: entity.entity.id, assignments: [.init(definitionID: definition.id, value: value)], expectedEntity: entity.revision, expectedVaultRevision: before, operationID: UUID())
        }
    }
    await #expect(throws: (any Error).self) {
        try await store.savePropertyValues(entityID: entity.entity.id, assignments: [.init(definitionID: definition.id, value: .number(1)), .init(definitionID: definition.id, value: .number(2))], expectedEntity: entity.revision, expectedVaultRevision: before, operationID: UUID())
    }
    await #expect(throws: (any Error).self) {
        try await store.savePropertyValues(entityID: entity.entity.id, assignments: [.init(definitionID: UUID(), value: .number(1))], expectedEntity: entity.revision, expectedVaultRevision: before, operationID: UUID())
    }
    #expect(try await store.canonicalVaultRevision() == before)
    #expect(try await store.loadPropertyValues(entityID: entity.entity.id).assignments.isEmpty)
    #expect(throws: EntityPropertyValidationError.invalidDate) { try EntityPropertyDate(year: 2023, month: 2, day: 29) }
    try await store.close()
}

@Test func entityPropertyRetirementPreservesExistingValuesAndTombstonesRejectEdits() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let vaultID = UUID(), store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    let entity = try await store.createEntity(.init(typeKey: "place", label: "Entity"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    var definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Label", kind: .text)
    let original = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let assignment = EntityPropertyAssignment(definitionID: definition.id, value: .text("preserved"))
    let saved = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [assignment], expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    var incompatible = definition; incompatible.kind = .number
    await #expect(throws: (any Error).self) {
        try await store.savePropertyDefinition(incompatible, expected: original.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    }
    definition.isRetired = true
    _ = try await store.savePropertyDefinition(definition, expected: original.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(try await store.listPropertyDefinitions().isEmpty)
    #expect(try await store.listPropertyDefinitions(includeRetired: true).count == 1)
    #expect(try await store.loadPropertyValues(entityID: entity.entity.id).assignments == [assignment])
    await #expect(throws: (any Error).self) {
        try await store.savePropertyValues(entityID: entity.entity.id, assignments: [.init(definitionID: definition.id, value: .text("new"))], expectedEntity: saved.entityRevision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    }
    let removed = try await store.transitionEntity(id: entity.entity.id, to: .tombstoned, expected: saved.entityRevision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(try await store.loadPropertyValues(entityID: entity.entity.id).assignments == [assignment])
    await #expect(throws: KnowledgeStoreError.tombstoned(entity.entity.id)) {
        try await store.savePropertyValues(entityID: entity.entity.id, assignments: [], expectedEntity: removed.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    }
    try await store.close()
}

private func propertyTestSQL(_ url: URL, _ sql: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else { throw VaultError.storage("Test database open failed") }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(connection))) }
}

@Test func entityPropertyExplicitMigrationPreservesSupportedSixVault() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let old = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: vaultID)
    let entity = try await old.createEntity(.init(typeKey: "event", label: "Existing"), expectedVaultRevision: old.canonicalVaultRevision(), operationID: UUID()).value
    let before = try await old.canonicalVaultRevision()
    try await old.close()
    let supported = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await supported.loadEntity(id: entity.entity.id) == entity)
    #expect(try await supported.canonicalVaultRevision() == before)
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await supported.upgradeEntityPropertySchema(expectedVaultRevision: .init(token: Data("stale".utf8)))
    }
    #expect(try await supported.canonicalVaultRevision() == before)
    let upgradedRevision = try await supported.upgradeEntityPropertySchema(expectedVaultRevision: before)
    #expect(try await supported.loadEntity(id: entity.entity.id) == entity)
    #expect(try await supported.listPropertyDefinitions().isEmpty)
    try await supported.close()
    let upgraded = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await upgraded.canonicalVaultRevision() == upgradedRevision)
    #expect(try await upgraded.loadEntity(id: entity.entity.id) == entity)
    try await upgraded.close()
}

@Test func entityPropertyMigrationFailureRollsBackSchemaAndVaultRevision() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: vaultID)
    let before = try await store.canonicalVaultRevision()
    // Migration must update the admission row atomically with its new tables.
    try propertyTestSQL(url, "CREATE TRIGGER fail_property_migration BEFORE UPDATE ON vault_state BEGIN SELECT RAISE(ABORT,'injected migration failure'); END")
    await #expect(throws: (any Error).self) {
        try await store.upgradeEntityPropertySchema(expectedVaultRevision: before)
    }
    #expect(try await store.canonicalVaultRevision() == before)
    try await store.close()
    try propertyTestSQL(url, "DROP TRIGGER fail_property_migration")
    let reopen = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopen.canonicalVaultRevision() == before)
    _ = try await reopen.upgradeEntityPropertySchema(expectedVaultRevision: before)
    #expect(try await reopen.listPropertyDefinitions().isEmpty)
    try await reopen.close()
}

@Test func entityPropertySQLConstraintsEnforceCardinalityAndScalarShape() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: url, vaultID: vaultID)
    let entity = try await store.createEntity(.init(typeKey: "person", label: "Entity"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Text", kind: .text)
    _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let assignment = EntityPropertyAssignment(definitionID: definition.id, value: .text("original"))
    let saved = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [assignment], expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(throws: VaultError.self) {
        try propertyTestSQL(url, "INSERT INTO entity_property_values(id,definition_id,entity_id,position,kind,text_value) VALUES('\(UUID())','\(definition.id)','\(entity.entity.id)',1,'text','second')")
    }
    #expect(throws: VaultError.self) {
        try propertyTestSQL(url, "UPDATE entity_property_values SET number_value=1 WHERE id='\(assignment.id)'")
    }
    #expect(throws: VaultError.self) {
        try propertyTestSQL(url, "UPDATE entity_property_definitions SET kind='number' WHERE id='\(definition.id)'")
    }
    #expect(try await store.loadPropertyValues(entityID: entity.entity.id) == saved.value)
    #expect(try await store.canonicalVaultRevision() == saved.vaultRevision)
    // Failure while recording the canonical operation must roll back the value replacement.
    try propertyTestSQL(url, "CREATE TRIGGER fail_property_operation BEFORE INSERT ON knowledge_operations BEGIN SELECT RAISE(ABORT,'injected operation failure'); END")
    await #expect(throws: VaultError.self) {
        try await store.savePropertyValues(entityID: entity.entity.id, assignments: [], expectedEntity: saved.value.entityRevision, expectedVaultRevision: saved.vaultRevision, operationID: UUID())
    }
    #expect(try await store.loadPropertyValues(entityID: entity.entity.id) == saved.value)
    #expect(try await store.canonicalVaultRevision() == saved.vaultRevision)
    try await store.close()
}

private struct PropertyManifestFailureStore: VaultContentStore {
    let base: any VaultContentStore
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data { try base.read(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        if path == "vault.json" { throw VaultError.storage("Injected manifest publication failure") }
        try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

@Test func entityPropertyManifestFailurePreservesMismatchAndExplicitResume() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let database = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: vaultID)
    let revision = try await database.canonicalVaultRevision()
    try await database.close()
    var manifest = VaultManifest(id: vaultID)
    manifest.storage?.schemaVersion = 6
    manifest.storage?.requiredCapabilities = SQLiteBlockStore.organisationRequiredCapabilities
    manifest.unknownFields["futureOptional"] = .string("retain")
    let bytes = try JSONEncoder().encode(manifest)
    let store = try VaultStorageProvider.plaintext.makeStore(root: root)
    for directory in ["Sources", "Removed Pages", "Conflicts"] { try store.createDirectory(at: directory) }
    try store.write(bytes, at: "vault.json", condition: .createOnly)
    let session = VaultSession(vaultID: vaultID, root: root, generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    await #expect(throws: VaultError.self) {
        try await FileVaultRepository.upgradeEntityProperties(root: root, sessionLease: session.lease, accessGate: gate, expectedVaultRevision: revision, contentStore: PropertyManifestFailureStore(base: store))
    }
    #expect(try store.read(at: "vault.json") == bytes)
    #expect(throws: VaultError.self) {
        try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
    }
    let recovered = try await FileVaultRepository.resumeEntityPropertiesUpgrade(root: root, sessionLease: session.lease, accessGate: gate)
    #expect(recovered.storage?.schemaVersion == 7)
    #expect(recovered.unknownFields == manifest.unknownFields)
    let reopened = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
    #expect(try await reopened.sqliteBlockStore.listPropertyDefinitions().isEmpty)
    try await reopened.sqliteBlockStore.close()
    gate.updateState(.closed)
    await #expect(throws: (any Error).self) {
        try await FileVaultRepository.resumeEntityPropertiesUpgrade(root: root, sessionLease: session.lease, accessGate: gate)
    }
}

@Test func entityPropertySQLRejectsTextDisguisedAsNumber() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: url, vaultID: vaultID)
    let entity = try await store.createEntity(.init(typeKey: "concept", label: "Entity"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Number", kind: .number)
    _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let assignment = EntityPropertyAssignment(definitionID: definition.id, value: .number(1))
    let saved = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [assignment], expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(throws: VaultError.self) { try propertyTestSQL(url, "UPDATE entity_property_values SET number_value='abc' WHERE id='\(assignment.id)'") }
    #expect(try await store.loadPropertyValues(entityID: entity.entity.id) == saved.value)
    try await store.close()
}

@Test func entityPropertyAdmissionRejectsFractionalDateComponents() async throws {
    let root = try propertyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: url, vaultID: vaultID)
    let entity = try await store.createEntity(.init(typeKey: "event", label: "Entity"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Date", kind: .date)
    _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let assignment = EntityPropertyAssignment(definitionID: definition.id, value: .date(try .init(year: 2024, month: 2, day: 1)))
    _ = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [assignment], expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(throws: VaultError.self) { try propertyTestSQL(url, "UPDATE entity_property_values SET date_month=2.5 WHERE id='\(assignment.id)'") }
    try await store.close()
    // Simulate corrupt bytes bypassing SQL checks; admission must reject, not truncate.
    try propertyTestSQL(url, "PRAGMA ignore_check_constraints=ON; UPDATE entity_property_values SET date_month=2.5 WHERE id='\(assignment.id)'")
    #expect(throws: (any Error).self) { try VaultStorageProvider.plaintext.makePropertyStagingStore(url: url, vaultID: vaultID, createIfMissing: false) }
}
