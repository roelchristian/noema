import Foundation
import Synchronization
import SQLite3
import Testing
@testable import VaultCore

private func embeddingIndexFixture() throws -> (URL, VaultSessionLease, VaultAccessGate, EmbeddingIndexGeneration) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/sem-emb-sqlite-tests/fixtures/\(UUID())")
    let session = VaultSession(vaultID: UUID(), root: root.appendingPathComponent("canonical"), generation: 1)
    let gate = VaultAccessGate(); gate.updateState(.open(session))
    let model = try EmbeddingModelDescriptor(providerID: "mock", modelID: "sqlite-test", revision: "1",
        dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10)
    let generation = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: model, chunkingVersion: "1")
    return (root.appendingPathComponent("support"), session.lease, gate, generation)
}

private func embeddingIndexRecord(lease: VaultSessionLease, generation: EmbeddingIndexGeneration,
                                  kind: AIEntityKind, id: UUID = UUID(), revision: String = "r1") throws -> EmbeddingRecord {
    let identity = try EmbeddingEntityIdentity(vaultID: lease.vaultID, entityKind: kind, entityID: id, revision: revision)
    let chunk = try EmbeddingChunk(identity: identity, chunkID: "block/one", ordinal: 0,
        contentFingerprint: "fingerprint-\(revision)", chunkingVersion: "1")
    return try EmbeddingRecord(generation: generation, chunk: chunk,
        vector: EmbeddingVector(values: [1, 2, 3], model: generation.model))
}

@Test func sqliteEmbeddingIndexPersistsPagesSourcesAndAtomicallyReplaces() async throws {
    let (support, lease, gate, generation) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let page = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page)
    let source = try embeddingIndexRecord(lease: lease, generation: generation, kind: .source)
    for record in [page, source] {
        try await index.replaceDocument(identity: record.chunk.identity, generation: generation,
            records: [record], validatePublication: {})
    }
    let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    #expect(try await reopened.records(generation: generation).count == 2)
    let updated = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page,
        id: page.chunk.identity.entityID, revision: "r2")
    try await index.replaceDocument(identity: updated.chunk.identity, generation: generation,
        records: [updated], validatePublication: {})
    let records = try await reopened.records(generation: generation)
    #expect(records.contains(updated))
    #expect(!records.contains(page))
    #expect(records.contains(source))
    try await index.removeDocument(identity: updated.chunk.identity, generation: generation, validatePublication: {})
    #expect(try await index.records(generation: generation) == [source])
    try await index.removeGeneration(generation: generation, validatePublication: {})
    #expect(try await index.records(generation: generation).isEmpty)
}

@Test func sqliteEmbeddingIndexRejectsDuplicateChunksAndRollsBackRevokedPublication() async throws {
    let (support, lease, gate, generation) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let record = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page)
    try await index.replaceDocument(identity: record.chunk.identity, generation: generation,
        records: [record], validatePublication: {})
    await #expect(throws: (any Error).self) {
        try await index.replaceDocument(identity: record.chunk.identity, generation: generation,
            records: [record, record], validatePublication: {})
    }
    let calls = Mutex(0)
    await #expect(throws: (any Error).self) {
        try await index.replaceDocument(identity: record.chunk.identity, generation: generation,
            records: [], validatePublication: {
                try calls.withLock { count in
                    count += 1
                    if count > 1 { throw EmbeddingContractError.authorityDenied }
                }
            })
    }
    #expect(try await index.records(generation: generation) == [record])
    gate.updateState(.closed)
    await #expect(throws: (any Error).self) { try await index.records(generation: generation) }
}

@Test func sqliteEmbeddingIndexRejectsCanonicalPathBeforeOpening() throws {
    let (_, lease, gate, _) = try embeddingIndexFixture()
    #expect(throws: (any Error).self) {
        try SQLiteEmbeddingIndex(applicationSupportRoot: lease.root, lease: lease, accessGate: gate)
    }
}

@Test func sqliteEmbeddingIndexRejectsGenerationIDReuseWithDifferentModel() async throws {
    let (support, lease, gate, generation) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let record = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page)
    try await index.replaceDocument(identity: record.chunk.identity, generation: generation,
        records: [record], validatePublication: {})
    let otherModel = try EmbeddingModelDescriptor(providerID: "mock", modelID: "different-model", revision: "2",
        dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10)
    let collision = try EmbeddingIndexGeneration(id: generation.id, vaultID: lease.vaultID,
        model: otherModel, chunkingVersion: "1")
    let other = try embeddingIndexRecord(lease: lease, generation: collision, kind: .page)
    await #expect(throws: (any Error).self) {
        try await index.replaceDocument(identity: other.chunk.identity, generation: collision,
            records: [other], validatePublication: {})
    }
    #expect(try await index.records(generation: generation) == [record])
}

