import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class ContextValidityFlag: Sendable {
    private let storage = Mutex(true)
    func revoke() { storage.withLock { $0 = false } }
    func validate() throws { if !storage.withLock({ $0 }) { throw EmbeddingContractError.authorityDenied } }
}

private struct ContextRetrievalFixture: Sendable {
    let root: URL
    let repository: FileVaultRepository
    let manager: VaultSessionManager
    let lease: VaultSessionLease
    let generation: EmbeddingIndexGeneration
    let index: SQLiteEmbeddingIndex
    let authority: EmbeddingPublicationAuthority
    let queryID = UUID()
    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/context-focused/fixtures/\(UUID())")
        let canonical = root.appendingPathComponent("canonical")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: canonical, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, lease, repository) = try await manager.openRepository(root: canonical)
        let model = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "context", revision: "1",
            dimensions: 3, maximumInputUTF8Bytes: 2048, maximumBatchSize: 10)
        let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"), lease: lease, accessGate: manager.accessGate)
        try await index.declareGeneration(generation: generation)
        return Self(root: root, repository: repository, manager: manager, lease: lease, generation: generation, index: index,
            authority: try EmbeddingPublicationAuthority(accessGate: manager.accessGate, lease: lease, generation: generation))
    }
    static func extract(_ snapshot: SourceSummarySnapshot) throws -> String {
        guard let text = String(data: snapshot.original, encoding: .utf8) else { throw EmbeddingInputPreparationError.unavailableOriginal }
        return text
    }
    func service(extract: @escaping @Sendable (SourceSummarySnapshot) throws -> String = Self.extract) throws -> SemanticContextRetrieval {
        try .init(repository: repository, index: index, generation: generation, lease: lease, extractOriginal: extract)
    }
    func context(query: UUID? = nil, valid: @escaping @Sendable () throws -> Void = {}) throws -> EmbeddingExecutionContext {
        let gate = manager.accessGate, lease = lease
        return try .init(lease: lease, scope: .query(vaultID: lease.vaultID, queryID: query ?? queryID), model: generation.model) {
            try valid()
            try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "context.test")
        }
    }
    var vector: EmbeddingVector { get throws { try .init(values: [1,0,0], model: generation.model) } }
    func seed(_ snapshot: EmbeddingPreparedInputSnapshot, partial: Bool = false, legacy: Bool = false,
              values: [Float] = [1,0,0]) async throws {
        let records = try snapshot.inputs.map { try EmbeddingRecord(generation: generation, chunk: $0.chunk,
            vector: .init(values: values, model: generation.model)) }
        let permit: EmbeddingPublicationPermit
        if snapshot.identity.entityKind == .page { permit = try await repository.sqliteBlockStore.embeddingPublicationPermit(pageID: snapshot.identity.entityID, expected: snapshot.canonicalRevision) }
        else { permit = try await repository.sqliteBlockStore.embeddingPublicationPermit(sourceID: snapshot.identity.entityID, expected: snapshot.canonicalRevision) }
        try await index.replaceDocument(identity: snapshot.identity, generation: generation, records: records, permit: permit, authority: authority,
            completion: partial ? nil : .init(identity: snapshot.identity, workRevision: snapshot.revision,
                inputFingerprint: snapshot.inputFingerprint, chunkCount: records.count, originalFingerprint: legacy ? nil : snapshot.originalFingerprint),
            checkpoint: partial ? .init(identity: snapshot.identity, workRevision: snapshot.revision,
                inputFingerprint: snapshot.inputFingerprint, chunkCount: records.count) : nil, validatePublication: {})
    }
    func page(title: String = "Context", body: String = "Current original passage") async throws -> (NoteRecord, EmbeddingPreparedInputSnapshot) {
        let note = try await repository.create(title: title, body: body)
        return (note, try await repository.embeddingPageSnapshot(id: note.id, expectedRevision: note.contentHash, model: generation.model))
    }
    func source(_ source: SourceRecord) async throws -> EmbeddingPreparedInputSnapshot {
        let revision = try await repository.sqliteBlockStore.sourceSnapshot(id: source.id).revision.token.base64EncodedString()
        return try await repository.embeddingSourceSnapshot(id: source.id, expectedRevision: revision, model: generation.model, extractOriginal: Self.extract)
    }
}

