import Foundation
import SQLite3
import Synchronization
import Testing
@testable import VaultCore

private struct SourceAssociationFixture {
    let root: URL
    let vaultID: UUID
    let store: SQLiteBlockStore
    let source: CanonicalSourceSnapshot
    var url: URL { root.appendingPathComponent("blocks.sqlite") }
}

private func sourceAssociationRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("source-association-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func sourceAssociationPublish(root: URL, store: SQLiteBlockStore, vaultID: UUID, title: String = "Evidence") async throws -> CanonicalSourceSnapshot {
    let bytes = Data("Original evidence: \(title)".utf8), operation = UUID()
    var metadata = SourceMetadata(id: UUID(), title: title, capturedAt: "2026-10-16", originalFilename: "original.txt", originURL: "https://example.org/evidence", sha256: digest(bytes), fileSize: bytes.count, storedFilename: "original.txt")
    metadata.unknownFields["futureSource"] = .object(["keep": .bool(true)])
    let adapter = try PlaintextVaultContentStore(root: root)
    let receipt = try adapter.publishCanonicalOriginal(bytes, metadata: metadata, vaultID: vaultID, operationID: operation)
    _ = try await store.publishSourceAndPage(source: CanonicalSource(metadata: metadata), condition: .createOnly, operationID: operation, expectedVaultRevision: store.canonicalVaultRevision(), byteReceipt: receipt)
    return try await store.sourceSnapshot(id: metadata.id)
}

private func sourceAssociationFixture() async throws -> SourceAssociationFixture {
    let root = try sourceAssociationRoot(), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeAssociationStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    let source = try await sourceAssociationPublish(root: root, store: store, vaultID: vaultID)
    return .init(root: root, vaultID: vaultID, store: store, source: source)
}

