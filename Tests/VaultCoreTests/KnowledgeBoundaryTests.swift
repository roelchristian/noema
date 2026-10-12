import Foundation
import SQLite3
import Testing
@testable import VaultCore

private func knowledgeBoundaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-boundary-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func knowledgeBoundarySQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw VaultError.storage("Test open failed") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(database))) }
}

@Test func knowledgeAliasRelationalIdentityMismatchFailsClosed() async throws {
    let root = try knowledgeBoundaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    let store = try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: url, vaultID: UUID())
    let entity = KnowledgeFixtures.entities[0]
    let result = try await store.createEntity(entity, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    try knowledgeBoundarySQL(url, "UPDATE knowledge_entity_aliases SET id='\(UUID().uuidString)' WHERE entity_id='\(entity.id.uuidString)'")
    await #expect(throws: VaultError.self) { try await store.loadEntity(id: entity.id) }
    #expect(try await store.canonicalVaultRevision() == result.vaultRevision)
    try await store.close()
}

@Test func knowledgeLockedSessionDeniesReadsAndWritesAndPreservesRevisions() async throws {
    let root = try knowledgeBoundaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let staging = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    try await staging.close()
    let session = VaultSession(vaultID: vaultID, root: root, generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    var declaration = VaultCanonicalStorageDeclaration()
    declaration.schemaVersion = 5
    declaration.requiredCapabilities = SQLiteBlockStore.semanticRequiredCapabilities
    var manifest = VaultManifest(id: vaultID)
    manifest.formatVersion = 2; manifest.storageMode = .sqliteBlocks; manifest.storage = declaration
    let store = try VaultStorageProvider.plaintext.makeBlockStore(url: url, sessionLease: session.lease, accessGate: gate, createIfMissing: false, manifest: manifest)
    let created = try await store.createEntity(KnowledgeFixtures.entities[0], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    gate.updateState(.locked(vaultID: vaultID, root: session.root, vaultName: session.vaultName, generation: session.generation))
    await #expect(throws: VaultAccessError.self) { try await store.loadEntity(id: created.value.entity.id) }
    await #expect(throws: VaultAccessError.self) { try await store.searchEntities(query: "Napoleon", limit: 5) }
    let deniedID = UUID()
    await #expect(throws: VaultAccessError.self) {
        try await store.updateEntity(id: created.value.entity.id, patch: .init(label: "denied"), expected: created.value.revision, expectedVaultRevision: created.vaultRevision, operationID: deniedID)
    }
    try await store.close()
    let preserved = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await preserved.loadEntity(id: created.value.entity.id) == created.value)
    #expect(try await preserved.canonicalVaultRevision() == created.vaultRevision)
    #expect(try await preserved.committedKnowledgeEntityOperation(id: deniedID) == nil)
    try await preserved.close()
}
