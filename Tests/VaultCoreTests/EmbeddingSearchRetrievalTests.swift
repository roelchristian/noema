import Foundation
import Darwin
import SQLite3
import Synchronization
import Testing
@testable import VaultCore

private struct RetrievalFixture: Sendable {
    let index: SQLiteEmbeddingIndex
    let generation: EmbeddingIndexGeneration
    let lease: VaultSessionLease
    let gate: VaultAccessGate
    let database: URL

    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-07-retrieval/fixtures/\(UUID())")
        let session = VaultSession(vaultID: UUID(), root: root.appendingPathComponent("canonical"), generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let model = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "retrieval", revision: "1",
            dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10)
        let generation = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: model, chunkingVersion: "1")
        let support = root.appendingPathComponent("support")
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: session.lease, accessGate: gate)
        try await index.declareGeneration(generation: generation)
        return Self(index: index, generation: generation, lease: session.lease, gate: gate,
            database: support.appendingPathComponent("KnowledgeVault/\(session.vaultID.uuidString)/semantic.sqlite"))
    }
    var query: EmbeddingVector { get throws { try EmbeddingVector(values: [1, 0, 0], model: generation.model) } }
    func sql(_ body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw EmbeddingIndexError.unavailable }
        defer { sqlite3_close(handle) }
        try body(handle)
    }
    func execute(_ sql: String) throws { try self.sql { db in
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw EmbeddingIndexError.unavailable }
    } }
    /// Synthetic derived-store fixtures deliberately use an independent test-only writer.
    /// Production retrieval/publication never obtains this connection.
    func seed(documents: Int = 1, chunks: Int = 1, kind: AIEntityKind = .page,
              completed: Bool = true, start: Int = 1) throws -> [UUID] {
        var ids: [UUID] = []
        try sql { db in
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw EmbeddingIndexError.unavailable }
            defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
            var chunkStatement: OpaquePointer?, documentStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO embedding_chunks VALUES(?,?,?,?,?,?,?)", -1, &chunkStatement, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "INSERT INTO embedding_documents VALUES(?,?,?,?,?)", -1, &documentStatement, nil) == SQLITE_OK,
                  let chunkStatement, let documentStatement else { throw EmbeddingIndexError.unavailable }
            defer { sqlite3_finalize(chunkStatement); sqlite3_finalize(documentStatement) }
            // SQL identifiers must be TEXT, matching the production writer.
            func text(_ statement: OpaquePointer, _ offset: Int32, _ value: String) {
                _ = value.withCString { sqlite3_bind_text(statement, offset, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }
            for number in start..<(start + documents) {
                let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
                ids.append(id)
                for ordinal in 0..<chunks {
                    let chunkID = "block/\(id.uuidString)/\(ordinal)"
                    let metadata: [String: Any] = ["entityKind": kind.rawValue, "entityID": id.uuidString,
                        "revision": "r1", "chunkID": chunkID, "fingerprint": "fingerprint", "chunkingVersion": "1", "ordinal": ordinal]
                    sqlite3_reset(chunkStatement)
                    text(chunkStatement, 1, generation.id.uuidString); text(chunkStatement, 2, kind.rawValue)
                    text(chunkStatement, 3, id.uuidString); text(chunkStatement, 4, chunkID)
                    sqlite3_bind_int64(chunkStatement, 5, Int64(ordinal))
                    for (column, value) in [(Int32(6), try JSONSerialization.data(withJSONObject: metadata)),
                                            (Int32(7), try query.encodedFloat32LittleEndian())] {
                        _ = value.withUnsafeBytes { sqlite3_bind_blob(chunkStatement, column, $0.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                    }
                    guard sqlite3_step(chunkStatement) == SQLITE_DONE else { throw EmbeddingIndexError.unavailable }
                }
                if completed {
                    sqlite3_reset(documentStatement)
                    text(documentStatement, 1, generation.id.uuidString); text(documentStatement, 2, kind.rawValue)
                    text(documentStatement, 3, id.uuidString); sqlite3_bind_int64(documentStatement, 4, Int64(chunks))
                    let metadata = try JSONSerialization.data(withJSONObject: ["entityKind": kind.rawValue, "entityID": id.uuidString,
                        "revision": "r1", "workRevision": "r1", "inputFingerprint": digest(Data((0..<chunks).map { "block/\(id.uuidString)/\($0):fingerprint" }.joined(separator: "\n").utf8)), "chunkCount": chunks])
                    _ = metadata.withUnsafeBytes { sqlite3_bind_blob(documentStatement, 5, $0.baseAddress, Int32(metadata.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                    guard sqlite3_step(documentStatement) == SQLITE_DONE else { throw EmbeddingIndexError.unavailable }
                }
            }
        }
        return ids
    }
    func search(limit: Int = 20, passages: Int = 3, kind: AIEntityKind? = nil,
                isCurrent: @Sendable (EmbeddingDocumentCompletion) throws -> Bool = { _ in true },
                validateQuery: @Sendable () throws -> Void = {}) async throws -> [SemanticSearchCandidate] {
        try await index.searchCandidates(query: query, generation: generation, documentLimit: limit,
            passagesPerDocument: passages, kind: kind, isCurrent: isCurrent, validateQuery: validateQuery)
    }
}

@Test func embeddingSearchRetrievalEmptyAndZeroChunkDocuments() async throws {
    let f = try await RetrievalFixture.make()
    #expect(try await f.search().isEmpty)
    _ = try f.seed(chunks: 0)
    #expect(try await f.search().isEmpty)
}

@Test func embeddingSearchRetrievalCompletedOnlyAndMetadataEvidence() async throws {
    let f = try await RetrievalFixture.make()
    let expected = try f.seed(chunks: 5)
    _ = try f.seed(completed: false, start: 2)
    let matches = try await f.search(passages: 2)
    #expect(matches.count == 1)
    #expect(matches[0].identity.entityID == expected[0])
    #expect(matches[0].completion.chunkCount == 5)
    #expect(matches[0].passages.map(\.chunk.ordinal) == [0, 1])
    #expect(matches[0].cosineSimilarity == 1)
}

@Test func embeddingSearchRetrievalDiversifiesAndOrdersTies() async throws {
    let f = try await RetrievalFixture.make()
    let ids = try f.seed(documents: 5, chunks: 20)
    let results = try await f.search(limit: 3, passages: 2)
    #expect(results.map(\.identity.entityID) == Array(ids.prefix(3)))
    #expect(results.allSatisfy { $0.passages.count == 2 })
    #expect(try await f.search(limit: 3, passages: 2) == results)
}

@Test func embeddingSearchRetrievalKindsAndCurrentCompletionPredicate() async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed(kind: .page)
    let sources = try f.seed(kind: .source)
    let results = try await f.search(kind: .source, isCurrent: { $0.workRevision == "r1" && $0.inputFingerprint.count == 64 })
    #expect(results.map(\.identity.entityID) == sources)
    #expect(results.allSatisfy { $0.identity.entityKind == .source })
    #expect(try await f.search(isCurrent: { _ in false }).isEmpty)
}

@Test(arguments: ["vector=X'01'", "vector=zeroblob(1048576)", "metadata=zeroblob(65536)", "vector=zeroblob(12)", "vector=X'0000C07F0000000000000000'", "metadata=X'00'", "ordinal=99"])
func embeddingSearchRetrievalDamagedChunkExcludesEntireDocument(mutation: String) async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed(documents: 2, chunks: 2)
    try f.execute("UPDATE embedding_chunks SET \(mutation) WHERE entity_id='00000000-0000-0000-0000-000000000001' AND ordinal=1")
    let results = try await f.search()
    #expect(results.count == 1)
    #expect(results[0].identity.entityID.uuidString.hasSuffix("000002"))
}

@Test(arguments: ["chunk_count=3", "metadata=X'00'"])
func embeddingSearchRetrievalDamagedCompletionExcluded(mutation: String) async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed(chunks: 2)
    try f.execute("UPDATE embedding_documents SET \(mutation)")
    #expect(try await f.search().isEmpty)
}

@Test func embeddingSearchRetrievalRemovedAndReplacedDocument() async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed()
    let original = try await f.search()
    try await f.index.removeDocument(identity: original[0].identity, generation: f.generation, validatePublication: {})
    #expect(try await f.search().isEmpty)
    _ = try f.seed()
    try f.execute("UPDATE embedding_chunks SET metadata=CAST(replace(CAST(metadata AS TEXT),'r1','r2') AS BLOB)")
    #expect(try await f.search().isEmpty)
}

@Test func embeddingSearchRetrievalRejectsCompatibilityAndBounds() async throws {
    let f = try await RetrievalFixture.make()
    for model in [try EmbeddingModelDescriptor(providerID: "other", modelID: "retrieval", revision: "1", dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10),
                  try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "other", revision: "1", dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10),
                  try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "retrieval", revision: "2", dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10),
                  try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "retrieval", revision: "1", dimensions: 2, maximumInputUTF8Bytes: 128, maximumBatchSize: 10)] {
        let query = try EmbeddingVector(values: Array(repeating: 1, count: model.dimensions), model: model)
        await #expect(throws: EmbeddingContractError.incompatibleGeneration) {
            try await f.index.searchCandidates(query: query, generation: f.generation, isCurrent: { _ in true }, validateQuery: {})
        }
    }
    await #expect(throws: EmbeddingContractError.invalidInput) { try await f.search(limit: 0) }
    await #expect(throws: EmbeddingContractError.invalidInput) { try await f.search(passages: 11) }
    let other = try EmbeddingIndexGeneration(vaultID: UUID(), model: f.generation.model, chunkingVersion: "1")
    await #expect(throws: (any Error).self) {
        try await f.index.searchCandidates(query: f.query, generation: other, isCurrent: { _ in true }, validateQuery: {})
    }
}

