import Foundation
import SQLite3
import Synchronization
import Testing
@testable import VaultCore

private struct CompletionFixture: Sendable {
    let root: URL, support: URL
    let session: VaultSession
    let gate: VaultAccessGate
    let store: SQLiteBlockStore
    let index: SQLiteEmbeddingIndex
    let generation: EmbeddingIndexGeneration
    let snapshot: BlockStoreSnapshot
    let identity: EmbeddingEntityIdentity
    var database: URL { support.appendingPathComponent("KnowledgeVault/\(session.vaultID.uuidString)/semantic.sqlite") }
    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-04b/fixtures/\(UUID())")
        let canonical = root.appendingPathComponent("canonical")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        let session = VaultSession(vaultID: UUID(), root: canonical, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let store = try SQLiteBlockStore(canonicalStagingURL: canonical.appendingPathComponent("blocks.sqlite"),
            vaultID: session.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
            schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
        let snapshot = try await store.save(BlockDocumentCodec.decode(""), pageID: UUID(), condition: .createOnly)
        let model = try EmbeddingModelDescriptor(providerID: "mock", modelID: "completion", revision: "1",
            dimensions: 2, maximumInputUTF8Bytes: 128, maximumBatchSize: 1)
        let generation = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: model, chunkingVersion: "1")
        let identity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page,
            entityID: snapshot.pageID, revision: snapshot.revision.token.base64EncodedString())
        let support = root.appendingPathComponent("support")
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: session.lease, accessGate: gate)
        return Self(root: root, support: support, session: session, gate: gate, store: store, index: index,
                    generation: generation, snapshot: snapshot, identity: identity)
    }
    func record() throws -> EmbeddingRecord {
        try EmbeddingRecord(generation: generation,
            chunk: EmbeddingChunk(identity: identity, chunkID: "block", ordinal: 0, contentFingerprint: "chunk", chunkingVersion: "1"),
            vector: EmbeddingVector(values: [1, 2], model: generation.model))
    }
    func completion(count: Int, fingerprint: String = "document") -> EmbeddingDocumentCompletion {
        EmbeddingDocumentCompletion(identity: identity, workRevision: identity.revision, inputFingerprint: fingerprint, chunkCount: count)
    }
    func publish(_ records: [EmbeddingRecord], completion: EmbeddingDocumentCompletion,
                 validation: @escaping @Sendable () throws -> Void = {}) async throws {
        let permit = try await store.embeddingPublicationPermit(pageID: snapshot.pageID, expected: snapshot.revision)
        let authority = try EmbeddingPublicationAuthority(accessGate: gate, lease: session.lease, generation: generation)
        try await index.replaceDocument(identity: identity, generation: generation, records: records,
            permit: permit, authority: authority, completion: completion, validatePublication: validation)
    }
}

private func completionSQL(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw EmbeddingIndexError.unavailable }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw EmbeddingIndexError.unavailable }
}
private func completionInteger(_ url: URL, _ sql: String) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw EmbeddingIndexError.unavailable }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw EmbeddingIndexError.unavailable }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw EmbeddingIndexError.unavailable }
    return Int(sqlite3_column_int64(statement, 0))
}

@Test func embeddingCompletionEmptyDocumentSurvivesReopen() async throws {
    let f = try await CompletionFixture.make()
    let completion = f.completion(count: 0)
    try await f.publish([], completion: completion)
    let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: f.support, lease: f.session.lease, accessGate: f.gate)
    #expect(try await reopened.completedDocuments(generation: f.generation) == [completion])
    #expect(try await reopened.records(generation: f.generation).isEmpty)
    #expect(try completionInteger(f.database, "PRAGMA user_version") == 3)
    try await f.store.close()
}

@Test func embeddingCompletionRollbackPreservesPreviousEvidenceAndVectors() async throws {
    let f = try await CompletionFixture.make()
    let record = try f.record(), original = f.completion(count: 1)
    try await f.publish([record], completion: original)
    let validations = Mutex(0)
    await #expect(throws: (any Error).self) {
        try await f.publish([], completion: f.completion(count: 0), validation: {
            try validations.withLock { count in
                count += 1
                if count == 2 { throw EmbeddingContractError.authorityDenied }
            }
        })
    }
    #expect(try await f.index.completedDocuments(generation: f.generation) == [original])
    #expect(try await f.index.records(generation: f.generation) == [record])
    await #expect(throws: EmbeddingIndexError.invalidMetadata) {
        try await f.publish([], completion: f.completion(count: 1))
    }
    await #expect(throws: EmbeddingIndexError.invalidMetadata) {
        try await f.publish([], completion: f.completion(count: 0, fingerprint: ""))
    }
    try await f.store.close()
}

