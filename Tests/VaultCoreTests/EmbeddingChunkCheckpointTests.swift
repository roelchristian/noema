import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class CheckpointRequests: Sendable {
    private let chunks = Mutex<[String]>([])
    func append(_ inputs: [EmbeddingChunkInput]) { chunks.withLock { $0 += inputs.map(\.chunk.chunkID) } }
    var values: [String] { chunks.withLock { $0 } }
}

private struct ChunkCheckpointFixture: Sendable {
    let repository: FileVaultRepository
    let manager: VaultSessionManager
    let lease: VaultSessionLease
    let support: URL
    let index: SQLiteEmbeddingIndex
    let generation: EmbeddingIndexGeneration

    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/pr68-completion/chunk-fixtures/\(UUID())")
        let canonical = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: canonical, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, lease, repository) = try await manager.openRepository(root: canonical)
        let model = try EmbeddingModelDescriptor(providerID: "mock", modelID: "checkpoint", revision: "1",
            dimensions: 2, maximumInputUTF8Bytes: 512, maximumBatchSize: 1)
        let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: model,
            chunkingVersion: EmbeddingChunker.version)
        let support = root.appendingPathComponent("support")
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: manager.accessGate)
        return Self(repository: repository, manager: manager, lease: lease, support: support,
                    index: index, generation: generation)
    }

    func processor(index: SQLiteEmbeddingIndex? = nil, generation: EmbeddingIndexGeneration? = nil,
                   dispatch: @escaping EmbeddingWorkProcessor.Dispatch) throws -> EmbeddingWorkProcessor {
        let selectedGeneration = generation ?? self.generation
        let authority = try EmbeddingPublicationAuthority(accessGate: manager.accessGate, lease: lease,
            generation: selectedGeneration)
        return try EmbeddingWorkProcessor(repository: repository, index: index ?? self.index,
            generation: selectedGeneration, lease: lease, publicationAuthority: authority, dispatch: dispatch,
            extractOriginal: { snapshot in
                guard let text = String(data: snapshot.original, encoding: .utf8) else { throw AIWorkFailure.unavailable }
                return text
            }, validateAuthority: {
                try manager.accessGate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID,
                                               operation: "checkpoint.test")
            })
    }

    func item(_ processor: EmbeddingWorkProcessor, kind: AIEntityKind) async throws -> AIWorkItem {
        let paragraphs = ["The first original paragraph describes a beautiful city.",
                          "The second original paragraph describes a distant country.",
                          "The third original paragraph describes an ancient history."]
        let id: UUID
        switch kind {
        case .page:
            let document = BlockDocument(blocks: paragraphs.map { EditorBlock(runs: [.init($0)]) })
            id = try await repository.create(title: "Checkpoint", body: BlockDocumentCodec.encode(document)).id
        case .source:
            id = try await repository.importSource(data: Data(paragraphs.joined(separator: "\n\n").utf8),
                filename: "checkpoint.txt", title: "Checkpoint", originURL: nil).id
        }
        let change = try #require(try await repository.aiProcessingInventory().first { $0.entityID == id })
        var revision = change.revision
        if kind == .source {
            let source = try await repository.sourceSummarySnapshot(id: id)
            revision += ":" + digest(source.original)
        }
        return AIWorkItem(key: .init(vaultID: lease.vaultID, entityKind: kind, entityID: id,
            processorID: processor.descriptor.identifier), revision: revision,
            processorVersion: processor.descriptor.version, eligibleAt: Date())
    }

    var context: AIProcessingExecutionContext { .init(lease: lease, validate: {}) }
}