@Test func embeddingSearchRetrievalRevocationAndCancellationDuringCursor() async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed(chunks: 100)
    let checks = Mutex(0)
    await #expect(throws: CancellationError.self) {
        try await f.search(validateQuery: { try checks.withLock { count in count += 1; if count == 50 { throw CancellationError() } } })
    }
    #expect(checks.withLock { $0 } == 50)
    #expect(try await f.search().count == 1) // aborted read transaction released
    await #expect(throws: (any Error).self) {
        try await f.search(isCurrent: { _ in f.gate.updateState(.closed); return true })
    }
}

@Test(arguments: [101, 201])
func embeddingSearchRetrievalBoundedHeapAndLargeCursor(documents: Int) async throws {
    var heap = EmbeddingSearchHeap<Int>(capacity: 7, precedes: >)
    for value in 0..<20_000 { heap.insert(value); #expect(heap.elements.count <= 7) }
    #expect(heap.sorted() == Array((19_993..<20_000).reversed()))
    let f = try await RetrievalFixture.make()
    _ = try f.seed(documents: documents, chunks: 101)
    var before = rusage(), after = rusage()
    #expect(getrusage(RUSAGE_SELF, &before) == 0)
    let started = ContinuousClock.now
    let results = try await f.search(limit: 7, passages: 2)
    let elapsed = started.duration(to: .now)
    #expect(getrusage(RUSAGE_SELF, &after) == 0)
    // Process high-water marks include fixture setup and other concurrently running tests.
    // Their difference is not an isolated query allocation or a portable memory budget.
    print("retrieval diagnostic: \(documents * 101) passages, \(documents) documents, 3 dimensions; elapsed=\(elapsed); retained results=\(results.count), passages=\(results.reduce(0) { $0 + $1.passages.count }); test_process_peak_rss_before_bytes=\(before.ru_maxrss), test_process_peak_rss_after_bytes=\(after.ru_maxrss)")
    #expect(results.count == 7)
    #expect(results.allSatisfy { $0.passages.count == 2 })
}

@Test func embeddingSearchRetrievalCountMismatchAndFinalCurrentness() async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed(chunks: 2)
    try f.execute("DELETE FROM embedding_chunks WHERE ordinal=1")
    #expect(try await f.search().isEmpty)
    try f.execute("DELETE FROM embedding_documents; DELETE FROM embedding_chunks")
    _ = try f.seed()
    let calls = Mutex(0)
    #expect(try await f.search(isCurrent: { _ in calls.withLock { $0 += 1; return $0 == 1 } }).isEmpty)
    #expect(calls.withLock { $0 } == 2)
}

