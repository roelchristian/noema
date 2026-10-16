import Foundation
import SQLite3
import Testing
@testable import VaultCore

private struct RelationshipFixture {
    let root: URL
    let url: URL
    let vaultID: UUID
    let store: SQLiteBlockStore
    let source: UUID
    let target: UUID
}

private func relationshipFixture() async throws -> RelationshipFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("entity-relationships-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: url, vaultID: vaultID)
    let source = try await store.createEntity(.init(typeKey: "creativeWork", label: "Work"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value.entity.id
    let target = try await store.createEntity(.init(typeKey: "person", label: "Creator"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value.entity.id
    return .init(root: root, url: url, vaultID: vaultID, store: store, source: source, target: target)
}

private func relationshipDefinition(_ f: RelationshipFixture, cardinality: EntityPropertyCardinality = .many) async throws -> EntityPropertyDefinitionSnapshot {
    let definition = try EntityPropertyDefinition(vaultID: f.vaultID, label: "Created by", kind: .entityReference, cardinality: cardinality)
    return try await f.store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
}

private func relationshipCreate(_ f: RelationshipFixture, definitionID: UUID, entityID: UUID? = nil, otherID: UUID? = nil, direction: KnowledgeRelationDirection = .outgoing) async throws -> EntityPropertyRelationshipSnapshot {
    let entityID = entityID ?? f.source, otherID = otherID ?? f.target
    let entity = try await f.store.loadEntity(id: entityID), other = try await f.store.loadEntity(id: otherID)
    return try await f.store.createPropertyRelationship(definitionID: definitionID, entityID: entityID, otherEntityID: otherID, direction: direction, expectedEntity: entity.revision, expectedOther: other.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
}

@discardableResult private func relationshipSQL(_ url: URL, _ sql: String) throws -> Int {
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

@Test func entityRelationshipOneCanonicalEdgeHasBothViewsAndSurvivesReopen() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let definition = try await relationshipDefinition(f)
    let edge = try await relationshipCreate(f, definitionID: definition.definition.id)
    #expect(try await f.store.queryPropertyRelationships(entityID: f.source, direction: .outgoing) == [edge])
    #expect(try await f.store.queryPropertyRelationships(entityID: f.target, direction: .incoming) == [edge])
    #expect(try await f.store.queryPropertyRelationships(entityID: f.source, direction: .incoming).isEmpty)
    #expect(try relationshipSQL(f.url, "SELECT count(*) FROM entity_property_relationships") == 1)
    try await f.store.close()
    let reopen = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    #expect(try await reopen.queryPropertyRelationships(entityID: f.target, direction: .incoming) == [edge])
    try await reopen.close()
}

@Test func entityRelationshipInverseCreationRemovalAndSelfLinksUseCanonicalDirection() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let definition = try await relationshipDefinition(f)
    let edge = try await relationshipCreate(f, definitionID: definition.definition.id, entityID: f.target, otherID: f.source, direction: .incoming)
    #expect(edge.relationship.sourceID == f.source)
    #expect(edge.relationship.targetID == f.target)
    let source = try await f.store.loadEntity(id: f.source), target = try await f.store.loadEntity(id: f.target)
    _ = try await f.store.removePropertyRelationship(id: edge.relationship.id, expected: edge.revision, expectedSource: source.revision, expectedTarget: target.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    #expect(try await f.store.queryPropertyRelationships(entityID: f.target, direction: .incoming).isEmpty)
    let selfEdge = try await relationshipCreate(f, definitionID: definition.definition.id, otherID: f.source)
    #expect(try await f.store.queryPropertyRelationships(entityID: f.source, direction: .both) == [selfEdge])
    try await f.store.close()
}

@Test func entityRelationshipRejectsDuplicatesAndTargetMultiplicityAllowsFanIn() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let definition = try await relationshipDefinition(f, cardinality: .one)
    let edge = try await relationshipCreate(f, definitionID: definition.definition.id)
    let before = try await f.store.canonicalVaultRevision()
    await #expect(throws: (any Error).self) { try await relationshipCreate(f, definitionID: definition.definition.id) }
    await #expect(throws: (any Error).self) { try await relationshipCreate(f, definitionID: definition.definition.id, otherID: f.source) }
    #expect(try await f.store.canonicalVaultRevision() == before)
    #expect(throws: (any Error).self) {
        try relationshipSQL(f.url, "INSERT INTO entity_property_relationships(id,definition_id,source_id,target_id,created_at,revision) SELECT '\(UUID())',definition_id,source_id,target_id,created_at,revision FROM entity_property_relationships WHERE id='\(edge.relationship.id)'")
    }
    _ = try await relationshipCreate(f, definitionID: definition.definition.id, entityID: f.target, otherID: f.target)
    #expect(try await f.store.queryPropertyRelationships(entityID: f.target, direction: .incoming).count == 2)
    try await f.store.close()
}

@Test func entityRelationshipFailureRollsBackAndRejectsStaleOrForeignReferences() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let definition = try await relationshipDefinition(f)
    let source = try await f.store.loadEntity(id: f.source), target = try await f.store.loadEntity(id: f.target)
    let before = try await f.store.canonicalVaultRevision()
    await #expect(throws: (any Error).self) {
        try await f.store.createPropertyRelationship(definitionID: definition.definition.id, entityID: f.source, otherEntityID: UUID(), direction: .outgoing, expectedEntity: source.revision, expectedOther: target.revision, expectedVaultRevision: before, operationID: UUID())
    }
    await #expect(throws: (any Error).self) {
        try await f.store.savePropertyDefinition(try .init(vaultID: UUID(), label: "Foreign", kind: .entityReference), expected: nil, expectedVaultRevision: before, operationID: UUID())
    }
    try relationshipSQL(f.url, "CREATE TRIGGER fail_edge_operation BEFORE INSERT ON knowledge_operations BEGIN SELECT RAISE(ABORT,'injected edge failure'); END")
    await #expect(throws: (any Error).self) { try await relationshipCreate(f, definitionID: definition.definition.id) }
    #expect(try await f.store.canonicalVaultRevision() == before)
    #expect(try await f.store.loadEntity(id: f.source) == source)
    #expect(try await f.store.queryPropertyRelationships(entityID: f.source, direction: .both).isEmpty)
    try relationshipSQL(f.url, "DROP TRIGGER fail_edge_operation")
    _ = try await relationshipCreate(f, definitionID: definition.definition.id)
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await f.store.createPropertyRelationship(definitionID: definition.definition.id, entityID: f.target, otherEntityID: f.source, direction: .outgoing, expectedEntity: target.revision, expectedOther: source.revision, expectedVaultRevision: before, operationID: UUID())
    }
    try await f.store.close()
}

