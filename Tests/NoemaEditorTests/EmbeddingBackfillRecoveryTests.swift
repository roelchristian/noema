import Foundation
import Synchronization
import Testing
@testable import VaultCore
@testable import noema

private final class RecoverySelectiveBackend: AppleSentenceEmbeddingBackend {
    let languageCode = "en", revision = 1, dimension = 3
    func dominantLanguage(for text: String) -> String? { text.contains("island") ? "fr" : "en" }
    func wordCount(for text: String) -> Int { text.split(separator: " ").count }
    func vector(for text: String) -> [Double]? { [0.25, 0.5, 0.75] }
}

/// Durable crash images are seeded without an executing worker, then reopened through
/// the real AppModel recovery path. This does not claim process-kill/fsync acceptance.
extension VaultUIIntegrationTests {
@Suite(.serialized)
struct EmbeddingBackfillRecoveryTests {
    private enum CrashImage: String, CaseIterable, Sendable {
        case persistedBatch, persistedJobWithoutAcknowledgement, admittedRunning, admittedRetryable
        var priorAttempt: Bool { self == .admittedRunning || self == .admittedRetryable }
    }

    @MainActor private func seed(_ model: AppModel, image: CrashImage) async throws -> (EmbeddingBackfillBatch, [EmbeddingBackfillMember]) {
        let ledger = try #require(model.aiProcessingLedger)
        let repository = try #require(model.repository)
        let generation = try #require(model.semanticProcessingGeneration)
        model.suspendAIProcessing()
        await model.aiProcessingRetirementTask?.value
        let batch = try EmbeddingBackfillBatch(generation: generation, scopes: [.page], createdAt: Date())
        try await ledger.createEmbeddingBatch(batch, inventory: repository.aiProcessingInventory())
        let members = try await ledger.embeddingBatchMembers(batchID: batch.id)
        if image != .persistedBatch {
            for member in members {
                let key = AIWorkKey(vaultID: member.vaultID, entityKind: member.entityKind,
                    entityID: member.entityID, processorID: EmbeddingWorkProcessor.identifier + ".history." + batch.id.uuidString)
                let item = AIWorkItem(id: member.workID, key: key, revision: member.revision,
                    processorVersion: generation.id.uuidString, state: image == .admittedRunning ? .running : (image == .admittedRetryable ? .retryable : .pending),
                    attemptCount: image.priorAttempt ? 1 : 0, eligibleAt: Date(),
                    failure: image == .admittedRetryable ? .transient : nil, batchID: batch.id)
                try await ledger.save(item)
                if image.priorAttempt { try await ledger.markEmbeddingMemberAdmitted(batchID: batch.id, workID: member.workID) }
            }
        }
        return (batch, members)
    }

