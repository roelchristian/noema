import Foundation
import SQLite3
import Testing
@testable import VaultCore

private func organisationRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("organisation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func organisationSQLValue(_ url: URL, _ sql: String) throws -> Int32 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
        throw VaultError.storage("Test open failed")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw VaultError.storage(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw VaultError.storage("Test query failed") }
    return sqlite3_column_int(statement, 0)
}

@Test func favouritesAndContainersStayInTheVaultDatabase() async throws {
    let root = try organisationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    let vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: vaultID)
    let pageID = UUID()
    let page = try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("Vault owned")])]) , pageID: pageID, condition: .createOnly)
    let pageReference = OrganisationItemReference(kind: .page, itemID: pageID)
    let beforeFavourite = try await store.canonicalVaultRevision()
    let favourited = try await store.setFavourite(pageReference, favourite: true, expectedVaultRevision: beforeFavourite, operationID: UUID())
    #expect(favourited.value)
    #expect(try await store.load(pageID: pageID).revision == page.revision)
    #expect(try await store.canonicalVaultRevision() != beforeFavourite)
    try await store.close()

    let reopened = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopened.organisationSnapshot(includingHidden: false).favourites.map(\.reference) == [pageReference])
    #expect(try await reopened.load(pageID: pageID).document.blocks.map(\.text) == ["Vault owned"])

    var vault = try await reopened.canonicalVaultRevision()
    let reading = try await reopened.createContainer(kind: .collection, name: " Reading ", parentID: nil, expectedVaultRevision: vault, operationID: UUID())
    vault = reading.vaultRevision
    let research = try await reopened.createContainer(kind: .collection, name: "Research", parentID: nil, expectedVaultRevision: vault, operationID: UUID())
    vault = research.vaultRevision
    #expect(reading.value.name == "Reading" && reading.value.parentID == nil)
    await #expect(throws: VaultError.self) {
        try await reopened.createContainer(kind: .collection, name: "Nested", parentID: reading.value.id, expectedVaultRevision: vault, operationID: UUID())
    }
    #expect(try await reopened.canonicalVaultRevision() == vault)

    let inReading = try await reopened.addMembership(containerID: reading.value.id, reference: pageReference, expectedVaultRevision: vault, operationID: UUID())
    vault = inReading.vaultRevision
    let inResearch = try await reopened.addMembership(containerID: research.value.id, reference: pageReference, expectedVaultRevision: vault, operationID: UUID())
    vault = inResearch.vaultRevision
    let entity = try await reopened.createEntity(KnowledgeFixtures.entities[0], expectedVaultRevision: vault, operationID: UUID())
    vault = entity.vaultRevision
    let entityReference = OrganisationItemReference(kind: .knowledgeEntity, itemID: entity.value.entity.id)
    let entityMembership = try await reopened.addMembership(containerID: research.value.id, reference: entityReference, expectedVaultRevision: vault, operationID: UUID())
    vault = entityMembership.vaultRevision
    #expect(try await reopened.load(pageID: pageID).document.blocks.count == 1)
    await #expect(throws: VaultError.self) {
        try await reopened.addMembership(containerID: research.value.id, reference: pageReference, expectedVaultRevision: vault, operationID: UUID())
    }
    #expect(try await reopened.canonicalVaultRevision() == vault)
    await #expect(throws: VaultError.self) {
        try await reopened.createContainer(kind: .folder, name: "Late", parentID: nil, expectedVaultRevision: BlockStoreRevision(token: Data("stale".utf8)), operationID: UUID())
    }

    let folder = try await reopened.createContainer(kind: .folder, name: "Notes", parentID: reading.value.id, expectedVaultRevision: vault, operationID: UUID())
    vault = folder.vaultRevision
    let nested = try await reopened.createContainer(kind: .folder, name: "Campaigns", parentID: folder.value.id, expectedVaultRevision: vault, operationID: UUID())
    vault = nested.vaultRevision
    await #expect(throws: VaultError.self) {
        try await reopened.moveContainer(id: folder.value.id, parentID: nested.value.id, index: 0, expected: folder.value.revision, expectedVaultRevision: vault, operationID: UUID())
    }
    #expect(try await reopened.canonicalVaultRevision() == vault)

    let removed = try await reopened.deleteContainer(id: reading.value.id, expected: reading.value.revision, expectedVaultRevision: vault, operationID: UUID())
    vault = removed.vaultRevision
    let afterDelete = try await reopened.organisationSnapshot(includingHidden: false)
    #expect(try await reopened.load(pageID: pageID).document.blocks[0].text == "Vault owned")
    #expect(afterDelete.containers.contains { $0.id == research.value.id })
    #expect(!afterDelete.containers.contains { $0.id == reading.value.id || $0.id == folder.value.id || $0.id == nested.value.id })
    #expect(afterDelete.memberships.contains { $0.containerID == research.value.id && $0.reference == pageReference })
    #expect(afterDelete.memberships.contains { $0.reference == entityReference })

    let trashed = try await reopened.setTrashed(pageID: pageID, expected: page.revision, trashed: true)
    let hidden = try await reopened.organisationSnapshot(includingHidden: true)
    let listed = try await reopened.organisationSnapshot(includingHidden: false)
    #expect(hidden.favourites.contains { $0.reference == pageReference })
    #expect(hidden.memberships.contains { $0.reference == pageReference })
    #expect(!listed.favourites.contains { $0.reference == pageReference })
    #expect(!listed.memberships.contains { $0.reference == pageReference })
    #expect(listed.memberships.contains { $0.reference == entityReference })
    let restored = try await reopened.setTrashed(pageID: pageID, expected: trashed.revision, trashed: false)
    #expect(try await reopened.organisationSnapshot(includingHidden: false).favourites.contains { $0.reference == pageReference })
    let trashedAgain = try await reopened.setTrashed(pageID: pageID, expected: restored.revision, trashed: true)
    try await reopened.purgeCanonicalEntity(id: pageID, kind: .page, expected: trashedAgain.revision, expectedVaultRevision: reopened.canonicalVaultRevision())
    let purged = try await reopened.organisationSnapshot(includingHidden: true)
    #expect(!purged.favourites.contains { $0.reference.itemID == pageID })
    #expect(!purged.memberships.contains { $0.reference.itemID == pageID })
    #expect(purged.memberships.contains { $0.reference == entityReference })
    #expect(try await reopened.loadEntity(id: entity.value.entity.id).entity.id == entity.value.entity.id)
    try await reopened.close()

    #expect(try organisationSQLValue(url, "PRAGMA user_version") == Int32(SQLiteBlockStore.organisationSchemaVersion))
    #expect(try organisationSQLValue(url, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name LIKE 'organisation_%'") == 3)
}