@Test func embeddingCompletionRemovalInvalidatesEvidenceAcrossGenerations() async throws {
    let f = try await CompletionFixture.make()
    let record = try f.record()
    try await f.publish([record], completion: f.completion(count: 1))
    try await f.index.removeChunk(identity: f.identity, generation: f.generation, chunkID: "block", validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    try await f.publish([], completion: f.completion(count: 0))
    try await f.index.removeDocument(identity: f.identity, generation: f.generation, validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    let second = try EmbeddingIndexGeneration(vaultID: f.session.vaultID, model: f.generation.model, chunkingVersion: "1")
    let permit = try await f.store.embeddingPublicationPermit(pageID: f.snapshot.pageID, expected: f.snapshot.revision)
    let authority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: second)
    try await f.index.replaceDocument(identity: f.identity, generation: second, records: [], permit: permit,
        authority: authority, completion: f.completion(count: 0), validatePublication: {})
    try await f.publish([record], completion: f.completion(count: 1))
    try await f.index.removeEntity(identity: f.identity, validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: second).isEmpty)
    #expect(try await f.index.records(generation: f.generation).isEmpty)
    try await f.publish([], completion: f.completion(count: 0))
    try await f.index.removeGeneration(generation: f.generation, validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    try await f.store.close()
}

@Test func embeddingCompletionStartupReconcilesEmptyDeletedAndStaleWithoutInference() async throws {
    let f = try await CompletionFixture.make()
    let completion = f.completion(count: 0)
    try await f.publish([], completion: completion)
    let current = AIContentChange(vaultID: f.session.vaultID, entityKind: .page, entityID: f.identity.entityID,
        revision: f.identity.revision)
    try await f.index.reconcile(current: [current], validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: f.generation) == [completion])
    let checks = Mutex(0)
    await #expect(throws: (any Error).self) {
        try await f.index.reconcile(current: [], validatePublication: {
            try checks.withLock { count in count += 1; if count == 2 { throw EmbeddingContractError.authorityDenied } }
        })
    }
    #expect(try await f.index.completedDocuments(generation: f.generation) == [completion])
    try await f.index.reconcile(current: [], validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    try await f.publish([f.record()], completion: f.completion(count: 1))
    let changed = AIContentChange(vaultID: f.session.vaultID, entityKind: .page, entityID: f.identity.entityID, revision: "changed")
    try await f.index.reconcile(current: [changed], validatePublication: {})
    #expect(try await f.index.records(generation: f.generation).isEmpty)
    try await f.store.close()
}

@Test func embeddingCompletionRejectsCorruptCountsAndIdentity() async throws {
    for mutation in ["UPDATE embedding_documents SET chunk_count=2", "DELETE FROM embedding_chunks",
                     "UPDATE embedding_chunks SET chunk_id='wrong'", "UPDATE embedding_documents SET entity_id='wrong'"] {
        let f = try await CompletionFixture.make()
        try await f.publish([f.record()], completion: f.completion(count: 1))
        try completionSQL(f.database, mutation)
        await #expect(throws: (any Error).self) { try await f.index.completedDocuments(generation: f.generation) }
        try await f.store.close()
    }
}

@Test func embeddingCompletionMigratesExactV1PreservingVectorsWithoutInventingCompletion() async throws {
    let f = try await CompletionFixture.make()
    let record = try f.record()
    try await f.index.replaceDocument(identity: f.identity, generation: f.generation, records: [record], validatePublication: {})
    // This is exactly the existing schema-1 fixture: same two tables, rows and vector blobs.
    try completionSQL(f.database, "DROP TABLE embedding_documents; DROP TABLE embedding_checkpoints; PRAGMA user_version=1")
    let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: f.support, lease: f.session.lease, accessGate: f.gate)
    #expect(try await reopened.records(generation: f.generation) == [record])
    #expect(try await reopened.completedDocuments(generation: f.generation).isEmpty)
    #expect(try completionInteger(f.database, "PRAGMA user_version") == 3)
    try await f.store.close()
}