@Test func sqliteEmbeddingNearestFiltersStaleRevisionsAndEntityKinds() async throws {
    let (support, lease, gate, generation) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let page = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page)
    let source = try embeddingIndexRecord(lease: lease, generation: generation, kind: .source)
    for record in [page, source] {
        try await index.replaceDocument(identity: record.chunk.identity, generation: generation,
            records: [record], validatePublication: {})
    }
    let pageMatches = try await index.nearest(query: page.vector, generation: generation,
        kind: .page, isCurrent: { _ in true }, validateQuery: {})
    #expect(pageMatches.count == 1)
    #expect(pageMatches[0].record == page)
    #expect(abs(pageMatches[0].score - 1) < 1e-12)
    #expect(try await index.nearest(query: page.vector, generation: generation,
        isCurrent: { _ in false }, validateQuery: {}).isEmpty)
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await index.nearest(query: page.vector, generation: generation,
            isCurrent: { _ in true }, validateQuery: { throw EmbeddingContractError.authorityDenied })
    }
}

private func semanticDatabaseURL(_ support: URL, _ lease: VaultSessionLease) -> URL {
    support.appendingPathComponent("KnowledgeVault/\(lease.vaultID.uuidString)/semantic.sqlite")
}

private func withEmbeddingTestDatabase<T>(_ url: URL, _ operation: (OpaquePointer) throws -> T) throws -> T {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
        if let handle { sqlite3_close(handle) }
        throw EmbeddingIndexError.unavailable
    }
    defer { sqlite3_close(handle) }
    return try operation(handle)
}

private func embeddingTestSQL(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw EmbeddingIndexError.unavailable }
}

@Test func sqliteEmbeddingRejectsForeignAndUnsupportedSchemasWithoutChangingBytes() throws {
    for schema in ["CREATE TABLE foreign_payload(value TEXT)",
                   "CREATE TABLE embedding_generations(id TEXT); CREATE TABLE embedding_chunks(vector TEXT); PRAGMA user_version=1",
                   "CREATE TABLE future_payload(value TEXT); PRAGMA user_version=99"] {
        let (support, lease, gate, _) = try embeddingIndexFixture()
        let url = semanticDatabaseURL(support, lease)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withEmbeddingTestDatabase(url) { try embeddingTestSQL($0, schema) }
        let previous = try Data(contentsOf: url)
        #expect(throws: EmbeddingIndexError.unsupportedSchema) {
            try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
        }
        #expect(try Data(contentsOf: url) == previous)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
    }
}

@Test func sqliteEmbeddingCorruptionLeavesCanonicalAndFTSSearchAvailable() throws {
    let (support, lease, gate, _) = try embeddingIndexFixture()
    let semantic = semanticDatabaseURL(support, lease)
    try FileManager.default.createDirectory(at: semantic.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: lease.root, withIntermediateDirectories: true)
    let canonical = lease.root.appendingPathComponent("blocks.sqlite")
    let canonicalBytes = Data("preserved canonical sentinel".utf8)
    try canonicalBytes.write(to: canonical)
    let search = semantic.deletingLastPathComponent().appendingPathComponent("search.sqlite")
    try withEmbeddingTestDatabase(search) {
        try embeddingTestSQL($0, "CREATE VIRTUAL TABLE documents USING fts5(body); INSERT INTO documents VALUES('unaffected lexical needle')")
    }
    let corruptBytes = Data("corrupted embedding database".utf8)
    try corruptBytes.write(to: semantic)
    #expect(throws: (any Error).self) {
        try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    }
    #expect(try Data(contentsOf: semantic) == corruptBytes)
    #expect(try Data(contentsOf: canonical) == canonicalBytes)
    try withEmbeddingTestDatabase(search) { db in
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM documents WHERE documents MATCH 'needle'", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 1)
    }
    // Explicit removal is restricted to the synthetic corrupt projection fixture.
    try FileManager.default.removeItem(at: semantic)
    _ = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    #expect(try Data(contentsOf: canonical) == canonicalBytes)
}

@Test func sqliteEmbeddingStoresCompactBlobsAndRejectsDamagedVectors() async throws {
    let (support, lease, gate, generation) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let record = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page)
    try await index.replaceDocument(identity: record.chunk.identity, generation: generation, records: [record], validatePublication: {})
    try withEmbeddingTestDatabase(semanticDatabaseURL(support, lease)) { db in
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT typeof(vector),length(vector),typeof(metadata) FROM embedding_chunks", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "blob")
        #expect(sqlite3_column_int(statement, 1) == 12)
        #expect(String(cString: sqlite3_column_text(statement, 2)) == "blob")
        try embeddingTestSQL(db, "UPDATE embedding_chunks SET vector=x'00'")
    }
    await #expect(throws: (any Error).self) { try await index.records(generation: generation) }
}