    @Test(arguments: CrashImage.allCases) @MainActor private func durableCrashImagesRecoverFixedMembersWithoutRepeatingInference(_ image: CrashImage) async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, probe, _, _) = try await helper.fixture(pages: 35)
        defer { defaults.removePersistentDomain(forName: domain) }
        let (captured, members) = try await seed(model, image: image)
        #expect(probe.calls.withLock { $0 } == 0)
        #expect(await model.closeVault())
        await model.open(root, create: false)
        _ = try await helper.completed(model, batchID: captured.id)
        let ledger = try #require(model.aiProcessingLedger)
        let recovered = try await ledger.embeddingBatchMembers(batchID: captured.id)
        #expect(Set(recovered.map(\.workID)) == Set(members.map(\.workID)))
        #expect(recovered.allSatisfy { $0.state == .completed })
        #expect(probe.calls.withLock { $0 } == 35)
        let works = try await ledger.snapshotWorkItems(vaultID: captured.vaultID).filter { $0.batchID == captured.id }
        #expect(works.count == 35)
        #expect(works.allSatisfy { $0.attemptCount == (image.priorAttempt ? 2 : 1) })
        #expect(await model.closeVault())
        await model.open(root, create: false)
        #expect(probe.calls.withLock { $0 } == 35)
        #expect(await model.closeVault())
    }

    @Test @MainActor func staleAndDeletedCapturedAdmissionsDoNotBlockLaterBoundedPasses() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, probe, _, _) = try await helper.fixture(pages: 37)
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try #require(model.repository)
        let (captured, members) = try await seed(model, image: .admittedRunning)
        let pages = try await repository.scan().notes.sorted { $0.id.uuidString < $1.id.uuidString }
        let edited = try #require(pages.first), deleted = pages[1]
        _ = try await repository.save(note: edited, title: edited.title, body: "A changed committed human paragraph.", tags: edited.tags)
        try await repository.trash(note: deleted)
        #expect(await model.closeVault())
        await model.open(root, create: false)
        let ledger = try #require(model.aiProcessingLedger)
        var recovered: [EmbeddingBackfillMember] = []
        for _ in 0..<400 {
            recovered = try await ledger.embeddingBatchMembers(batchID: captured.id)
            if recovered.allSatisfy({ $0.state.isTerminal }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(recovered.map(\.workID)) == Set(members.map(\.workID)))
        #expect(recovered.filter { $0.state == .completed }.count == 35)
        #expect(recovered.first { $0.entityID == edited.id }?.state == .superseded)
        #expect(recovered.first { $0.entityID == deleted.id }?.state == .unavailable)
        #expect(try await ledger.embeddingBatch(id: captured.id)?.state == .active)
        // Reopen also recovers the committed edit against the ordinary checkpoint.
        // It is one incremental job, separate from the35 valid captured admissions.
        let activeRepository = try #require(model.repository)
        let current = try #require(try await activeRepository.scan().notes.first { $0.id == edited.id })
        let works = try await ledger.snapshotWorkItems(vaultID: captured.vaultID)
        let historical = works.filter { $0.batchID == captured.id && $0.state == .completed }
        let incremental = works.filter { $0.batchID == nil && $0.key.processorID == EmbeddingWorkProcessor.identifier }
        #expect(historical.count == 35)
        #expect(!historical.contains { $0.key.entityID == edited.id || $0.key.entityID == deleted.id })
        #expect(incremental.count == 1)
        #expect(incremental.first?.key.entityID == edited.id)
        #expect(incremental.first?.revision == current.contentHash)
        #expect(incremental.first?.state == .completed)
        #expect(probe.calls.withLock { $0 } == 36)
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        try await model.resumeEmbeddingBackfill(batchID: captured.id, for: lease)
        #expect(probe.calls.withLock { $0 } == 36)
        #expect(await model.closeVault())
    }

    @Test(arguments: [false, true]) @MainActor func replacementActivationRetainsOldGenerationAndExactSelectedScope(_ sourcesSelected: Bool) async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, _, _, _) = try await helper.fixture(pages: 2, sources: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let initialID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page, .source])
        let initial = try await helper.completed(model, batchID: initialID)
        let scopes: Set<AIEntityKind> = sourcesSelected ? [.page, .source] : [.page]
        let replacementID = try await model.startEmbeddingBackfill(for: lease, scopes: scopes, rebuild: true)
        let replacement = try await helper.completed(model, batchID: replacementID)
        // Completion notification can precede the awaited coordinator rebind; observe it.
        for _ in 0..<400 {
            if model.semanticProcessingGeneration == replacement.generation { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replacement.generation != initial.generation)
        #expect(model.semanticProcessingGeneration == replacement.generation)
        let index = try #require(model.semanticIndex)
        let replacementDocuments = try await index.completedDocuments(generation: replacement.generation)
        #expect(replacementDocuments.filter { $0.identity.entityKind == .page }.count == 2)
        #expect(replacementDocuments.filter { $0.identity.entityKind == .source }.count == (sourcesSelected ? 1 : 0))
        #expect(try await index.generations().contains(initial.generation))
        #expect(await model.closeVault())
        await model.open(root, create: false)
        #expect(model.semanticProcessingGeneration == replacement.generation)
        #expect(await model.closeVault())
    }

    @Test @MainActor func failedReplacementRemainsPartialAndDoesNotActivate() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, _, defaults, domain, _, _, _) = try await helper.fixture(pages: 2, sources: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let initialID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        let initial = try await helper.completed(model, batchID: initialID)
        let selective = try AppleSentenceEmbeddingProvider(backend: RecoverySelectiveBackend())
        model.embeddingProviderFactory = { selective }
        let repository = try #require(model.repository)
        await model.bindAIProcessing(repository: repository, lease: lease)
        let replacementID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page, .source], rebuild: true)
        let ledger = try #require(model.aiProcessingLedger)
        var members: [EmbeddingBackfillMember] = []
        for _ in 0..<400 {
            members = try await ledger.embeddingBatchMembers(batchID: replacementID)
            if members.allSatisfy({ $0.state.isTerminal }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(members.filter { $0.entityKind == .page && $0.state == .completed }.count == 2)
        #expect(members.first { $0.entityKind == .source }?.state == .failed)
        #expect(try await ledger.embeddingBatch(id: replacementID)?.state == .active)
        #expect(model.semanticProcessingGeneration == initial.generation)
        let index = try #require(model.semanticIndex)
        #expect(try await index.generations().contains(initial.generation))
        #expect(await model.closeVault())
    }

    @Test @MainActor func editAfterActivationSnapshotDoesNotInventCurrentRevisionCompletion() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, _, defaults, domain, _, _, transport) = try await helper.fixture(pages: 1, cloud: true)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let initialID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        let initial = try await helper.completed(model, batchID: initialID)
        let repository = try #require(model.repository)
        let page = try #require(try await repository.scan().notes.first)
        let runtime = try #require(model.embeddingBackfillRuntime)
        runtime.afterRebuildInventoryValidation = {
            _ = try await repository.save(note: page, title: page.title,
                body: "An edit after the captured replacement inventory was validated.", tags: page.tags)
        }
        let replacementID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page], rebuild: true)
        let replacement = try await helper.completed(model, batchID: replacementID)
        for _ in 0..<400 {
            if model.semanticProcessingGeneration == replacement.generation { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.semanticProcessingGeneration == replacement.generation)
        let index = try #require(model.semanticIndex)
        let current = try #require(try await repository.scan().notes.first)
        #expect(current.contentHash != page.contentHash)
        let completions = try await index.completedDocuments(generation: replacement.generation)
        // Missing or captured-revision evidence is an explicitly partial generation;
        // neither can establish completion for the edited current document.
        #expect(!completions.contains { $0.identity.entityID == current.id && $0.workRevision == current.contentHash })
        // Only the two explicitly approved historical generations may submit.
        #expect(await transport.count == 2)
        #expect(!model.externalAIService.embeddingDocumentsApproved(for: lease))
        #expect(try await index.generations().contains(initial.generation))
        #expect(await model.closeVault())
    }

    @Test @MainActor func editAtFinalActivationBoundaryKeepsPreviousGeneration() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, _, defaults, domain, _, _, _) = try await helper.fixture(pages: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let initialID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        let initial = try await helper.completed(model, batchID: initialID)
        let repository = try #require(model.repository)
        let page = try #require(try await repository.scan().notes.first)
        let runtime = try #require(model.embeddingBackfillRuntime)
        runtime.beforeRebuildActivation = {
            _ = try await repository.save(note: page, title: page.title,
                body: "A human edit injected at the final replacement activation boundary.", tags: page.tags)
        }
        let replacementID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page], rebuild: true)
        let ledger = try #require(model.aiProcessingLedger)
        for _ in 0..<400 {
            if try await ledger.embeddingBatch(id: replacementID)?.state == .incompatible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await ledger.embeddingBatch(id: replacementID)?.state == .incompatible)
        #expect(model.semanticProcessingGeneration == initial.generation)
        #expect(model.semanticIndexIssue?.contains("Content changed during rebuild") == true)
        #expect(await model.closeVault())
    }
}
}