@Test func embeddingCompletionInvalidV1MigrationRollsBackWithoutDroppingEvidence() async throws {
    let f = try await CompletionFixture.make()
    try await f.index.replaceDocument(identity: f.identity, generation: f.generation, records: [f.record()], validatePublication: {})
    try completionSQL(f.database, "DROP TABLE embedding_documents; DROP TABLE embedding_checkpoints; PRAGMA user_version=1; UPDATE embedding_chunks SET vector=x'00'")
    #expect(throws: (any Error).self) {
        try SQLiteEmbeddingIndex(applicationSupportRoot: f.support, lease: f.session.lease, accessGate: f.gate)
    }
    #expect(try completionInteger(f.database, "PRAGMA user_version") == 1)
    #expect(try completionInteger(f.database, "SELECT count(*) FROM sqlite_master WHERE name='embedding_documents'") == 0)
    #expect(try completionInteger(f.database, "SELECT length(vector) FROM embedding_chunks") == 1)
    try await f.store.close()
}

@Test func embeddingCompletionPreservesExactSourceWorkRevisionAndReconcilesIndependentBytes() async throws {
    let f = try await CompletionFixture.make()
    let bytes = Data("original source".utf8), operationID = UUID()
    let metadata = SourceMetadata(id: UUID(), title: "Source", capturedAt: "2026-10-16", originalFilename: "original.txt",
        originURL: nil, sha256: digest(bytes), fileSize: bytes.count, storedFilename: "original.txt")
    let adapter = try PlaintextVaultContentStore(root: f.session.root)
    let receipt = try adapter.publishCanonicalOriginal(bytes, metadata: metadata, vaultID: f.session.vaultID, operationID: operationID)
    let outcome = try await f.store.publishSourceAndPage(source: CanonicalSource(metadata: metadata), condition: .createOnly,
        operationID: operationID, expectedVaultRevision: f.store.canonicalVaultRevision(), byteReceipt: receipt)
    let canonical = outcome.sourceRevision.token.base64EncodedString()
    let identity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .source, entityID: metadata.id, revision: canonical)
    let workRevision = canonical + ":" + digest(bytes)
    let completion = EmbeddingDocumentCompletion(identity: identity, workRevision: workRevision, inputFingerprint: "empty-filtered-source", chunkCount: 0)
    let permit = try await f.store.embeddingPublicationPermit(sourceID: metadata.id, expected: outcome.sourceRevision)
    let authority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: f.generation)
    try await f.index.replaceDocument(identity: identity, generation: f.generation, records: [], permit: permit,
        authority: authority, completion: completion, validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: f.generation) == [completion])
    let current = AIContentChange(vaultID: f.session.vaultID, entityKind: .source, entityID: metadata.id, revision: workRevision)
    try await f.index.reconcile(current: [current], validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: f.generation) == [completion])
    let independentlyChanged = AIContentChange(vaultID: f.session.vaultID, entityKind: .source,
        entityID: metadata.id, revision: canonical + ":" + digest(Data("other original bytes".utf8)))
    try await f.index.reconcile(current: [independentlyChanged], validatePublication: {})
    #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    try await f.store.close()
}

@Test func embeddingCompletionMigratesExactV2PreservingCompletionAndVectors() async throws {
    let f = try await CompletionFixture.make()
    let record = try f.record(), completion = f.completion(count: 1)
    try await f.publish([record], completion: completion)
    try completionSQL(f.database, "DROP TABLE embedding_checkpoints; PRAGMA user_version=2")
    let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: f.support, lease: f.session.lease, accessGate: f.gate)
    #expect(try await reopened.records(generation: f.generation) == [record])
    #expect(try await reopened.completedDocuments(generation: f.generation) == [completion])
    #expect(try await reopened.documentCheckpoints(generation: f.generation).isEmpty)
    #expect(try completionInteger(f.database, "PRAGMA user_version") == 3)
    try await f.store.close()
}

@Test func embeddingCompletionInvalidV2MigrationPreservesFailureEvidence() async throws {
    let f = try await CompletionFixture.make()
    try await f.publish([f.record()], completion: f.completion(count: 1))
    try completionSQL(f.database, "DROP TABLE embedding_checkpoints; PRAGMA user_version=2; UPDATE embedding_documents SET chunk_count=2")
    #expect(throws: (any Error).self) {
        try SQLiteEmbeddingIndex(applicationSupportRoot: f.support, lease: f.session.lease, accessGate: f.gate)
    }
    #expect(try completionInteger(f.database, "PRAGMA user_version") == 2)
    #expect(try completionInteger(f.database, "SELECT count(*) FROM sqlite_master WHERE name='embedding_checkpoints'") == 0)
    #expect(try completionInteger(f.database, "SELECT chunk_count FROM embedding_documents") == 2)
    try await f.store.close()
}