@Test func schema5OpenDoesNotGrowOrganisationTables() async throws {
    let root = try organisationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: UUID())
    await #expect(throws: VaultError.self) { try await store.organisationSnapshot(includingHidden: false) }
    try await store.close()
    let reopened = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: UUID(), createIfMissing: false)
    try await reopened.close()
    #expect(try organisationSQLValue(url, "PRAGMA user_version") == Int32(SQLiteBlockStore.semanticSchemaVersion))
    #expect(try organisationSQLValue(url, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name LIKE 'organisation_%'") == 0)
}

@Test func organisationWritesRejectARevokedVaultLease() async throws {
    let root = try organisationRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = VaultSessionManager()
    let session = try await manager.open(root: root) { _ in UUID() }
    let url = root.appendingPathComponent("blocks.sqlite")
    let staging = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: session.vaultID)
    try await staging.close()
    let store = try SQLiteBlockStore(url: url, sessionLease: session.lease, accessGate: manager.accessGate, canonicalVaultID: session.vaultID)
    let pageID = UUID()
    let page = try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("leased")])]) , pageID: pageID, condition: .createOnly)
    let vault = try await store.canonicalVaultRevision()
    try await manager.lock()
    await #expect(throws: VaultAccessError.self) {
        try await store.setFavourite(OrganisationItemReference(kind: .page, itemID: pageID), favourite: true, expectedVaultRevision: vault, operationID: UUID())
    }
    try await store.close()
    let inspection = try VaultStorageProvider.plaintext.makeOrganisationStagingStore(url: url, vaultID: session.vaultID, createIfMissing: false)
    #expect(try await inspection.load(pageID: pageID) == page)
    #expect(try await inspection.organisationSnapshot(includingHidden: true).favourites.isEmpty)
    try await inspection.close()
}