private func sourceAssociationEntity(_ f: SourceAssociationFixture, type: String = "creativeWork") async throws -> KnowledgeEntitySnapshot {
    try await f.store.createEntity(.init(typeKey: type, label: "Entity \(type)"), expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
}

private func sourceAssociationLink(_ f: SourceAssociationFixture, entityID: UUID, sourceID: UUID? = nil, role: SourceEntityAssociationRole = .aboutEntity) async throws -> SourceEntityAssociationSnapshot {
    let source = try await f.store.sourceSnapshot(id: sourceID ?? f.source.source.id), entity = try await f.store.loadEntity(id: entityID)
    return try await f.store.linkSource(source.source.id, to: entityID, role: role, expectedSource: source.revision, expectedEntity: entity.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
}

private func sourceAssociationUnlink(_ f: SourceAssociationFixture, _ snapshot: SourceEntityAssociationSnapshot) async throws {
    let source = try await f.store.sourceSnapshot(id: snapshot.association.sourceID), entity = try await f.store.loadEntity(id: snapshot.association.entityID)
    _ = try await f.store.unlinkSourceAssociation(id: snapshot.association.id, expected: snapshot.revision, expectedSource: source.revision, expectedEntity: entity.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
}

@discardableResult private func sourceAssociationSQL(_ url: URL, _ sql: String) throws -> Int {
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

@Test func sourceEntityAssociationManyToManyUsesOneIdentityAndSurvivesReopen() async throws {
    let f = try await sourceAssociationFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let work = try await sourceAssociationEntity(f), otherWork = try await sourceAssociationEntity(f)
    let second = try await sourceAssociationPublish(root: f.root, store: f.store, vaultID: f.vaultID, title: "Another edition")
    let first = try await sourceAssociationLink(f, entityID: work.entity.id, role: .representsWork)
    let anthology = try await sourceAssociationLink(f, entityID: otherWork.entity.id, role: .representsWork)
    let edition = try await sourceAssociationLink(f, entityID: work.entity.id, sourceID: second.source.id, role: .representsWork)
    let subject = try await sourceAssociationLink(f, entityID: work.entity.id)
    let sourceRows = try await f.store.associationsForSource(id: f.source.source.id)
    #expect(Set(sourceRows.map(\.association.id)) == Set([first, anthology, subject].map(\.association.id)))
    let entityRows = try await f.store.sourcesForEntity(id: work.entity.id)
    #expect(Set(entityRows.map(\.association.id)) == Set([first, edition, subject].map(\.association.id)))
    #expect(entityRows.first { $0.association.id == first.association.id } == first)
    #expect(try sourceAssociationSQL(f.url, "SELECT count(*) FROM source_entity_associations") == 4)
    #expect(try await f.store.sourceSnapshot(id: f.source.source.id) == f.source)
    #expect(try await f.store.loadEntity(id: work.entity.id) == work)
    try await f.store.close()
    let reopened = try VaultStorageProvider.plaintext.makeAssociationStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    #expect(try await reopened.associationsForSource(id: f.source.source.id) == sourceRows)
    #expect(try await reopened.sourcesForEntity(id: work.entity.id) == entityRows)
    try await reopened.close()
}

@Test func sourceEntityAssociationRolesAcceptExactlyTheirRegisteredTargets() async throws {
    let f = try await sourceAssociationFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    for type in KnowledgeEntityType.initial.map(\.key) {
        let entity = try await sourceAssociationEntity(f, type: type)
        _ = try await sourceAssociationLink(f, entityID: entity.entity.id)
        if type == "creativeWork" { _ = try await sourceAssociationLink(f, entityID: entity.entity.id, role: .representsWork) }
        else {
            let before = try await f.store.canonicalVaultRevision()
            await #expect(throws: (any Error).self) { try await sourceAssociationLink(f, entityID: entity.entity.id, role: .representsWork) }
            #expect(try await f.store.canonicalVaultRevision() == before)
        }
    }
    #expect(try await f.store.associationsForSource(id: f.source.source.id).count == 6)
    #expect(SourceEntityAssociationRole(rawValue: "author") == nil)
    try await f.store.close()
}

@Test func sourceEntityAssociationRejectsDuplicatesForeignMissingAndStaleEndpointsWithoutMutation() async throws {
    let f = try await sourceAssociationFixture(), foreign = try await sourceAssociationFixture()
    defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: foreign.root) }
    let entity = try await sourceAssociationEntity(f), other = try await sourceAssociationEntity(foreign)
    let before = try await f.store.canonicalVaultRevision(), stale = BlockStoreRevision(token: Data("stale".utf8))
    for (sourceID, entityID, sourceRevision, entityRevision) in [
        (UUID(), entity.entity.id, f.source.revision, entity.revision),
        (foreign.source.source.id, entity.entity.id, foreign.source.revision, entity.revision),
        (f.source.source.id, other.entity.id, f.source.revision, other.revision),
        (f.source.source.id, UUID(), f.source.revision, entity.revision),
        (f.source.source.id, entity.entity.id, stale, entity.revision),
        (f.source.source.id, entity.entity.id, f.source.revision, stale)
    ] {
        await #expect(throws: (any Error).self) {
            try await f.store.linkSource(sourceID, to: entityID, role: .aboutEntity, expectedSource: sourceRevision, expectedEntity: entityRevision, expectedVaultRevision: before, operationID: UUID())
        }
        #expect(try await f.store.canonicalVaultRevision() == before)
    }
    let saved = try await sourceAssociationLink(f, entityID: entity.entity.id)
    let after = try await f.store.canonicalVaultRevision()
    await #expect(throws: (any Error).self) { try await sourceAssociationLink(f, entityID: entity.entity.id) }
    await #expect(throws: KnowledgeStoreError.staleRevision) {
        try await f.store.linkSource(f.source.source.id, to: entity.entity.id, role: .representsWork, expectedSource: f.source.revision, expectedEntity: entity.revision, expectedVaultRevision: before, operationID: UUID())
    }
    #expect(try await f.store.canonicalVaultRevision() == after)
    #expect(try await f.store.associationsForSource(id: f.source.source.id) == [saved])
    try await f.store.close(); try await foreign.store.close()
}