@Test func entityRelationshipConcurrentWritersCannotBothUseSameRevision() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let definition = try await relationshipDefinition(f, cardinality: .one)
    let otherStore = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    let source = try await f.store.loadEntity(id: f.source), target = try await f.store.loadEntity(id: f.target), before = try await f.store.canonicalVaultRevision()
    let successes = await withTaskGroup(of: Bool.self) { group in
        for store in [f.store, otherStore] {
            group.addTask {
                do {
                    _ = try await store.createPropertyRelationship(definitionID: definition.definition.id, entityID: f.source, otherEntityID: f.target, direction: .outgoing, expectedEntity: source.revision, expectedOther: target.revision, expectedVaultRevision: before, operationID: UUID())
                    return true
                } catch { return false }
            }
        }
        var count = 0
        for await success in group { if success { count += 1 } }
        return count
    }
    #expect(successes == 1)
    #expect(try relationshipSQL(f.url, "SELECT count(*) FROM entity_property_relationships") == 1)
    try await otherStore.close(); try await f.store.close()
}

@Test func entityRelationshipRenameRetirementAndTombstonePreserveFacts() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try await relationshipDefinition(f)
    let edge = try await relationshipCreate(f, definitionID: original.definition.id)
    var renamed = original.definition; renamed.label = "Creator"; renamed.isRetired = true
    _ = try await f.store.savePropertyDefinition(renamed, expected: original.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    #expect(try await f.store.listPropertyDefinitions().isEmpty)
    #expect(try await f.store.listPropertyDefinitions(includeRetired: true).first?.definition.label == "Creator")
    await #expect(throws: (any Error).self) { try await relationshipCreate(f, definitionID: original.definition.id, entityID: f.target, otherID: f.source) }
    let target = try await f.store.loadEntity(id: f.target)
    _ = try await f.store.transitionEntity(id: f.target, to: .tombstoned, expected: target.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    #expect(try relationshipSQL(f.url, "SELECT count(*) FROM entity_property_relationships") == 1)
    #expect(try await f.store.queryPropertyRelationships(entityID: f.source, direction: .outgoing) == [edge])
    try await f.store.close()
}

@Test func entityRelationshipSevenMigrationPreservesTombstonedScalarsAndRollsBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relationship-migration-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: url, vaultID: vaultID)
    let entity = try await store.createEntity(.init(typeKey: "concept", label: "Preserved"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Note", kind: .text)
    _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let assignment = EntityPropertyAssignment(definitionID: definition.id, value: .text("Keep"))
    let values = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [assignment], expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    _ = try await store.transitionEntity(id: entity.entity.id, to: .tombstoned, expected: values.entityRevision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let before = try await store.canonicalVaultRevision()
    try relationshipSQL(url, "CREATE TRIGGER fail_relationship_migration BEFORE UPDATE ON vault_state BEGIN SELECT RAISE(ABORT,'injected migration failure'); END")
    await #expect(throws: (any Error).self) { try await store.upgradeEntityRelationshipSchema(expectedVaultRevision: before) }
    #expect(try await store.canonicalVaultRevision() == before)
    #expect(try await store.loadPropertyValues(entityID: entity.entity.id).assignments == [assignment])
    try relationshipSQL(url, "DROP TRIGGER fail_relationship_migration")
    _ = try await store.upgradeEntityRelationshipSchema(expectedVaultRevision: before)
    try await store.close()
    let reopened = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopened.loadPropertyValues(entityID: entity.entity.id).assignments == [assignment])
    #expect(try await reopened.queryPropertyRelationships(entityID: entity.entity.id, direction: .both).isEmpty)
    try await reopened.close()
}

@Test func entityRelationshipPresentationPersistsAndTypeHintsRemainAdvisory() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try await relationshipDefinition(f)
    #expect(original.definition.presentation == nil)
    var definition = original.definition
    definition.presentation = .init(inverseLabel: "Works created", sourceTypeKeys: ["person"], targetTypeKeys: ["place"])
    let saved = try await f.store.savePropertyDefinition(definition, expected: original.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
    // Both types deliberately disagree with the hints: an explicit assertion is allowed.
    let edge = try await relationshipCreate(f, definitionID: definition.id)
    #expect(try await f.store.queryPropertyRelationships(entityID: f.target, direction: .incoming) == [edge])
    try await f.store.close()
    let reopened = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    #expect(try await reopened.listPropertyDefinitions() == [saved])
    #expect(try await reopened.queryPropertyRelationships(entityID: f.target, direction: .incoming) == [edge])
    try await reopened.close()
}

@Test func entityRelationshipPresentationPreservesUnknownFieldsAndRollsBackAtomically() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try await relationshipDefinition(f)
    let raw = "{\"unrelatedFuture\":{\"keep\":true},\"entityPropertyPresentation\":{\"\(original.definition.id.uuidString)\":{\"inverseLabel\":\"Works created\",\"future\":{\"retain\":[1,true]}}}}"
    try relationshipSQL(f.url, "UPDATE vault_state SET extensions=CAST('\(raw)' AS BLOB) WHERE singleton=1")
    let current = try #require(try await f.store.listPropertyDefinitions().first)
    var edited = current.definition
    // Even a caller replacing the known presentation retains future optional data.
    edited.presentation = .init(inverseLabel: "Created works", targetTypeKeys: ["person"])
    try relationshipSQL(f.url, "CREATE TRIGGER fail_presentation_operation BEFORE INSERT ON knowledge_operations BEGIN SELECT RAISE(ABORT,'injected presentation failure'); END")
    let before = try await f.store.canonicalVaultRevision()
    await #expect(throws: (any Error).self) {
        try await f.store.savePropertyDefinition(edited, expected: current.revision, expectedVaultRevision: before, operationID: UUID())
    }
    #expect(try await f.store.canonicalVaultRevision() == before)
    #expect(try await f.store.listPropertyDefinitions() == [current])
    try relationshipSQL(f.url, "DROP TRIGGER fail_presentation_operation")
    let saved = try await f.store.savePropertyDefinition(edited, expected: current.revision, expectedVaultRevision: before, operationID: UUID()).value
    #expect(saved.definition.presentation?.inverseLabel == "Created works")
    #expect(saved.definition.presentation?.unknownFields == current.definition.presentation?.unknownFields)
    #expect(try relationshipSQL(f.url, "SELECT instr(CAST(extensions AS TEXT),'unrelatedFuture')>0 FROM vault_state") == 1)
    var scalar = saved.definition; scalar.kind = .text; scalar.presentation = nil
    await #expect(throws: (any Error).self) {
        try await f.store.savePropertyDefinition(scalar, expected: saved.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    }
    try await f.store.validateCanonicalLogicalIntegrity()
    try await f.store.close()
    let reopened = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    #expect(try await reopened.listPropertyDefinitions() == [saved])
    try await reopened.close()
}