@Test func embeddingSearchRetrievalActualTaskCancellationReleasesCursor() async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed(chunks: 100)
    let calls = Mutex(0)
    let task = Task {
        try await f.search(validateQuery: {
            calls.withLock { count in
                count += 1
                if count == 50 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(calls.withLock { $0 } == 50)
    #expect(try await f.search().count == 1)
}

@Test func embeddingSearchRetrievalRejectsPersistedDescriptorAndChunkerCollision() async throws {
    let f = try await RetrievalFixture.make()
    for generation in [try EmbeddingIndexGeneration(id: f.generation.id, vaultID: f.lease.vaultID,
                        model: f.generation.model, chunkingVersion: "other"),
                       try EmbeddingIndexGeneration(id: f.generation.id, vaultID: f.lease.vaultID,
                        model: EmbeddingModelDescriptor(providerID: "synthetic", modelID: "other", revision: "1",
                        dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 10), chunkingVersion: "1")] {
        let query = try EmbeddingVector(values: [1, 0, 0], model: generation.model)
        await #expect(throws: EmbeddingContractError.incompatibleGeneration) {
            try await f.index.searchCandidates(query: query, generation: generation, isCurrent: { _ in true }, validateQuery: {})
        }
    }
}

@Test func embeddingSearchRetrievalDocumentFingerprintMismatchExcluded() async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed(chunks: 2)
    try f.execute(#"UPDATE embedding_documents SET metadata=CAST(replace(CAST(metadata AS TEXT),'"inputFingerprint":"','"inputFingerprint":"wrong') AS BLOB)"#)
    #expect(try await f.search().isEmpty)
}

@Test func embeddingSearchRetrievalActualPartialCheckpointExcluded() async throws {
    let f = try await RetrievalFixture.make()
    _ = try f.seed(chunks: 2)
    try f.execute("INSERT INTO embedding_checkpoints SELECT * FROM embedding_documents; DELETE FROM embedding_documents")
    #expect(try await f.search().isEmpty)
}

@Test func embeddingSearchRetrievalMissingAndOversizedGenerationMetadata() async throws {
    let f = try await RetrievalFixture.make()
    let missing = try EmbeddingIndexGeneration(vaultID: f.lease.vaultID, model: f.generation.model, chunkingVersion: "1")
    #expect(try await f.index.searchCandidates(query: f.query, generation: missing,
        isCurrent: { _ in true }, validateQuery: {}).isEmpty)
    try f.execute("UPDATE embedding_generations SET metadata=zeroblob(1048576)")
    await #expect(throws: EmbeddingIndexError.invalidMetadata) { try await f.search() }
}