@Test func sourceEntityAssociationRollbackReplayAndUnlinkRevisionChecksAreAtomic() async throws {
    let f = try await sourceAssociationFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let entity = try await sourceAssociationEntity(f), before = try await f.store.canonicalVaultRevision(), operation = UUID()
    try sourceAssociationSQL(f.url, "CREATE TRIGGER fail_association_operation BEFORE INSERT ON knowledge_operations BEGIN SELECT RAISE(ABORT,'injected association failure'); END")
    await #expect(throws: (any Error).self) { try await sourceAssociationLink(f, entityID: entity.entity.id) }
    #expect(try await f.store.canonicalVaultRevision() == before)
    #expect(try await f.store.associationsForSource(id: f.source.source.id).isEmpty)
    try sourceAssociationSQL(f.url, "DROP TRIGGER fail_association_operation")
    let saved = try await f.store.linkSource(f.source.source.id, to: entity.entity.id, role: .aboutEntity, expectedSource: f.source.revision, expectedEntity: entity.revision, expectedVaultRevision: before, operationID: operation)
    await #expect(throws: (any Error).self) {
        try await f.store.linkSource(f.source.source.id, to: entity.entity.id, role: .representsWork, expectedSource: f.source.revision, expectedEntity: entity.revision, expectedVaultRevision: saved.vaultRevision, operationID: operation)
    }
    await #expect(throws: (any Error).self) {
        try await f.store.unlinkSourceAssociation(id: saved.value.association.id, expected: .init(token: Data("stale".utf8)), expectedSource: f.source.revision, expectedEntity: entity.revision, expectedVaultRevision: saved.vaultRevision, operationID: UUID())
    }
    try sourceAssociationSQL(f.url, "CREATE TRIGGER fail_association_operation BEFORE INSERT ON knowledge_operations BEGIN SELECT RAISE(ABORT,'injected unlink failure'); END")
    await #expect(throws: (any Error).self) { try await sourceAssociationUnlink(f, saved.value) }
    #expect(try await f.store.associationsForSource(id: f.source.source.id) == [saved.value])
    #expect(try await f.store.canonicalVaultRevision() == saved.vaultRevision)
    try sourceAssociationSQL(f.url, "DROP TRIGGER fail_association_operation")
    try await sourceAssociationUnlink(f, saved.value)
    #expect(try await f.store.associationsForSource(id: f.source.source.id).isEmpty)
    #expect(try await f.store.sourcesForEntity(id: entity.entity.id).isEmpty)
    #expect(try await f.store.sourceSnapshot(id: f.source.source.id) == f.source)
    #expect(try await f.store.loadEntity(id: entity.entity.id) == entity)
    try await f.store.close()
}

@Test func sourceEntityAssociationConcurrentWritersAndPaginationAreDeterministic() async throws {
    let f = try await sourceAssociationFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let entity = try await sourceAssociationEntity(f), before = try await f.store.canonicalVaultRevision()
    let other = try VaultStorageProvider.plaintext.makeAssociationStagingStore(url: f.url, vaultID: f.vaultID, createIfMissing: false)
    let successes = await withTaskGroup(of: Bool.self) { group in
        for store in [f.store, other] {
            group.addTask {
                do {
                    _ = try await store.linkSource(f.source.source.id, to: entity.entity.id, role: .aboutEntity, expectedSource: f.source.revision, expectedEntity: entity.revision, expectedVaultRevision: before, operationID: UUID())
                    return true
                } catch { return false }
            }
        }
        var count = 0
        for await success in group { if success { count += 1 } }
        return count
    }
    #expect(successes == 1)
    for _ in 0..<4 {
        let another = try await sourceAssociationEntity(f)
        _ = try await sourceAssociationLink(f, entityID: another.entity.id)
    }
    // Force a timestamp tie: UUID must be the stable tie-breaker.
    try sourceAssociationSQL(f.url, "UPDATE source_entity_associations SET created_at=100")
    let all = try await f.store.associationsForSource(id: f.source.source.id)
    #expect(all.map { $0.association.id.uuidString } == all.map { $0.association.id.uuidString }.sorted())
    let first = try await f.store.associationsForSource(id: f.source.source.id, limit: 2, offset: 0)
    let rest = try await f.store.associationsForSource(id: f.source.source.id, limit: 3, offset: 2)
    #expect(first + rest == all)
    #expect(try await f.store.associationsForSource(id: f.source.source.id, limit: 2, offset: 100).isEmpty)
    for (limit, offset) in [(0, 0), (1001, 0), (1, -1)] {
        await #expect(throws: (any Error).self) { try await f.store.associationsForSource(id: f.source.source.id, limit: limit, offset: offset) }
        await #expect(throws: (any Error).self) { try await f.store.sourcesForEntity(id: entity.entity.id, limit: limit, offset: offset) }
    }
    try await other.close(); try await f.store.close()
}