@Suite(.timeLimit(.minutes(1))) struct EmbeddingChunkCheckpointTests {
    @Test(arguments: [AIEntityKind.page, .source], [false, true])
    func interruptedDocumentReopensAndReusesOnlyCommittedBatches(_ kind: AIEntityKind, _ failAtCommit: Bool) async throws {
        let f = try await ChunkCheckpointFixture.make()
        let requests = CheckpointRequests()
        let processor = try f.processor { inputs, _, _ in
            requests.append(inputs)
            let requestNumber = requests.values.count
            if requestNumber == 2 && !failAtCommit { throw CancellationError() }
            let validations = Mutex(0)
            return EmbeddingDispatchResult(vectors: try inputs.map { _ in
                try EmbeddingVector(values: [1, -1], model: f.generation.model)
            }, validatePublication: {
                try validations.withLock { count in
                    count += 1
                    // The second request succeeded but loses authority before its SQL COMMIT.
                    if requestNumber == 2 && count >= 2 { throw EmbeddingContractError.authorityDenied }
                }
            })
        }
        let item = try await f.item(processor, kind: kind)
        let snapshot = try await processor.prepare(item, lease: f.lease)
        await #expect(throws: (any Error).self) { try await processor.execute(snapshot, context: f.context) }
        #expect(requests.values.count == 2)
        let partial = try await f.index.records(generation: f.generation)
        #expect(partial.count == 1)
        #expect(partial.first?.chunk.chunkID == requests.values.first)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)

        // Reconstruct storage and processor: no in-memory progress or old provider capability survives.
        let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: f.support, lease: f.lease,
            accessGate: f.manager.accessGate)
        #expect(try await reopened.records(generation: f.generation) == partial)
        let checkpoint = try #require(try await reopened.documentCheckpoints(generation: f.generation).first)
        #expect(checkpoint.workRevision == item.revision)
        #expect(checkpoint.chunkCount == 1)
        // Use the actual metadata-only startup inventory. Source inventory contains the
        // canonical token rather than the observed-original composite work revision.
        let inventory = try await f.repository.aiProcessingInventory()
        if kind == .source {
            let current = try #require(inventory.first { $0.entityID == item.key.entityID })
            #expect(current.revision != item.revision)
            #expect(checkpoint.identity.revision == current.revision)
        }
        try await reopened.reconcile(current: inventory, validatePublication: {})
        #expect(try await reopened.records(generation: f.generation) == partial)
        let resumedRequests = CheckpointRequests()
        let resumed = try f.processor(index: reopened) { inputs, _, _ in
            resumedRequests.append(inputs)
            return EmbeddingDispatchResult(vectors: try inputs.map { _ in
                try EmbeddingVector(values: [1, -1], model: f.generation.model)
            }, validatePublication: {})
        }
        let resumedSnapshot = try await resumed.prepare(item, lease: f.lease)
        guard case .completed = try await resumed.execute(resumedSnapshot, context: f.context) else {
            Issue.record("Resumed partial work must complete"); return
        }
        #expect(resumedRequests.values.count == 2)
        let committedChunkID = try #require(partial.first?.chunk.chunkID)
        #expect(!resumedRequests.values.contains(committedChunkID))
        let complete = try await reopened.records(generation: f.generation)
        #expect(complete.count == 3)
        #expect(complete.map(\.chunk.ordinal) == [0, 1, 2])
        let completion = try #require(try await reopened.completedDocuments(generation: f.generation).first)
        #expect(completion.chunkCount == 3)
        #expect(completion.identity.entityID == item.key.entityID)
        #expect(completion.workRevision == item.revision)
        #expect(try await reopened.documentCheckpoints(generation: f.generation).isEmpty)
    }

    @Test func partialChunksCannotCrossGenerationIdentity() async throws {
        let f = try await ChunkCheckpointFixture.make()
        let requests = CheckpointRequests()
        let processor = try f.processor { inputs, _, _ in
            requests.append(inputs)
            if requests.values.count == 2 { throw CancellationError() }
            return EmbeddingDispatchResult(vectors: try inputs.map { _ in
                try EmbeddingVector(values: [1, -1], model: f.generation.model)
            }, validatePublication: {})
        }
        let item = try await f.item(processor, kind: .page)
        let snapshot = try await processor.prepare(item, lease: f.lease)
        await #expect(throws: (any Error).self) { try await processor.execute(snapshot, context: f.context) }
        let secondGeneration = try EmbeddingIndexGeneration(vaultID: f.lease.vaultID,
            model: f.generation.model, chunkingVersion: EmbeddingChunker.version)
        let secondRequests = CheckpointRequests()
        let second = try f.processor(generation: secondGeneration) { inputs, _, _ in
            secondRequests.append(inputs)
            return EmbeddingDispatchResult(vectors: try inputs.map { _ in
                try EmbeddingVector(values: [1, -1], model: secondGeneration.model)
            }, validatePublication: {})
        }
        let secondItem = AIWorkItem(key: item.key, revision: item.revision,
            processorVersion: second.descriptor.version, eligibleAt: Date())
        let secondSnapshot = try await second.prepare(secondItem, lease: f.lease)
        _ = try await second.execute(secondSnapshot, context: f.context)
        #expect(secondRequests.values.count == 3)
        #expect(try await f.index.records(generation: f.generation).count == 1)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
        #expect(try await f.index.completedDocuments(generation: secondGeneration).first?.chunkCount == 3)
    }

    @Test func editDuringLaterBatchPreservesPartialAndRechecksChunkFingerprint() async throws {
        let f = try await ChunkCheckpointFixture.make()
        let requests = CheckpointRequests()
        let processor = try f.processor { inputs, scope, _ in
            requests.append(inputs)
            if requests.values.count == 2 {
                guard case .document(let identity) = scope else { throw AIWorkFailure.validation }
                let loaded = try await f.repository.sqliteBlockStore.loadPage(pageID: identity.entityID)
                var document = loaded.snapshot.document
                document.blocks[0].runs = [.init("A changed original paragraph about a completely different place.")]
                _ = try await f.repository.save(note: loaded.record, title: loaded.record.title,
                    body: BlockDocumentCodec.encode(document), tags: [])
            }
            return EmbeddingDispatchResult(vectors: try inputs.map { _ in
                try EmbeddingVector(values: [1, -1], model: f.generation.model)
            }, validatePublication: {})
        }
        let item = try await f.item(processor, kind: .page)
        let snapshot = try await processor.prepare(item, lease: f.lease)
        await #expect(throws: (any Error).self) { try await processor.execute(snapshot, context: f.context) }
        let partial = try await f.index.records(generation: f.generation)
        #expect(partial.count == 1)
        #expect(partial.first?.chunk.identity.revision == item.revision)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
        let checkpoint = try #require(try await f.index.documentCheckpoints(generation: f.generation).first)
        #expect(checkpoint.workRevision == item.revision)

        // Fresh canonical preparation must not reuse the same block ID after its text changes.
        let freshRequests = CheckpointRequests()
        let fresh = try f.processor { inputs, _, _ in
            freshRequests.append(inputs)
            return EmbeddingDispatchResult(vectors: try inputs.map { _ in
                try EmbeddingVector(values: [1, -1], model: f.generation.model)
            }, validatePublication: {})
        }
        let current = try #require(try await f.repository.aiProcessingInventory().first { $0.entityID == item.key.entityID })
        let freshItem = AIWorkItem(key: item.key, revision: current.revision,
            processorVersion: fresh.descriptor.version, eligibleAt: Date())
        let freshSnapshot = try await fresh.prepare(freshItem, lease: f.lease)
        _ = try await fresh.execute(freshSnapshot, context: f.context)
        #expect(freshRequests.values.count == 3)
        let finalRecords = try await f.index.records(generation: f.generation)
        #expect(finalRecords.allSatisfy { $0.chunk.identity.revision == current.revision })
        let first = try #require(finalRecords.first)
        #expect(first.chunk.chunkID == partial.first?.chunk.chunkID)
        #expect(first.chunk.contentFingerprint != partial.first?.chunk.contentFingerprint)
        #expect(try await f.index.documentCheckpoints(generation: f.generation).isEmpty)
    }


    @Test func zeroVectorGenerationDeclarationSurvivesReopenWithoutGrantingWorkAuthority() async throws {
        let f = try await ChunkCheckpointFixture.make()
        try await f.index.declareGeneration(generation: f.generation)
        let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: f.support, lease: f.lease,
            accessGate: f.manager.accessGate)
        #expect(try await reopened.generations() == [f.generation])
        #expect(try await reopened.records(generation: f.generation).isEmpty)
        #expect(try await reopened.documentCheckpoints(generation: f.generation).isEmpty)
        #expect(try await reopened.completedDocuments(generation: f.generation).isEmpty)
        let incompatibleModel = try EmbeddingModelDescriptor(providerID: "mock", modelID: "checkpoint", revision: "2",
            dimensions: 2, maximumInputUTF8Bytes: 512, maximumBatchSize: 1)
        let incompatible = try EmbeddingIndexGeneration(id: f.generation.id, vaultID: f.lease.vaultID,
            model: incompatibleModel, chunkingVersion: EmbeddingChunker.version)
        await #expect(throws: EmbeddingContractError.incompatibleGeneration) {
            try await reopened.declareGeneration(generation: incompatible)
        }
        #expect(try await reopened.generations() == [f.generation])
    }

    @Test func revokedLeaseCannotDeclareGeneration() async throws {
        let f = try await ChunkCheckpointFixture.make()
        let original = f.manager.accessGate.currentState
        f.manager.accessGate.updateState(.closed)
        await #expect(throws: (any Error).self) {
            try await f.index.declareGeneration(generation: f.generation)
        }
        f.manager.accessGate.updateState(original)
        #expect(try await f.index.generations().isEmpty)
    }

}