@Test func sqliteEmbeddingInterruptedTransactionKeepsAcknowledgedRecord() async throws {
    let (support, lease, gate, generation) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let record = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page)
    try await index.replaceDocument(identity: record.chunk.identity, generation: generation, records: [record], validatePublication: {})
    try withEmbeddingTestDatabase(semanticDatabaseURL(support, lease)) {
        // Closing this separate connection without COMMIT simulates interrupted local publication.
        try embeddingTestSQL($0, "BEGIN IMMEDIATE; DELETE FROM embedding_chunks")
    }
    #expect(try await index.records(generation: generation) == [record])
}

@Test func sqliteEmbeddingEnumeratesIsolatedGenerationsAndDocumentRevisions() async throws {
    let (support, lease, gate, first) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let model = try EmbeddingModelDescriptor(providerID: "other", modelID: "space", revision: "2", dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10)
    let second = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: model, chunkingVersion: "1")
    let id = UUID()
    let older = try embeddingIndexRecord(lease: lease, generation: first, kind: .page, id: id, revision: "r1")
    let newer = try embeddingIndexRecord(lease: lease, generation: second, kind: .page, id: id, revision: "r2")
    for record in [older, newer] {
        try await index.replaceDocument(identity: record.chunk.identity, generation: record.generation, records: [record], validatePublication: {})
    }
    let generations = try await index.generations()
    #expect(generations.count == 2 && generations.contains(first) && generations.contains(second))
    #expect(try await index.indexedDocuments(generation: first) == [older.chunk.identity])
    #expect(try await index.records(generation: second) == [newer])
    try await index.removeGeneration(generation: first, validatePublication: {})
    #expect(try await index.generations() == [second])
    #expect(try await index.records(generation: second) == [newer])
}

@Test func sqliteEmbeddingNearestRejectsAuthorityAndLeaseRevokedDuringQuery() async throws {
    let (support, lease, gate, generation) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let record = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page)
    try await index.replaceDocument(identity: record.chunk.identity, generation: generation, records: [record], validatePublication: {})
    let checks = Mutex(0)
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await index.nearest(query: record.vector, generation: generation, isCurrent: { _ in true }, validateQuery: {
            try checks.withLock { count in
                count += 1
                if count > 1 { throw EmbeddingContractError.authorityDenied }
            }
        })
    }
    await #expect(throws: (any Error).self) {
        try await index.nearest(query: record.vector, generation: generation, isCurrent: { _ in gate.updateState(.closed); return true }, validateQuery: {})
    }
    await #expect(throws: (any Error).self) { try await index.generations() }
}

@Test func sqliteEmbeddingRejectsSymlinkToCanonicalBeforeCreatingIndex() throws {
    let (support, lease, gate, _) = try embeddingIndexFixture()
    try FileManager.default.createDirectory(at: lease.root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: support, withDestinationURL: lease.root)
    #expect(throws: EmbeddingIndexError.unsafeLocation) {
        try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    }
    #expect(!FileManager.default.fileExists(atPath: lease.root.appendingPathComponent("KnowledgeVault").path))
}

@Test func sqliteEmbeddingChunkDeletionIsScopedAndPublicationChecked() async throws {
    let (support, lease, gate, generation) = try embeddingIndexFixture()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    let page = try embeddingIndexRecord(lease: lease, generation: generation, kind: .page)
    let source = try embeddingIndexRecord(lease: lease, generation: generation, kind: .source)
    for record in [page, source] {
        try await index.replaceDocument(identity: record.chunk.identity, generation: generation, records: [record], validatePublication: {})
    }
    let calls = Mutex(0)
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await index.removeChunk(identity: page.chunk.identity, generation: generation, chunkID: page.chunk.chunkID, validatePublication: {
            try calls.withLock { count in
                count += 1
                if count > 1 { throw EmbeddingContractError.authorityDenied }
            }
        })
    }
    #expect(try await index.records(generation: generation).count == 2)
    try await index.removeChunk(identity: page.chunk.identity, generation: generation, chunkID: page.chunk.chunkID, validatePublication: {})
    #expect(try await index.records(generation: generation) == [source])
}

@Test func sqliteEmbeddingRejectsCanonicalRootSymlinkAlias() throws {
    let (support, lease, gate, _) = try embeddingIndexFixture()
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: lease.root, withDestinationURL: support)
    // Replacing the canonical root alias also invalidates the gate's captured root.
    #expect(throws: VaultAccessError.self) {
        try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: gate)
    }
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("KnowledgeVault").path))
}
