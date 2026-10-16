import Foundation
import SQLite3
import Synchronization
import Testing
@testable import VaultCore

private struct SearchSafetyFixture: Sendable {
    let root: URL
    let session: VaultSession
    let gate: VaultAccessGate
    let store: SQLiteBlockStore
    let index: SQLiteEmbeddingIndex
    let generation: EmbeddingIndexGeneration
    let pages: [BlockStoreSnapshot]
    var database: URL { root.appendingPathComponent("support/KnowledgeVault/\(session.vaultID.uuidString)/semantic.sqlite") }

    static func make(vaultID: UUID = UUID()) async throws -> Self {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-07-safety/fixtures/\(UUID())")
        let canonical = root.appendingPathComponent("canonical")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        let session = VaultSession(vaultID: vaultID, root: canonical, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let store = try SQLiteBlockStore(canonicalStagingURL: canonical.appendingPathComponent("blocks.sqlite"),
            vaultID: vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
            schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
        var pages: [BlockStoreSnapshot] = []
        for text in ["first", "second"] {
            pages.append(try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun(text)])]), pageID: UUID(), condition: .createOnly))
        }
        let model = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "safety", revision: "1", dimensions: 2,
            maximumInputUTF8Bytes: 128, maximumBatchSize: 1)
        let generation = try EmbeddingIndexGeneration(vaultID: vaultID, model: model, chunkingVersion: "1")
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"), lease: session.lease, accessGate: gate)
        try await index.declareGeneration(generation: generation)
        return Self(root: root, session: session, gate: gate, store: store, index: index, generation: generation, pages: pages)
    }
    func permits() async throws -> [EmbeddingPublicationPermit] {
        var permits: [EmbeddingPublicationPermit] = []
        for page in pages { permits.append(try await store.embeddingPublicationPermit(pageID: page.pageID, expected: page.revision)) }
        return permits
    }
    func authority() throws -> EmbeddingPublicationAuthority {
        try EmbeddingPublicationAuthority(accessGate: gate, lease: session.lease, generation: generation)
    }
    func publish(count: Int = 1, partial: Bool = false) async throws {
        let page = pages[0]
        let identity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page, entityID: page.pageID,
            revision: page.revision.token.base64EncodedString())
        let records = try (0..<count).map { ordinal in
            try EmbeddingRecord(generation: generation,
                chunk: EmbeddingChunk(identity: identity, chunkID: "block/\(page.pageID)/\(ordinal)", ordinal: ordinal,
                    contentFingerprint: "fingerprint", chunkingVersion: "1"),
                vector: EmbeddingVector(values: [1, 0], model: generation.model))
        }
        let completion = EmbeddingDocumentCompletion(identity: identity, workRevision: identity.revision,
            inputFingerprint: digest(Data(records.map { $0.chunk.chunkID + ":" + $0.chunk.contentFingerprint }.joined(separator: "\n").utf8)), chunkCount: count)
        let checkpoint = EmbeddingDocumentCheckpoint(identity: identity, workRevision: identity.revision,
            inputFingerprint: completion.inputFingerprint, chunkCount: count)
        let permit = try await store.embeddingPublicationPermit(pageID: page.pageID, expected: page.revision)
        try await index.replaceDocument(identity: identity, generation: generation, records: records,
            permit: permit, authority: authority(), completion: partial ? nil : completion,
            checkpoint: partial ? checkpoint : nil, validatePublication: {})
    }
    func sql(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw EmbeddingIndexError.unavailable }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw EmbeddingIndexError.unavailable }
    }
    func available(kind: AIEntityKind? = nil,
                   isCurrent: @Sendable (EmbeddingDocumentCompletion) throws -> Bool = { _ in true },
                   validateQuery: @Sendable () throws -> Void = {}) async throws -> Bool {
        try await index.hasCompletedSearchDocuments(generation: generation, kind: kind, isCurrent: isCurrent, validateQuery: validateQuery)
    }
}

@Test func embeddingSearchSafetyProbeEmptyZeroPartialAndScope() async throws {
    let f = try await SearchSafetyFixture.make()
    #expect(try await !f.available())
    try await f.publish(count: 0)
    #expect(try await !f.available())
    try await f.publish(partial: true)
    #expect(try await !f.available())
    try await f.publish()
    #expect(try await f.available(kind: .page))
    #expect(try await !f.available(kind: .source))
    #expect(try await !f.available(isCurrent: { _ in false }))
    try await f.store.close()
}

@Test(arguments: ["chunk_count=2", "metadata=X'00'", "metadata=zeroblob(1048576)"])
func embeddingSearchSafetyProbeRejectsCorruptCompletions(mutation: String) async throws {
    let f = try await SearchSafetyFixture.make()
    try await f.publish()
    try f.sql("UPDATE embedding_documents SET \(mutation)")
    #expect(try await !f.available())
    try await f.store.close()
}

