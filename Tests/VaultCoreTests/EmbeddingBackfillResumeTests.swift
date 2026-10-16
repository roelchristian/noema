import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class ResumeInferenceCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}
private final class ResumeSentenceBackend: AppleSentenceEmbeddingBackend {
    let languageCode = "en", revision = 7, dimension = 3
    let calls: ResumeInferenceCounter
    init(_ calls: ResumeInferenceCounter) { self.calls = calls }
    func dominantLanguage(for text: String) -> String? { "en" }
    func wordCount(for text: String) -> Int { 8 }
    func vector(for text: String) -> [Double]? { calls.increment(); return [1, 0, -1] }
}
private struct ResumePolicy: AIProcessingPolicyResolver {
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority { .allowed }
    func validateExecution(lease: VaultSessionLease) throws {}
}

/// Independent evidence for the derived-COMMIT / durable-work-completion crash window.
@Suite(.timeLimit(.minutes(1))) struct EmbeddingBackfillResumeTests {
    @Test func interruptedLedgerAfterDerivedCommitResumesWithoutRepeatingNativeInference() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-05-app/resume-fixtures/\(UUID())")
        let canonical = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: canonical, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, lease, repository) = try await manager.openRepository(root: canonical)
        let calls = ResumeInferenceCounter()
        let provider = try AppleSentenceEmbeddingProvider(backend: ResumeSentenceBackend(calls))
        let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: provider.descriptor,
                                                       chunkingVersion: EmbeddingChunker.version)
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"),
                                            lease: lease, accessGate: manager.accessGate)
        let batch = try EmbeddingBackfillBatch(generation: generation, scopes: [.page], createdAt: Date())
        let authority = try EmbeddingPublicationAuthority(accessGate: manager.accessGate, lease: lease, generation: generation)
        let processor = try EmbeddingWorkProcessor(repository: repository, index: index, generation: generation,
            lease: lease, publicationAuthority: authority, dispatch: { inputs, scope, execution in
                guard case .historicalBackfill(let batchID, _) = scope, batchID == batch.id else { throw AIWorkFailure.authority }
                let context = try EmbeddingExecutionContext(lease: lease, scope: scope, model: provider.descriptor,
                                                             validateCurrentAuthority: { try execution.validate() })
                let vectors = try await provider.embed(inputs.map(\.text), scope: scope, context: context)
                return EmbeddingDispatchResult(vectors: vectors, validatePublication: { try execution.validate() })
            }, extractOriginal: { _ in throw AIWorkFailure.unsupported }, validateAuthority: {
                try manager.accessGate.validate(lease: lease, targetRoot: lease.root,
                                               targetVaultID: lease.vaultID, operation: "backfill.resume")
            }, batchID: batch.id)
        let page = try await repository.create(title: "Existing", body: "An original committed paragraph about the history of this beautiful city.")
        let inventory = try await repository.aiProcessingInventory()
        let url = root.appendingPathComponent("work.sqlite")
        let ledger = try SQLiteAIWorkLedger(url: url)
        try await ledger.createEmbeddingBatch(batch, inventory: inventory)
        let member = try #require(try await ledger.pendingEmbeddingAdmissions(batchID: batch.id).first)
        let candidate = AIWorkItem(id: member.workID,
            key: .init(vaultID: lease.vaultID, entityKind: .page, entityID: page.id, processorID: processor.descriptor.identifier),
            revision: member.revision, processorVersion: processor.descriptor.version, state: .running,
            attemptCount: 1, eligibleAt: batch.createdAt, batchID: batch.id)
        let snapshot = try await processor.prepare(candidate, lease: lease)
        _ = try await processor.execute(snapshot, context: .init(lease: lease, validate: {}))
        #expect(calls.count == 1)
        // The semantic COMMIT succeeded, but its scheduler completion/acknowledgment did not.
        try await ledger.save(candidate)
        let reopened = try SQLiteAIWorkLedger(url: url)
        let clock = AIProcessingClock(now: { Date() }, sleep: { _ in try Task.checkCancellation() })
        let resumed = AIProcessingCoordinator(ledger: reopened, gate: manager.accessGate, policy: ResumePolicy(), clock: clock)
        try await resumed.bind(lease: lease, inventory: inventory)
        #expect(await resumed.workItems().isEmpty)
        #expect(calls.count == 1)
        // Late registration is the app's restart path; repeated admission uses the fixed ID.
        await resumed.register(processor)
        try await resumed.admitHistorical(candidate)
        try await resumed.admitHistorical(candidate)
        var completed: AIWorkItem?
        for _ in 0..<4000 {
            if let item = try await reopened.existingWorkItem(key: candidate.key), item.state == .completed {
                completed = item; break
            }
            await Task.yield()
        }
        let result = try #require(completed)
        #expect(result.id == candidate.id)
        #expect(result.attemptCount == 2)
        #expect(result.completionDisposition == .skipped)
        #expect(calls.count == 1)
        #expect(try await index.completedDocuments(generation: generation).count == 1)
        try await resumed.admitHistorical(candidate)
        #expect(try await reopened.existingWorkItem(key: candidate.key)?.attemptCount == 2)
        #expect(calls.count == 1)
        try await resumed.suspend()
    }
}