@Test func semanticContextReadOnlyEvidenceIsBoundedAndPageEditsInvalidate() async throws {
    let f = try await ContextRetrievalFixture.make(), service = try f.service(), context = try f.context()
    let (note, snapshot) = try await f.page(body: String(repeating: "Original sentence. ", count: 80))
    try await f.seed(snapshot)
    let before = try await f.repository.sqliteBlockStore.load(pageID: note.id)
    let results = try await service.retrieve(vector: f.vector, scope: .all, context: context)
    let evidence = try #require(results.first)
    #expect(evidence.title == note.title)
    #expect(evidence.excerpt.count == 600)
    #expect(evidence.candidate.completion.identity == snapshot.identity)
    let after = try await f.repository.sqliteBlockStore.load(pageID: note.id)
    #expect(before.document == after.document && before.revision == after.revision)
    #expect(try await service.validate(evidence: evidence, context: context) != nil)
    _ = try await f.repository.save(note: note, title: note.title, body: "Changed original", tags: [])
    #expect(try await service.validate(evidence: evidence, context: context) == nil)
    #expect(try await service.retrieve(vector: f.vector, scope: .all, context: context).isEmpty)
    #expect(throws: EmbeddingContractError.authorityDenied) { try evidence.permit.withPublication(authority: f.authority) {} }
}

@Test func semanticContextExcludesPartialAndLegacySourcesAndRechecksCompletion() async throws {
    let f = try await ContextRetrievalFixture.make(), service = try f.service(), context = try f.context()
    let (_, page) = try await f.page()
    try await f.seed(page, partial: true)
    #expect(try await service.retrieve(vector: f.vector, scope: .all, context: context).isEmpty)
    let source = try await f.repository.importSource(data: Data("Source original".utf8), filename: "source.txt", title: "Source", originURL: nil)
    let original = try await f.source(source)
    try await f.seed(original, legacy: true)
    #expect(try await service.retrieve(vector: f.vector, scope: .sources, context: context).isEmpty)
    try await f.seed(original)
    let evidence = try #require(try await service.retrieve(vector: f.vector, scope: .sources, context: context).first)
    #expect(evidence.candidate.completion.originalFingerprint == original.originalFingerprint)
    try await f.seed(original, partial: true)
    #expect(try await service.validate(evidence: evidence, context: context) == nil)
}

@Test func semanticContextSourceOriginalMutationInvalidatesEvidence() async throws {
    let f = try await ContextRetrievalFixture.make(), service = try f.service(), context = try f.context()
    let linked = f.root.appendingPathComponent("linked.txt")
    try Data("Current linked original".utf8).write(to: linked)
    let source = try #require(try await f.repository.linkSources(at: linked, maximumFiles: 1).first)
    let original = try await f.source(source)
    try await f.seed(original)
    let evidence = try #require(try await service.retrieve(vector: f.vector, scope: .sources, context: context).first)
    try Data("Modified linked original".utf8).write(to: linked)
    #expect(try await service.validate(evidence: evidence, context: context) == nil)
    #expect(try await service.retrieve(vector: f.vector, scope: .sources, context: context).isEmpty)
}