@Test func entityRelationshipPresentationSizeLimitRollsBackDefinition() async throws {
    let f = try await relationshipFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let original = try await relationshipDefinition(f)
    var definition = original.definition
    definition.presentation = .init(inverseLabel: String(repeating: "a", count: 262_144))
    let before = try await f.store.canonicalVaultRevision()
    await #expect(throws: PersistencePayloadError.limitExceeded) {
        try await f.store.savePropertyDefinition(definition, expected: original.revision, expectedVaultRevision: before, operationID: UUID())
    }
    #expect(try await f.store.listPropertyDefinitions() == [original])
    #expect(try await f.store.canonicalVaultRevision() == before)
    // Each optional scope fits individually, but the shared vault bound still applies.
    let unrelated = String(repeating: "b", count: 160_000)
    try relationshipSQL(f.url, "UPDATE vault_state SET extensions=CAST('{\"future\":\"\(unrelated)\"}' AS BLOB) WHERE singleton=1")
    definition.presentation = .init(inverseLabel: String(repeating: "a", count: 150_000))
    await #expect(throws: PersistencePayloadError.limitExceeded) {
        try await f.store.savePropertyDefinition(definition, expected: original.revision, expectedVaultRevision: before, operationID: UUID())
    }
    #expect(try await f.store.listPropertyDefinitions() == [original])
    #expect(try await f.store.canonicalVaultRevision() == before)
    #expect(try relationshipSQL(f.url, "SELECT instr(CAST(extensions AS TEXT),'entityPropertyPresentation') FROM vault_state") == 0)
    try await f.store.close()
}
