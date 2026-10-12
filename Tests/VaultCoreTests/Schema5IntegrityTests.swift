import Foundation
import SQLite3
import Testing
@testable import VaultCore

private func schema5IntegrityRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("schema5-integrity-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func schema5IntegritySQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw VaultError.storage("Fixture database open failed") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(database))) }
}

@Test func schema5SupportedExtraKnowledgeDescriptorsSurviveReopenAndBackup() async throws {
    let root = try schema5IntegrityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    try await store.close()
    try schema5IntegritySQL(url, """
    INSERT INTO knowledge_entity_types VALUES('organization',1,'{"key":"organization","version":1,"metadata":{"version":1,"requiredFeatures":[],"properties":{"optional":"retained"}}}');
    INSERT INTO knowledge_relation_types VALUES('memberOf',1,'{"key":"memberOf","version":1,"requiredFeatures":[],"optional":{"label":"Member of"}}');
    """)
    let reopened = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    try await reopened.validateCanonicalLogicalIntegrity()
    let backup = root.appendingPathComponent("backup.sqlite")
    try await reopened.backup(to: backup)
    try await reopened.close()
    let archived = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: backup, vaultID: vaultID, createIfMissing: false)
    try await archived.validateCanonicalLogicalIntegrity()
    try await archived.close()
}

@Test(arguments: ["{\"requiredFeatures\":[\"futureRequired\"]}", "{\"version\":2}", "{\"key\":\"wrongKey\"}", "{\"metadata\":{\"version\":1,\"requiredFeatures\":[\"futureRequired\"],\"properties\":{}}}"])
func schema5ExtraRegistryRejectsUnsupportedDescriptors(descriptor: String) async throws {
    let root = try schema5IntegrityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    try await store.close()
    try schema5IntegritySQL(url, "INSERT INTO knowledge_entity_types VALUES('organization',1,'\(descriptor)')")
    #expect(throws: VaultError.self) {
        try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    }
}

@Test func schema5LogicalValidationChecksEntitiesBeyondSearchLimit() async throws {
    let root = try schema5IntegrityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: UUID())
    let entity = try await store.createEntity(.init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!, typeKey: "person", label: "Fixture"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    try schema5IntegritySQL(url, """
    WITH RECURSIVE ids(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM ids WHERE n<1001)
    INSERT INTO knowledge_entities SELECT printf('%08X-0000-4000-8000-000000000000',n),type_key,revision,lifecycle,payload FROM ids,knowledge_entities WHERE id='\(entity.value.entity.id.uuidString)';
    UPDATE knowledge_entities SET payload='{}' WHERE id='000003E9-0000-4000-8000-000000000000';
    """)
    #expect(try await store.searchEntities(query: "", limit: 1000).count == 1000)
    try await store.validateIntegrity()
    await #expect(throws: (any Error).self) { try await store.validateCanonicalLogicalIntegrity() }
    try await store.close()
}

@Test func schema5LogicalValidationChecksDisconnectedObjectsAndRelations() async throws {
    let root = try schema5IntegrityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: UUID())
    let source = try await store.createEntity(.init(typeKey: "person", label: "Source"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let target = try await store.createEntity(.init(typeKey: "person", label: "Target"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let relation = try await store.createRelation(.init(sourceID: source.entity.id, targetID: target.entity.id), expectedSource: source.revision, expectedTarget: target.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let object = try await store.createObject(.init(typeKey: "question"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    try await store.validateCanonicalLogicalIntegrity()
    try schema5IntegritySQL(url, "UPDATE semantic_objects SET payload='{}' WHERE id='\(object.object.id.uuidString)'")
    try await store.validateIntegrity()
    await #expect(throws: (any Error).self) { try await store.validateCanonicalLogicalIntegrity() }
    try schema5IntegritySQL(url, "DELETE FROM semantic_objects; UPDATE knowledge_relations SET payload='{}' WHERE id='\(relation.relation.id.uuidString)'")
    try await store.validateIntegrity()
    await #expect(throws: (any Error).self) { try await store.validateCanonicalLogicalIntegrity() }
    try await store.close()
}

@Test(arguments: [AnnotationDisposition.stale, .deleted])
func schema5LogicalValidationPreservesCapturedAnnotationsWithoutLivePage(disposition: AnnotationDisposition) async throws {
    let root = try schema5IntegrityRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    let page = UUID(), block = UUID()
    let annotation = SemanticAnnotation(location: .wholeBlock(pageID: page, blockID: block),
        referent: .init(identity: .init(kind: "legacy", id: UUID()), disposition: .unresolved),
        designation: "preserved", anchorDisposition: disposition)
    let payload = try String(decoding: JSONEncoder().encode(annotation), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    try schema5IntegritySQL(url, "INSERT INTO semantic_annotations(id,revision,location_kind,captured_page,captured_block,payload) VALUES('\(annotation.id.uuidString)',X'01','wholeBlock','\(page.uuidString)','\(block.uuidString)','\(payload)')")
    try await store.validateCanonicalLogicalIntegrity()
    #expect(try await store.annotationsNeedingReview().first?.annotation == annotation)
    try await store.close()
    let reopened = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    try await reopened.validateCanonicalLogicalIntegrity()
    try await reopened.close()
}