@Test func embeddingSearchSafetyProbeCountsPresenceAndDoesNotDecodeVectors() async throws {
    let f = try await SearchSafetyFixture.make()
    try await f.publish()
    try f.sql("UPDATE embedding_chunks SET vector=X'00'")
    #expect(try await f.available()) // preflight does not decode any vector
    let query = try EmbeddingVector(values: [1, 0], model: f.generation.model)
    #expect(try await f.index.searchCandidates(query: query, generation: f.generation,
        isCurrent: { _ in true }, validateQuery: {}).isEmpty)
    try f.sql("DELETE FROM embedding_chunks")
    #expect(try await !f.available())
    try await f.publish()
    try f.sql("INSERT INTO embedding_checkpoints SELECT * FROM embedding_documents")
    #expect(try await !f.available())
    #expect(try await f.index.searchCandidates(query: query, generation: f.generation,
        isCurrent: { _ in true }, validateQuery: {}).isEmpty)
    try await f.store.close()
}

@Test func embeddingSearchSafetyProbeValidatesGenerationAndRetirement() async throws {
    let f = try await SearchSafetyFixture.make()
    try await f.publish()
    let wrong = try EmbeddingIndexGeneration(id: f.generation.id, vaultID: f.session.vaultID,
        model: f.generation.model, chunkingVersion: "2")
    await #expect(throws: EmbeddingContractError.incompatibleGeneration) {
        try await f.index.hasCompletedSearchDocuments(generation: wrong, isCurrent: { _ in true }, validateQuery: {})
    }
    let crossVault = try EmbeddingIndexGeneration(vaultID: UUID(), model: f.generation.model, chunkingVersion: "1")
    await #expect(throws: (any Error).self) {
        try await f.index.hasCompletedSearchDocuments(generation: crossVault, isCurrent: { _ in true }, validateQuery: {})
    }
    let missing = try EmbeddingIndexGeneration(vaultID: f.session.vaultID, model: f.generation.model, chunkingVersion: "1")
    #expect(try await !f.index.hasCompletedSearchDocuments(generation: missing, isCurrent: { _ in true }, validateQuery: {}))
    await #expect(throws: CancellationError.self) { try await f.available(validateQuery: { throw CancellationError() }) }
    await #expect(throws: (any Error).self) {
        try await f.available(isCurrent: { _ in f.gate.updateState(.closed); return true })
    }
    try await f.store.close()
}

@Test func embeddingSearchSafetyMultiplePermitsPublishOnceWithoutDeadlock() async throws {
    let f = try await SearchSafetyFixture.make()
    let permits = try await f.permits(), authority = try f.authority()
    let assignments = Mutex(0)
    let value = try EmbeddingPublicationPermit.withPublication(permits: permits, authority: authority) {
        assignments.withLock { $0 += 1 }
        return 42
    }
    #expect(value == 42)
    #expect(assignments.withLock { $0 } == 1)
    try await f.store.close()
}

private enum SearchSafetyInterruption: String, CaseIterable, Sendable { case edit, trash, query, lease, vaultSwitch, close }

@Test(arguments: SearchSafetyInterruption.allCases)
private func embeddingSearchSafetyMultiPermitRejectsHydrationAssignmentChanges(interruption: SearchSafetyInterruption) async throws {
    let f = try await SearchSafetyFixture.make()
    let permits = try await f.permits(), authority = try f.authority()
    let page = f.pages[1]
    switch interruption {
    case .edit:
        _ = try await f.store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("edited")])]), pageID: page.pageID,
            condition: .replace(expected: page.revision))
    case .trash: _ = try await f.store.setTrashed(pageID: page.pageID, expected: page.revision, trashed: true)
    case .query: authority.invalidate()
    case .lease: f.gate.updateState(.closed)
    case .vaultSwitch: f.gate.updateState(.open(VaultSession(vaultID: UUID(), root: f.root.appendingPathComponent("other"), generation: 2)))
    case .close: try await f.store.close()
    }
    var assigned = false
    #expect(throws: EmbeddingContractError.authorityDenied) {
        try EmbeddingPublicationPermit.withPublication(permits: permits, authority: authority) { assigned = true }
    }
    #expect(!assigned)
    if interruption != .close { try await f.store.close() }
}