@Test func sourceEntityAssociationTrashTombstoneRestoreAndPurgeGatePreserveEvidence() async throws {
    let f = try await sourceAssociationFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let entity = try await sourceAssociationEntity(f), edge = try await sourceAssociationLink(f, entityID: entity.entity.id)
    _ = try await f.store.setFavourite(.init(kind: .source, itemID: f.source.source.id), favourite: true, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    let trashed = try await f.store.setSourceTrashed(id: f.source.source.id, expected: f.source.revision, trashed: true)
    let tombstoned = try await f.store.transitionEntity(id: entity.entity.id, to: .tombstoned, expected: entity.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(try await f.store.associationsForSource(id: f.source.source.id) == [edge])
    #expect(try await f.store.sourcesForEntity(id: entity.entity.id) == [edge])
    let before = try await f.store.canonicalVaultRevision(), organisation = try await f.store.organisationSnapshot(includingHidden: true)
    await #expect(throws: (any Error).self) { try await sourceAssociationLink(f, entityID: entity.entity.id, role: .representsWork) }
    await #expect(throws: (any Error).self) { try await f.store.purgeCanonicalEntity(id: f.source.source.id, kind: .source, expected: trashed.revision, expectedVaultRevision: before) }
    #expect(try await f.store.canonicalVaultRevision() == before)
    #expect(try await f.store.organisationSnapshot(includingHidden: true) == organisation)
    #expect(try await f.store.tombstone(id: f.source.source.id, kind: .source) == nil)
    #expect(try await f.store.sourceSnapshot(id: f.source.source.id) == trashed)
    let restored = try await f.store.setSourceTrashed(id: f.source.source.id, expected: trashed.revision, trashed: false)
    _ = try await f.store.transitionEntity(id: entity.entity.id, to: .live, expected: tombstoned.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    #expect(try await f.store.sourcesForEntity(id: entity.entity.id) == [edge])
    _ = try await f.store.setSourceTrashed(id: f.source.source.id, expected: restored.revision, trashed: true)
    let currentEntity = try await f.store.loadEntity(id: entity.entity.id)
    _ = try await f.store.transitionEntity(id: entity.entity.id, to: .tombstoned, expected: currentEntity.revision, expectedVaultRevision: f.store.canonicalVaultRevision(), operationID: UUID())
    // Explicit unlink is permitted even while both endpoints are inactive.
    try await sourceAssociationUnlink(f, edge)
    let current = try await f.store.sourceSnapshot(id: f.source.source.id)
    try await f.store.purgeCanonicalEntity(id: f.source.source.id, kind: .source, expected: current.revision, expectedVaultRevision: f.store.canonicalVaultRevision())
    #expect(try await f.store.tombstone(id: f.source.source.id, kind: .source) != nil)
    let metadata = try f.source.source.sourceMetadata()
    let original = f.root.appendingPathComponent("Sources/\(metadata.id.uuidString.lowercased())/\(metadata.storedFilename)")
    #expect(try Data(contentsOf: original) == Data("Original evidence: Evidence".utf8))
    try await f.store.close()
}

@Test func sourceEntityAssociationSQLRejectsInvalidRolesAndDanglingEndpoints() async throws {
    let f = try await sourceAssociationFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let person = try await sourceAssociationEntity(f, type: "person")
    let edge = try await sourceAssociationLink(f, entityID: person.entity.id)
    for sql in [
        "UPDATE source_entity_associations SET role='representsWork' WHERE id='\(edge.association.id)'",
        "UPDATE source_entity_associations SET entity_id='\(UUID())' WHERE id='\(edge.association.id)'",
        "UPDATE source_entity_associations SET source_id='\(UUID())' WHERE id='\(edge.association.id)'",
        "DELETE FROM sources WHERE id='\(f.source.source.id)'",
        "DELETE FROM knowledge_entities WHERE id='\(person.entity.id)'"
    ] { #expect(throws: (any Error).self) { try sourceAssociationSQL(f.url, sql) } }
    #expect(try await f.store.associationsForSource(id: f.source.source.id) == [edge])
    try await f.store.close()
}

@Test func sourceEntityAssociationNineUpgradeRollsBackAndPreservesTemplateAndUnknownData() async throws {
    let root = try sourceAssociationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let old = try VaultStorageProvider.plaintext.makeTemplateStagingStore(url: url, vaultID: vaultID)
    let source = try await sourceAssociationPublish(root: root, store: old, vaultID: vaultID)
    var entity = KnowledgeEntity(typeKey: "creativeWork", label: "Work")
    entity.unknownFields["futureEntity"] = .bool(true)
    let owner = try await old.createEntity(entity, expectedVaultRevision: old.canonicalVaultRevision(), operationID: UUID()).value
    let template = try await old.savePropertyTemplate(typeKey: "creativeWork", definitionIDs: [], expected: nil, expectedVaultRevision: old.canonicalVaultRevision(), operationID: UUID()).value
    try sourceAssociationSQL(url, "UPDATE vault_state SET extensions=CAST('{\"futureVault\":true}' AS BLOB)")
    let before = try await old.canonicalVaultRevision()
    await #expect(throws: KnowledgeStoreError.transitionRequired) { try await old.associationsForSource(id: source.source.id) }
    await #expect(throws: KnowledgeStoreError.staleRevision) { try await old.upgradeSourceEntityAssociationSchema(expectedVaultRevision: .init(token: Data("stale".utf8))) }
    try sourceAssociationSQL(url, "CREATE TRIGGER fail_association_migration BEFORE UPDATE ON vault_state BEGIN SELECT RAISE(ABORT,'injected association migration failure'); END")
    await #expect(throws: (any Error).self) { try await old.upgradeSourceEntityAssociationSchema(expectedVaultRevision: before) }
    #expect(try sourceAssociationSQL(url, "PRAGMA user_version") == 9)
    #expect(try await old.canonicalVaultRevision() == before)
    try sourceAssociationSQL(url, "DROP TRIGGER fail_association_migration")
    _ = try await old.upgradeSourceEntityAssociationSchema(expectedVaultRevision: before)
    #expect(try await old.associationsForSource(id: source.source.id).isEmpty)
    #expect(try await old.sourceSnapshot(id: source.source.id) == source)
    #expect(try await old.loadEntity(id: entity.id) == owner)
    #expect(try await old.loadPropertyTemplate(typeKey: "creativeWork") == template)
    #expect(try sourceAssociationSQL(url, "SELECT json_extract(CAST(extensions AS TEXT),'$.futureVault') FROM vault_state") == 1)
    try await old.close()
    let reopened = try VaultStorageProvider.plaintext.makeAssociationStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopened.sourceSnapshot(id: source.source.id) == source)
    try await reopened.close()
}

private final class AssociationOriginalReadProbe: VaultContentStore {
    let base: PlaintextVaultContentStore
    let originalReads = Mutex(0)
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data {
        if path.hasPrefix("Sources/") { originalReads.withLock { $0 += 1 } }
        return try base.read(at: path)
    }
    func changeToken(at path: String) throws -> VaultContentChangeToken? { try base.changeToken(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws { try base.write(data, at: path, condition: condition) }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.publishCanonicalOriginal(data, metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalOriginal(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalLinked(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
}

@Test func sourceEntityAssociationEditsLeaveSourcePageSearchEmbeddingAndAIObservationsUnchanged() async throws {
    let parent = try sourceAssociationRoot(); defer { try? FileManager.default.removeItem(at: parent) }
    let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
    let manifest = try FileVaultRepository.inspectManifest(at: root)
    let session = VaultSession(vaultID: manifest.id, root: root, generation: 1), gate = VaultAccessGate()
    gate.updateState(.open(session))
    let probe = try AssociationOriginalReadProbe(root: root)
    let repository = try FileVaultRepository.open(root: root, contentStore: probe, sessionLease: session.lease, accessGate: gate)
    let imported = try await repository.importSource(data: Data("Preserved searchable phrase".utf8), filename: "evidence.txt", title: "Evidence", originURL: nil)
    let page = try await repository.create(title: "Independent page", body: "Preserved page content", source: imported)
    let originalPage = try await repository.sqliteBlockStore.loadPage(pageID: page.id)
    let external = parent.appendingPathComponent("linked.txt")
    try Data("Externally owned original".utf8).write(to: external)
    let linked = try #require(try await repository.linkSources(at: external, maximumFiles: 1).first)
    let store = repository.sqliteBlockStore
    let owner = try await store.createEntity(.init(typeKey: "creativeWork", label: "Canonical work"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let importedBefore = try await store.sourceSnapshot(id: imported.id), linkedBefore = try await store.sourceSnapshot(id: linked.id)
    let baseline = try await repository.scan()
    let search = try SQLiteSearchIndex(url: parent.appendingPathComponent("search.sqlite"))
    try await search.reconcile(baseline)
    let changes = Mutex(0)
    await repository.setAIContentChangeHandler { _ in changes.withLock { $0 += 1 } }
    let model = try EmbeddingModelDescriptor(providerID: "mock", modelID: "association-preservation", revision: "1", dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10)
    let generation = try EmbeddingIndexGeneration(vaultID: manifest.id, model: model, chunkingVersion: "1")
    let embedding = try SQLiteEmbeddingIndex(applicationSupportRoot: parent.appendingPathComponent("Support"), lease: session.lease, accessGate: gate)
    let identity = try EmbeddingEntityIdentity(vaultID: manifest.id, entityKind: .source, entityID: imported.id, revision: "existing-content-revision")
    let chunk = try EmbeddingChunk(identity: identity, chunkID: "source/one", ordinal: 0, contentFingerprint: "existing-fingerprint", chunkingVersion: "1")
    let record = try EmbeddingRecord(generation: generation, chunk: chunk, vector: .init(values: [1, 2, 3], model: model))
    try await embedding.replaceDocument(identity: identity, generation: generation, records: [record], validatePublication: {})
    probe.originalReads.withLock { $0 = 0 }
    let first = try await store.linkSource(imported.id, to: owner.entity.id, role: .representsWork, expectedSource: importedBefore.revision, expectedEntity: owner.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    // A missing synthetic external original must not prevent metadata association edits.
    try FileManager.default.removeItem(at: external)
    let offline = try await store.linkSource(linked.id, to: owner.entity.id, role: .aboutEntity, expectedSource: linkedBefore.revision, expectedEntity: owner.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(try await store.associationsForSource(id: linked.id) == [offline])
    #expect(try await store.sourcesForEntity(id: owner.entity.id).count == 2)
    let metadataOnly = try await repository.scanSources()
    #expect(metadataOnly.sources.contains { $0.id == linked.id && $0.metadata == linked.metadata })
    #expect(probe.originalReads.withLock { $0 } == 0)
    var importedMetadata = metadataOnly
    importedMetadata.sources.removeAll { $0.id != imported.id }
    #expect(try await search.sourcesRequiringContent(in: importedMetadata).isEmpty)
    #expect(metadataOnly.sourceContentRevisions[imported.id] == baseline.sourceContentRevisions[imported.id])
    #expect(try await search.search("searchable", kind: .source).map(\.id) == [imported.id])
    #expect(try await store.sourceSnapshot(id: imported.id) == importedBefore)
    #expect(try await store.sourceSnapshot(id: linked.id) == linkedBefore)
    #expect(try await store.loadPage(pageID: page.id) == originalPage)
    #expect(try await embedding.records(generation: generation) == [record])
    #expect(changes.withLock { $0 } == 0)
    _ = try await store.unlinkSourceAssociation(id: first.association.id, expected: first.revision, expectedSource: importedBefore.revision, expectedEntity: owner.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    _ = try await store.unlinkSourceAssociation(id: offline.association.id, expected: offline.revision, expectedSource: linkedBefore.revision, expectedEntity: owner.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(changes.withLock { $0 } == 0)
    #expect(try await embedding.records(generation: generation) == [record])
    #expect(probe.originalReads.withLock { $0 } == 0)
    #expect(try FileVaultRepository.readSourceOriginal(imported, root: root, contentStore: probe) == Data("Preserved searchable phrase".utf8))
    try await store.close()
}

@Test func sourceEntityAssociationNativeArchiveRoundTripPreservesBothDirectionsAndOriginals() async throws {
    let parent = try sourceAssociationRoot(); defer { try? FileManager.default.removeItem(at: parent) }
    let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
    let manager = VaultSessionManager()
    let (_, _, repository) = try await manager.openRepository(root: root)
    let source = try await repository.importSource(data: Data("Archive original".utf8), filename: "original.txt", title: "Source", originURL: nil)
    let store = repository.sqliteBlockStore
    let entity = try await store.createEntity(.init(typeKey: "creativeWork", label: "Work"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let sourceBefore = try await store.sourceSnapshot(id: source.id)
    let edge = try await store.linkSource(source.id, to: entity.entity.id, role: .representsWork, expectedSource: sourceBefore.revision, expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let archive = parent.appendingPathComponent("Archive")
    _ = try await repository.archive(to: archive)
    let destination = parent.appendingPathComponent("Restored")
    let session = VaultSession(vaultID: repository.manifest.id, root: destination, generation: 1), gate = VaultAccessGate()
    gate.updateState(.open(session))
    _ = try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored", sessionLease: session.lease, accessGate: gate)
    let restoredManager = VaultSessionManager()
    let (_, _, restored) = try await restoredManager.openRepository(root: destination)
    #expect(try await restored.sqliteBlockStore.associationsForSource(id: source.id) == [edge])
    #expect(try await restored.sqliteBlockStore.sourcesForEntity(id: entity.entity.id) == [edge])
    #expect(try await restored.sqliteBlockStore.sourceSnapshot(id: source.id) == sourceBefore)
    #expect(try await restored.sqliteBlockStore.loadEntity(id: entity.entity.id) == entity)
    #expect(try FileVaultRepository.readSourceOriginal(source, root: destination, contentStore: restored.contentStore) == Data("Archive original".utf8))
    try await restored.sqliteBlockStore.close(); try await restoredManager.close()
    try await store.close(); try await manager.close()
}

private struct AssociationManifestFailureStore: VaultContentStore {
    let base: any VaultContentStore
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data { try base.read(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        if path == "vault.json" { throw VaultError.storage("Injected association manifest failure") }
        try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

@Test func sourceEntityAssociationManifestFailureResumeAndLeaseDenialPreserveRows() async throws {
    let root = try sourceAssociationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let vaultID = UUID(), url = root.appendingPathComponent("blocks.sqlite")
    let old = try VaultStorageProvider.plaintext.makeTemplateStagingStore(url: url, vaultID: vaultID)
    let source = try await sourceAssociationPublish(root: root, store: old, vaultID: vaultID)
    let entity = try await old.createEntity(.init(typeKey: "creativeWork", label: "Work"), expectedVaultRevision: old.canonicalVaultRevision(), operationID: UUID()).value
    let revision = try await old.canonicalVaultRevision()
    try await old.close()
    var manifest = VaultManifest(id: vaultID)
    manifest.storage?.schemaVersion = 9; manifest.storage?.requiredCapabilities = SQLiteBlockStore.templateRequiredCapabilities
    manifest.unknownFields["futureManifest"] = .bool(true)
    let content = try VaultStorageProvider.plaintext.makeStore(root: root), bytes = try JSONEncoder().encode(manifest)
    for directory in ["Removed Pages", "Conflicts"] { try content.createDirectory(at: directory) }
    try content.write(bytes, at: "vault.json", condition: .createOnly)
    let session = VaultSession(vaultID: vaultID, root: root, generation: 1), gate = VaultAccessGate()
    gate.updateState(.open(session))
    await #expect(throws: VaultError.self) {
        try await FileVaultRepository.upgradeSourceEntityAssociations(root: root, sessionLease: session.lease, accessGate: gate, expectedVaultRevision: revision, contentStore: AssociationManifestFailureStore(base: content))
    }
    #expect(try content.read(at: "vault.json") == bytes)
    #expect(throws: VaultError.self) { try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate) }
    let recovered = try await FileVaultRepository.resumeSourceEntityAssociationsUpgrade(root: root, sessionLease: session.lease, accessGate: gate)
    #expect(recovered.storage?.schemaVersion == 10)
    #expect(recovered.unknownFields == manifest.unknownFields)
    let repository = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate), store = repository.sqliteBlockStore
    let edge = try await store.linkSource(source.source.id, to: entity.entity.id, role: .representsWork, expectedSource: source.revision, expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let before = try await store.canonicalVaultRevision()
    gate.updateState(.closed)
    await #expect(throws: (any Error).self) { try await store.associationsForSource(id: source.source.id) }
    await #expect(throws: (any Error).self) { try await store.unlinkSourceAssociation(id: edge.association.id, expected: edge.revision, expectedSource: source.revision, expectedEntity: entity.revision, expectedVaultRevision: before, operationID: UUID()) }
    await #expect(throws: (any Error).self) { try await FileVaultRepository.resumeSourceEntityAssociationsUpgrade(root: root, sessionLease: session.lease, accessGate: gate) }
    try await store.close()
    gate.updateState(.open(session))
    let reopened = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
    #expect(try await reopened.sqliteBlockStore.canonicalVaultRevision() == before)
    #expect(try await reopened.sqliteBlockStore.associationsForSource(id: source.source.id) == [edge])
    try await reopened.sqliteBlockStore.close()
}