@Test func semanticContextBlocksFilterBeforeTopKAndVerifyActualTags() async throws {
    let f = try await ContextRetrievalFixture.make(), service = try f.service(), context = try f.context()
    var catalog: [UUID: Set<UUID>] = [:]
    for offset in 0..<4 {
        let (_, snapshot) = try await f.page(title: "Untagged \(offset)")
        try await f.seed(snapshot)
    }
    let (note, _) = try await f.page(title: "Tagged")
    var metadata = BlockMetadata(); metadata.semantic = "idea"
    let block = EditorBlock(runs: [.init("Tagged current passage")], metadata: metadata)
    let saved = try await f.repository.save(note: note, title: note.title, document: .init(blocks: [block]), tags: [])
    let snapshot = try await f.repository.embeddingPageSnapshot(id: note.id, expectedRevision: saved.contentHash, model: f.generation.model)
    try await f.seed(snapshot, values: [0.1,1,0])
    catalog[note.id] = [block.id]
    #expect(try await service.retrieve(vector: f.vector, scope: .blocks, context: context, limit: 1).isEmpty)
    let evidence = try #require(try await service.retrieve(vector: f.vector, scope: .blocks, context: context, limit: 1, taggedBlocks: catalog).first)
    #expect(evidence.candidate.identity.entityID == note.id)
    #expect(evidence.currentSemanticBlockIDs == [block.id])
    let (_, untagged) = try await f.page(title: "Fake tagged")
    try await f.seed(untagged)
    let guessedID = try #require(SemanticPassageLocator(chunkID: untagged.inputs[0].chunk.chunkID, entityKind: .page))
    if case .block(let id, _) = guessedID {
        #expect(try await service.retrieve(vector: f.vector, scope: .blocks, context: context, taggedBlocks: [untagged.identity.entityID: [id]]).isEmpty)
    }
}

@Test func semanticContextRejectsDocumentAuthorityQueryReplayAndRevokedExecution() async throws {
    let f = try await ContextRetrievalFixture.make(), service = try f.service(), context = try f.context()
    let (_, page) = try await f.page(); try await f.seed(page)
    let documentContext = try EmbeddingExecutionContext(lease: f.lease, scope: .document(page.identity), model: f.generation.model) {}
    await #expect(throws: EmbeddingContractError.authorityDenied) { try await service.retrieve(vector: f.vector, scope: .all, context: documentContext) }
    let evidence = try #require(try await service.retrieve(vector: f.vector, scope: .all, context: context).first)
    await #expect(throws: EmbeddingContractError.authorityDenied) { try await service.validate(evidence: evidence, context: f.context(query: UUID())) }
    let valid = ContextValidityFlag()
    let revoked = try f.context { try valid.validate() }
    let source = try await f.repository.importSource(data: Data("Original to revoke".utf8), filename: "revoke.txt", title: "Source", originURL: nil)
    try await f.seed(f.source(source))
    let revokingService = try f.service { snapshot in
        valid.revoke()
        return try ContextRetrievalFixture.extract(snapshot)
    }
    await #expect(throws: EmbeddingContractError.authorityDenied) { try await revokingService.retrieve(vector: f.vector, scope: .sources, context: revoked) }
}

@Test func semanticContextRequiresExactLeaseModelAndIndependentRepositoryGate() async throws {
    let f = try await ContextRetrievalFixture.make(), service = try f.service()
    let (_, page) = try await f.page(); try await f.seed(page)
    let otherLease = VaultSessionLease(vaultID: f.lease.vaultID, root: f.lease.root, generation: f.lease.generation)
    let wrongLease = try EmbeddingExecutionContext(lease: otherLease, scope: .query(vaultID: f.lease.vaultID, queryID: UUID()), model: f.generation.model) {}
    await #expect(throws: EmbeddingContractError.authorityDenied) { try await service.retrieve(vector: f.vector, scope: .all, context: wrongLease) }
    let otherModel = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "context", revision: "2",
        dimensions: 3, maximumInputUTF8Bytes: 2048, maximumBatchSize: 10)
    let wrongVector = try EmbeddingVector(values: [1,0,0], model: otherModel)
    await #expect(throws: EmbeddingContractError.incompatibleGeneration) { try await service.retrieve(vector: wrongVector, scope: .all, context: f.context()) }
    let permissiveContext = try EmbeddingExecutionContext(lease: f.lease, scope: .query(vaultID: f.lease.vaultID, queryID: UUID()), model: f.generation.model) {}
    f.manager.accessGate.updateState(.closed)
    await #expect(throws: (any Error).self) { try await service.retrieve(vector: f.vector, scope: .all, context: permissiveContext) }
}