@Test func embeddingSearchSafetyMultiPermitRejectsEmptyCrossDomainAndVault() async throws {
    let f = try await SearchSafetyFixture.make()
    let sameVaultOtherDomain = try await SearchSafetyFixture.make(vaultID: f.session.vaultID)
    let otherVault = try await SearchSafetyFixture.make()
    let own = try await f.permits(), foreignDomain = try await sameVaultOtherDomain.permits(), foreignVault = try await otherVault.permits()
    let authority = try f.authority()
    for permits in [[], [own[0], foreignDomain[0]], [own[0], foreignVault[0]], foreignVault, foreignDomain] {
        #expect(throws: EmbeddingContractError.authorityDenied) {
            try EmbeddingPublicationPermit.withPublication(permits: permits, authority: authority) {}
        }
    }
    #expect(throws: EmbeddingContractError.authorityDenied) {
        try EmbeddingPublicationPermit.withPublication(permits: own, authority: otherVault.authority()) {}
    }
    // A forged different-vault permit sharing the domain must still fail the vault check.
    let forged = EmbeddingPublicationPermit(domain: EmbeddingPublicationDomain.shared(for: f.session.root.appendingPathComponent("blocks.sqlite")),
        entityID: f.pages[0].pageID, revision: f.pages[0].revision, kind: .page, vaultID: UUID())
    #expect(throws: EmbeddingContractError.authorityDenied) {
        try EmbeddingPublicationPermit.withPublication(permits: [own[0], forged], authority: authority) {}
    }
    try await f.store.close(); try await sameVaultOtherDomain.store.close(); try await otherVault.store.close()
}

@Test func embeddingSearchSafetyMultiPermitActualTaskCancellation() async throws {
    let f = try await SearchSafetyFixture.make()
    let permits = try await f.permits(), authority = try f.authority()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try EmbeddingPublicationPermit.withPublication(permits: permits, authority: authority) { 42 }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    try await f.store.close()
}

@Test func embeddingSearchSafetySourceOriginalFingerprintPersistsAndLegacyDecodes() async throws {
    let f = try await SearchSafetyFixture.make()
    let bytes = Data("original source bytes with metadata".utf8), operationID = UUID()
    let metadata = SourceMetadata(id: UUID(), title: "Source", capturedAt: "2026-10-16", originalFilename: "original.txt",
        originURL: nil, sha256: digest(bytes), fileSize: bytes.count, storedFilename: "original.txt")
    let adapter = try PlaintextVaultContentStore(root: f.session.root)
    let receipt = try adapter.publishCanonicalOriginal(bytes, metadata: metadata, vaultID: f.session.vaultID, operationID: operationID)
    let outcome = try await f.store.publishSourceAndPage(source: CanonicalSource(metadata: metadata), condition: .createOnly,
        operationID: operationID, expectedVaultRevision: f.store.canonicalVaultRevision(), byteReceipt: receipt)
    let revision = outcome.sourceRevision.token.base64EncodedString()
    let identity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .source, entityID: metadata.id, revision: revision)
    let chunk = try EmbeddingChunk(identity: identity, chunkID: "paragraph/0/0", ordinal: 0,
        contentFingerprint: "chunk-fingerprint", chunkingVersion: "1")
    let record = try EmbeddingRecord(generation: f.generation, chunk: chunk,
        vector: EmbeddingVector(values: [1, 0], model: f.generation.model))
    let completion = EmbeddingDocumentCompletion(identity: identity, workRevision: revision,
        inputFingerprint: digest(Data((chunk.chunkID + ":" + chunk.contentFingerprint).utf8)), chunkCount: 1,
        originalFingerprint: digest(bytes))
    let permit = try await f.store.embeddingPublicationPermit(sourceID: metadata.id, expected: outcome.sourceRevision)
    try await f.index.replaceDocument(identity: identity, generation: f.generation, records: [record], permit: permit,
        authority: f.authority(), completion: completion, validatePublication: {})
    let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: f.root.appendingPathComponent("support"), lease: f.session.lease, accessGate: f.gate)
    #expect(try await reopened.completedDocuments(generation: f.generation) == [completion])
    let query = try EmbeddingVector(values: [1, 0], model: f.generation.model)
    #expect(try await reopened.searchCandidates(query: query, generation: f.generation,
        isCurrent: { $0.originalFingerprint == digest(bytes) }, validateQuery: {}).first?.completion.originalFingerprint == digest(bytes))
    // Legacy Source JSON has no optional original-byte evidence and must still decode.
    let legacy: [String: Any] = ["entityKind": "source", "entityID": metadata.id.uuidString, "revision": revision,
        "workRevision": revision, "inputFingerprint": completion.inputFingerprint, "chunkCount": 1]
    let hex = try JSONSerialization.data(withJSONObject: legacy).map { String(format: "%02x", $0) }.joined()
    try f.sql("UPDATE embedding_documents SET metadata=X'\(hex)'")
    #expect(try await reopened.completedDocuments(generation: f.generation).first?.originalFingerprint == nil)
    #expect(try await !reopened.hasCompletedSearchDocuments(generation: f.generation,
        isCurrent: { $0.originalFingerprint != nil }, validateQuery: {}))
    try await f.publish() // Existing Page completion JSON remains compatible and has nil evidence.
    #expect(try await reopened.completedDocuments(generation: f.generation).first(where: { $0.identity.entityKind == .page })?.originalFingerprint == nil)
    try await f.store.close()
}

