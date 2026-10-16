import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class GateSourceCalls: Sendable { let value = Mutex(0) }
private final class GateSourceBackend: AppleSentenceEmbeddingBackend {
    let languageCode = "en", revision = 1, dimension = 3
    let calls: GateSourceCalls
    init(_ calls: GateSourceCalls) { self.calls = calls }
    func dominantLanguage(for text: String) -> String? { "en" }
    func wordCount(for text: String) -> Int { text.split(separator: " ").count }
    func vector(for text: String) -> [Double]? { calls.value.withLock { $0 += 1 }; return [1, 0.5, -1] }
}
private struct GateSourcePolicy: AIProcessingPolicyResolver {
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority { .allowed }
    func validateExecution(lease: VaultSessionLease) throws {}
}

/// Independent regression for an original-bound Source job recovered against metadata-only inventory.
struct EmbeddingBackfillGateTests {
    @Test(arguments: [false, true]) func compositeSourceRevisionSurvivesHistoricalMetadataOnlyRestart(_ originalChanged: Bool) async throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-05-gate/source-fixtures/\(UUID())")
        let root = base.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: root, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, lease, repository) = try await manager.openRepository(root: root)
        let original = Data("This original historical source describes the architecture of a coastal city.".utf8)
        let source = try await repository.importSource(data: original, filename: "history.txt", title: "History", originURL: nil)
        let inventory = try await repository.aiProcessingInventory()
        let canonical = try #require(inventory.first { $0.entityID == source.id })
        let composite = canonical.revision + ":" + digest(originalChanged ? Data("previous bytes that were replaced".utf8) : original)
        let calls = GateSourceCalls()
        let countedProvider = try AppleSentenceEmbeddingProvider(backend: GateSourceBackend(calls))
        let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: countedProvider.descriptor, chunkingVersion: EmbeddingChunker.version)
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: base.appendingPathComponent("support"), lease: lease, accessGate: manager.accessGate)
        let batch = try EmbeddingBackfillBatch(generation: generation, scopes: [.source], createdAt: Date())
        let authority = try EmbeddingPublicationAuthority(accessGate: manager.accessGate, lease: lease, generation: generation)
        let processor = try EmbeddingWorkProcessor(repository: repository, index: index, generation: generation, lease: lease,
            publicationAuthority: authority, dispatch: { inputs, scope, execution in
                let context = try EmbeddingExecutionContext(lease: lease, scope: scope, model: generation.model,
                    validateCurrentAuthority: { try execution.validate() })
                return EmbeddingDispatchResult(vectors: try await countedProvider.embed(inputs.map(\.text), scope: scope, context: context),
                    validatePublication: { try context.validate(scope: scope, model: generation.model) })
            }, extractOriginal: { snapshot in String(decoding: snapshot.original, as: UTF8.self) }, validateAuthority: {}, batchID: batch.id)
        let url = base.appendingPathComponent("work.sqlite"), ledger = try SQLiteAIWorkLedger(url: base.appendingPathComponent("work.sqlite"))
        try await ledger.createEmbeddingBatch(batch, inventory: inventory)
        let member = try #require(try await ledger.pendingEmbeddingAdmissions(batchID: batch.id).first)
        let interrupted = AIWorkItem(id: member.workID, key: .init(vaultID: lease.vaultID, entityKind: .source,
            entityID: source.id, processorID: processor.descriptor.identifier), revision: composite,
            processorVersion: processor.descriptor.version, state: .running, attemptCount: 1, eligibleAt: Date(), batchID: batch.id)
        try await ledger.save(interrupted)
        try await ledger.markEmbeddingMemberAdmitted(batchID: batch.id, workID: member.workID)
        let reopened = try SQLiteAIWorkLedger(url: url)
        let coordinator = AIProcessingCoordinator(ledger: reopened, gate: manager.accessGate, policy: GateSourcePolicy(),
            clock: AIProcessingClock(now: { Date() }, sleep: { _ in try Task.checkCancellation(); await Task.yield() }))
        try await coordinator.bind(lease: lease, inventory: inventory)
        await coordinator.register(processor)
        try await coordinator.admitHistorical(interrupted)
        var final: AIWorkItem?
        for _ in 0..<4000 {
            if let work = try await reopened.existingWorkItem(key: interrupted.key), work.state == (originalChanged ? .failed : .completed) { final = work; break }
            await Task.yield()
        }
        let completed = try #require(final)
        #expect(completed.revision == composite)
        #expect(completed.id == interrupted.id)
        #expect(completed.attemptCount == 2)
        #expect(calls.value.withLock { $0 } == (originalChanged ? 0 : 1))
        if originalChanged { #expect(try await index.completedDocuments(generation: generation).isEmpty) }
        else { #expect(try await index.completedDocuments(generation: generation).first?.workRevision == composite) }
        try await coordinator.admitHistorical(interrupted)
        #expect(calls.value.withLock { $0 } == (originalChanged ? 0 : 1))
        try await coordinator.suspend()
    }
}
