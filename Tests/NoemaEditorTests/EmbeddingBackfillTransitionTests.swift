import Foundation
import Testing
@testable import ExternalAI
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct EmbeddingBackfillTransitionTests {
    @MainActor private func waitForBinding(_ model: AppModel, modelID: String, generationID: UUID? = nil) async throws {
        for _ in 0..<400 {
            if model.embeddingBackfillRuntime != nil,
               model.semanticProcessingGeneration?.model.modelID == modelID,
               generationID == nil || model.semanticProcessingGeneration?.id == generationID { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Semantic binding did not select \(modelID)")
        try #require(model.embeddingBackfillRuntime)
        #expect(model.semanticProcessingGeneration?.model.modelID == modelID)
    }

    @Test @MainActor func cloudSourceOnlyBackfillUsesFreshRequestsAndSkipsCompatibleSuccess() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, _, defaults, domain, probe, _, transport) = try await helper.fixture(pages: 2, sources: 3, cloud: true)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let repository = try #require(model.repository)
        let canonicalBefore = try await repository.scan().notes.map { $0.id.uuidString + $0.body + $0.contentHash }.sorted()
        #expect(await transport.count == 0)
        let batchID = try await model.startEmbeddingBackfill(for: lease, scopes: [.source])
        let batch = try await helper.completed(model, batchID: batchID)
        #expect(batch.scopes == [.source]); #expect(batch.state == .completed)
        let ledger = try #require(model.aiProcessingLedger)
        let members = try await ledger.embeddingBatchMembers(batchID: batchID)
        #expect(members.count == 3)
        #expect(members.allSatisfy { $0.entityKind == .source && $0.state == .completed })
        let inputs = await transport.inputs
        #expect(inputs.count == 3)
        #expect(inputs.allSatisfy { $0.count == 1 && $0[0].contains("historical source") && !$0[0].contains("historical human paragraph") })
        #expect(await transport.models == Array(repeating: OpenAIEmbeddingModel.small.rawValue, count: 3))
        #expect(probe.calls.withLock { $0 } == 0)
        #expect(!model.externalAIService.embeddingDocumentsApproved(for: lease))
        let generation = try #require(model.semanticProcessingGeneration)
        let index = try #require(model.semanticIndex)
        #expect(try await index.completedDocuments(generation: generation).allSatisfy { $0.identity.entityKind == .source })
        let again = try await model.startEmbeddingBackfill(for: lease, scopes: [.source])
        _ = try await helper.completed(model, batchID: again)
        #expect(await transport.count == 3)
        #expect(try await ledger.embeddingBatchMembers(batchID: again).allSatisfy { [.skipped, .completed].contains($0.state) })
        #expect(try await repository.scan().notes.map { $0.id.uuidString + $0.body + $0.contentHash }.sorted() == canonicalBefore)
        #expect(await model.closeVault())
    }

    @Test(arguments: [OpenAIEmbeddingModel.small, .large]) @MainActor
    func bothCloudModelTransitionsBlockCapturedHistoryAndRequireExplicitReplacement(_ initial: OpenAIEmbeddingModel) async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, _, authenticator, transport) = try await helper.fixture(pages: 1, sources: 1, cloud: true)
        defer { defaults.removePersistentDomain(forName: domain) }
        if initial == .large {
            #expect(await model.closeVault())
            try model.externalAIService.setEmbeddingModel(initial.rawValue)
            await model.open(root, create: false)
        }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let originalID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        let original = try await helper.completed(model, batchID: originalID)
        #expect(await transport.count == 1)
        // Capture unprocessed Sources in a different immutable batch. The injected delay
        // prevents provider entry and makes the configuration transition deterministic.
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let repository = try #require(model.repository)
        await model.bindAIProcessing(repository: repository, lease: lease)
        let pending = try await model.startEmbeddingBackfill(for: lease, scopes: [.source])
        #expect(await transport.count == 1)
        #expect(await model.closeVault())
        let prompts = authenticator.calls.withLock { $0 }
        let next: OpenAIEmbeddingModel = initial == .small ? .large : .small
        try model.externalAIService.setEmbeddingModel(next.rawValue)
        #expect(await transport.count == 1)
        #expect(authenticator.calls.withLock { $0 } == prompts)
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try Task.checkCancellation(); await Task.yield() })
        await model.open(root, create: false)
        let fresh = try #require(model.sessionManager.accessGate.currentLease)
        let ledger = try #require(model.aiProcessingLedger)
        #expect(try await ledger.embeddingBatch(id: pending)?.state == .incompatible)
        #expect(await transport.count == 1)
        #expect(authenticator.calls.withLock { $0 } == prompts)
        await #expect(throws: (any Error).self) { try await model.resumeEmbeddingBackfill(batchID: pending, for: fresh) }
        let index = try #require(model.semanticIndex)
        #expect(try await index.records(generation: original.generation).count == 1)
        let replacementID = try await model.startEmbeddingBackfill(for: fresh, scopes: [.page], rebuild: true)
        let replacement = try await helper.completed(model, batchID: replacementID)
        try await waitForBinding(model, modelID: next.rawValue, generationID: replacement.generation.id)
        #expect(replacement.mode == .rebuild)
        #expect(replacement.generation.model == OpenAIEmbeddingConfiguration(model: next).embeddingDescriptor)
        #expect(replacement.generation.id != original.generation.id)
        #expect(model.semanticProcessingGeneration == replacement.generation)
        #expect(await transport.count == 2)
        #expect(await transport.models == [initial.rawValue, next.rawValue])
        let generations = try await index.generations()
        #expect(generations.contains(original.generation)); #expect(generations.contains(replacement.generation))
        #expect(try await index.records(generation: original.generation).allSatisfy { $0.vector.model == original.generation.model })
        #expect(try await index.records(generation: replacement.generation).allSatisfy { $0.vector.model == replacement.generation.model })
        #expect(!model.externalAIService.embeddingDocumentsApproved(for: fresh))
        #expect(await model.closeVault())
    }

    @Test @MainActor func nativeRevisionChangeRetiresOldBatchWithoutHistoricalInference() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, probe, _, transport) = try await helper.fixture(pages: 2)
        defer { defaults.removePersistentDomain(forName: domain) }
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let repository = try #require(model.repository)
        await model.bindAIProcessing(repository: repository, lease: lease)
        let pending = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        #expect(await model.closeVault())
        let revised = try AppleSentenceEmbeddingProvider(backend: BackfillNativeBackend(probe, revision: 2))
        model.embeddingProviderFactory = { revised }
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try Task.checkCancellation(); await Task.yield() })
        await model.open(root, create: false)
        let fresh = try #require(model.sessionManager.accessGate.currentLease)
        let ledger = try #require(model.aiProcessingLedger)
        #expect(try await ledger.embeddingBatch(id: pending)?.state == .incompatible)
        #expect(probe.calls.withLock { $0 } == 0); #expect(await transport.count == 0)
        await #expect(throws: (any Error).self) { try await model.resumeEmbeddingBackfill(batchID: pending, for: fresh) }
        let replacement = try await model.startEmbeddingBackfill(for: fresh, scopes: [.page], rebuild: true)
        _ = try await helper.completed(model, batchID: replacement)
        #expect(probe.calls.withLock { $0 } == 2)
        #expect(model.semanticProcessingGeneration?.model.revision == "2")
        #expect(await model.closeVault())
    }

    @Test @MainActor func providerChangeDoesNotReuseHistoricalCloudAuthority() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, _, defaults, domain, probe, authenticator, transport) = try await helper.fixture(pages: 2, cloud: true)
        defer { defaults.removePersistentDomain(forName: domain) }
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let repository = try #require(model.repository)
        await model.bindAIProcessing(repository: repository, lease: lease)
        let pending = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        let prompts = authenticator.calls.withLock { $0 }
        try model.setVaultAIConfiguration(VaultAIConfiguration(enabled: true, provider: .onDevice), for: lease)
        try await waitForBinding(model, modelID: "sentence-en-input-v1")
        let ledger = try #require(model.aiProcessingLedger)
        for _ in 0..<400 {
            if try await ledger.embeddingBatch(id: pending)?.state == .incompatible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await ledger.embeddingBatch(id: pending)?.state == .incompatible)
        #expect(probe.calls.withLock { $0 } == 0); #expect(await transport.count == 0)
        #expect(authenticator.calls.withLock { $0 } == prompts)
        await #expect(throws: (any Error).self) { try await model.resumeEmbeddingBackfill(batchID: pending, for: lease) }
        #expect(await model.closeVault())
    }

    @Test @MainActor func globalModelPreferenceLeavesUnapprovedAndPreviouslyUnopenedVaultsQuiet() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, probe, authenticator, transport) = try await helper.fixture(pages: 2, cloud: true)
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(await model.closeVault())
        let unopenedRoot = root.deletingLastPathComponent().appendingPathComponent("unopened-vault")
        try FileManager.default.createDirectory(at: unopenedRoot, withIntermediateDirectories: true)
        let unopened = try await openCanonicalAppFixture(root: unopenedRoot, create: true)
        _ = try await unopened.create(title: "Unopened history", body: "This committed content has no historical OpenAI approval.")
        defaults.set(try JSONEncoder().encode(VaultAIConfiguration(enabled: true, provider: .openAI)),
                     forKey: VaultAIConfigurationStore.key(for: unopened.manifest.id))
        try await unopened.shutdownPageStorage()
        try model.externalAIService.setEmbeddingModel(OpenAIEmbeddingModel.large.rawValue)
        #expect(await transport.count == 0)
        for selectedRoot in [root, unopenedRoot] {
            await model.open(selectedRoot, create: false)
            let lease = try #require(model.sessionManager.accessGate.currentLease)
            let ledger = try #require(model.aiProcessingLedger)
            #expect(try await ledger.embeddingBatches(vaultID: lease.vaultID).isEmpty)
            #expect(model.semanticProcessingGeneration?.model == OpenAIEmbeddingConfiguration(model: .large).embeddingDescriptor)
            #expect(!model.externalAIService.embeddingDocumentsApproved(for: lease))
            #expect(await transport.count == 0); #expect(probe.calls.withLock { $0 } == 0)
            #expect(authenticator.calls.withLock { $0 } == 0)
            #expect(await model.closeVault())
        }
    }


    @Test(arguments: [false, true]) @MainActor
    func bothDeclineActionsStartNoHistoricalWorkAndPermitLaterExplicitIndexing(_ cloud: Bool) async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, probe, authenticator, transport) = try await helper.fixture(pages: 1, sources: 1, cloud: cloud)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let inventory = try await model.backfillInventory(for: lease)
        #expect(inventory.pageCount == 1); #expect(inventory.sourceCount == 1)
        // Both Settings callbacks invoke this same lease-bound production action.
        try model.declineEmbeddingBackfill(for: lease) // New and Changed Content Only
        try model.declineEmbeddingBackfill(for: lease) // Not Now
        let ledger = try #require(model.aiProcessingLedger)
        #expect(try await ledger.embeddingBatches(vaultID: lease.vaultID).isEmpty)
        #expect(try await ledger.snapshotWorkItems(vaultID: lease.vaultID).isEmpty)
        #expect(probe.calls.withLock { $0 } == 0); #expect(await transport.count == 0)
        #expect(authenticator.calls.withLock { $0 } == 0)
        let later = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        _ = try await helper.completed(model, batchID: later)
        if cloud { #expect(await transport.count == 1) }
        else { #expect(probe.calls.withLock { $0 } == 1) }
        #expect(await model.closeVault())
        await model.open(root, create: false)
        #expect(throws: (any Error).self) { try model.declineEmbeddingBackfill(for: lease) }
        #expect(await model.closeVault())
    }

}
}