@Test func embeddingSearchSafetyPreparedFingerprintTracksBytesBeyondExtractedText() async throws {
    let f = try await SearchSafetyFixture.make()
    let original = Data("PDF bytes version 1".utf8), changed = Data("PDF bytes version 2".utf8)
    let metadata = SourceMetadata(id: UUID(), title: "Source", capturedAt: "2026-10-16", originalFilename: "original.pdf",
        originURL: nil, sha256: digest(original), fileSize: original.count, storedFilename: "original.pdf")
    let identity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .source, entityID: metadata.id, revision: "same-canonical")
    let inputs = try EmbeddingInputPreparation.source(extractedOriginalText: "Identical extracted text.", identity: identity, model: f.generation.model)
    func snapshot(_ bytes: Data) -> EmbeddingPreparedInputSnapshot {
        EmbeddingPreparedInputSnapshot(identity: identity, canonicalRevision: .init(token: Data("same-canonical".utf8)),
            model: f.generation.model, inputs: inputs,
            sourceEvidence: SourceSummarySnapshot(source: SourceRecord(metadata: metadata, body: ""), original: bytes, originalToken: nil))
    }
    let first = snapshot(original), second = snapshot(changed)
    #expect(first.revision == second.revision)
    #expect(first.inputFingerprint == second.inputFingerprint)
    #expect(first.sourceRecord?.metadata == metadata)
    #expect(first.originalFingerprint == digest(original))
    #expect(second.originalFingerprint == digest(changed))
    #expect(first.originalFingerprint != second.originalFingerprint)
    let page = EmbeddingPreparedInputSnapshot(identity: identity, canonicalRevision: first.canonicalRevision,
        model: f.generation.model, inputs: inputs, sourceEvidence: nil)
    #expect(page.originalFingerprint == nil)
    #expect(page.sourceRecord == nil)
    try await f.store.close()
}

@Test func embeddingSearchSafetyProbeActualTaskCancellation() async throws {
    let f = try await SearchSafetyFixture.make()
    try await f.publish()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await f.available()
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await f.available())
    try await f.store.close()
}

@Test func embeddingSearchSafetyProcessorPublishesOriginalByteFingerprint() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/sem-emb-07-safety/processor/\(UUID())")
    let canonical = root.appendingPathComponent("canonical")
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    try await FileVaultRepository.initializeSchema5(root: canonical, storageProvider: .plaintext)
    let manager = VaultSessionManager()
    let (_, lease, repository) = try await manager.openRepository(root: canonical)
    let bytes = Data("The original source body is complete and independent of extracted metadata.".utf8)
    let source = try await repository.importSource(data: bytes, filename: "original.txt", title: "Current source", originURL: nil)
    let model = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "fingerprint", revision: "1", dimensions: 2,
        maximumInputUTF8Bytes: 1024, maximumBatchSize: 10)
    let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
    let gate = manager.accessGate
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"), lease: lease, accessGate: gate)
    let authority = try EmbeddingPublicationAuthority(accessGate: gate, lease: lease, generation: generation)
    let processor = try EmbeddingWorkProcessor(repository: repository, index: index, generation: generation, lease: lease,
        publicationAuthority: authority, dispatch: { inputs, _, execution in
            try execution.validate()
            return EmbeddingDispatchResult(vectors: try inputs.map { _ in try EmbeddingVector(values: [1, 0], model: model) },
                validatePublication: { try execution.validate() })
        }, extractOriginal: { _ in "Identical extraction may conceal independent original-byte changes." }, validateAuthority: {
            try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "search.safety.processor")
        })
    let inventory = try await repository.aiProcessingInventory()
    let revision = try #require(inventory.first { $0.entityID == source.id }?.revision)
    let item = AIWorkItem(key: .init(vaultID: lease.vaultID, entityKind: .source, entityID: source.id,
        processorID: processor.descriptor.identifier), revision: revision, processorVersion: processor.descriptor.version, eligibleAt: Date())
    let snapshot = try await processor.prepare(item, lease: lease)
    _ = try await processor.execute(snapshot, context: .init(lease: lease, validate: {
        try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "search.safety.execute")
    }))
    let completion = try #require(try await index.completedDocuments(generation: generation).first)
    #expect(completion.originalFingerprint == digest(bytes))
    #expect(completion.workRevision == revision)
    #expect(completion.chunkCount > 0)
    try await repository.sqliteBlockStore.close()
}
