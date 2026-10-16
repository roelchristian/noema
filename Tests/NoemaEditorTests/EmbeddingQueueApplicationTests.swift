import Foundation
import Testing
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct EmbeddingQueueApplicationTests {
    @Test @MainActor func durableQueueSnapshotDoesNotAdmitAndPauseSurvivesRestart() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, probe, _, _) = try await helper.fixture(pages: 3)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let repository = try #require(model.repository)
        await model.bindAIProcessing(repository: repository, lease: lease)
        let batchID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        try await model.pauseEmbeddingBackfill(batchID: batchID, for: lease)
        let snapshot = try await model.embeddingQueueSnapshot(for: lease)
        #expect(snapshot.batches.first?.batch.state == .paused)
        #expect(snapshot.batches.first?.members.count == 3)
        #expect(snapshot.activeCount == 0)
        #expect(probe.calls.withLock { $0 } == 0)
        #expect(await model.closeVault())
        await model.open(root, create: false)
        let reopened = try #require(model.sessionManager.accessGate.currentLease)
        let recovered = try await model.embeddingQueueSnapshot(for: reopened)
        #expect(recovered.batches.first?.batch.state == .paused)
        #expect(probe.calls.withLock { $0 } == 0)
        try await model.cancelEmbeddingBackfill(batchID: batchID, for: reopened)
        let cancelled = try await model.embeddingQueueSnapshot(for: reopened)
        #expect(cancelled.batches.first?.batch.state == .cancelled)
        #expect(cancelled.batches.first?.members.allSatisfy { $0.state == .cancelled } == true)
        await #expect(throws: AIWorkFailure.self) { try await model.embeddingQueueSnapshot(for: lease) }
        #expect(await model.closeVault())
    }

    @Test @MainActor func incrementalPauseBeforeFirstVectorReopensExactJobAndResumes() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, probe, _, _) = try await helper.fixture(pages: 0)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let repository = try #require(model.repository)
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        await model.bindAIProcessing(repository: repository, lease: lease)
        let generation = try #require(model.semanticProcessingGeneration)
        let page = try await repository.create(title: "New committed page", body: "A newly committed human paragraph about an island.")
        var admitted: AIWorkItem?
        for _ in 0..<400 {
            admitted = try await model.embeddingQueueSnapshot(for: lease).incremental.first { $0.key.entityID == page.id }
            if admitted != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let originalJob = try #require(admitted)
        try await model.pauseIncrementalEmbeddingQueue(for: lease)
        #expect(probe.calls.withLock { $0 } == 0)
        let index = try #require(model.semanticIndex)
        #expect(try await index.generations().contains(generation))
        #expect(try await index.completedDocuments(generation: generation).isEmpty)
        #expect(await model.closeVault())
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try Task.checkCancellation(); await Task.yield() })
        await model.open(root, create: false)
        let fresh = try #require(model.sessionManager.accessGate.currentLease)
        let reopened = try await model.embeddingQueueSnapshot(for: fresh)
        let recovered = try #require(reopened.incremental.first { $0.key.entityID == page.id })
        #expect(reopened.incrementalPaused)
        #expect(reopened.activeCount == 0)
        #expect(recovered.id == originalJob.id)
        #expect(recovered.revision == originalJob.revision)
        #expect(model.semanticProcessingGeneration == generation)
        #expect(probe.calls.withLock { $0 } == 0)
        try await model.resumeIncrementalEmbeddingQueue(for: fresh)
        var completed = false
        for _ in 0..<400 {
            completed = try await model.embeddingQueueSnapshot(for: fresh).incremental.contains {
                $0.id == originalJob.id && $0.state == .completed
            }
            if completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed)
        #expect(probe.calls.withLock { $0 } == 1)
        #expect(await model.closeVault())
    }

    @Test(arguments: [false, true]) @MainActor
    func explicitRetryAfterRestartCompletesOnlyEligibleCapturedMembers(_ cloud: Bool) async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, root, defaults, domain, probe, authenticator, transport) = try await helper.fixture(pages: 1, cloud: cloud)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let repository = try #require(model.repository)
        let originalPage = try #require(try await repository.aiProcessingInventory().first { $0.entityKind == .page })
        let initialID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        _ = try await helper.completed(model, batchID: initialID)
        try await model.pauseIncrementalEmbeddingQueue(for: lease)
        for number in 0..<4 {
            _ = try await repository.create(title: "Retry page \(number)", body: "A committed human paragraph about retry evidence numbered \(number).")
        }
        let generation = try #require(model.semanticProcessingGeneration)
        let ledger = try #require(model.aiProcessingLedger)
        model.suspendAIProcessing()
        await model.aiProcessingRetirementTask?.value
        let captured = try EmbeddingBackfillBatch(generation: generation, scopes: [.page], createdAt: Date(), state: .active)
        try await ledger.createEmbeddingBatch(captured, inventory: repository.aiProcessingInventory())
        let members = try await ledger.embeddingBatchMembers(batchID: captured.id)
        let newMembers = members.filter { $0.entityID != originalPage.entityID }
        #expect(newMembers.count == 4)
        let eligibleIDs = Set(newMembers.prefix(2).map(\.workID))
        let cancelledID = newMembers[2].workID
        let unsupportedID = newMembers[3].workID
        for member in members {
            let state: AIWorkState
            let memberState: EmbeddingBackfillMemberState
            let failure: AIWorkFailure?
            if member.entityID == originalPage.entityID {
                state = .completed; memberState = .completed; failure = nil
            } else if member.workID == newMembers[0].workID {
                state = .failed; memberState = .failed; failure = .transient
            } else if member.workID == newMembers[1].workID {
                state = .failed; memberState = .failed; failure = .attemptsExhausted
            } else if member.workID == cancelledID {
                state = .cancelled; memberState = .cancelled; failure = nil
            } else {
                state = .failed; memberState = .failed; failure = .unsupported
            }
            try await ledger.markEmbeddingMemberAdmitted(batchID: captured.id, workID: member.workID)
            try await ledger.updateEmbeddingMember(batchID: captured.id, workID: member.workID, state: memberState, failure: failure)
            let key = AIWorkKey(vaultID: lease.vaultID, entityKind: member.entityKind, entityID: member.entityID,
                processorID: EmbeddingWorkProcessor.identifier + ".history." + captured.id.uuidString)
            try await ledger.save(AIWorkItem(id: member.workID, key: key, revision: member.revision,
                processorVersion: generation.id.uuidString, state: state, attemptCount: 4, eligibleAt: Date(),
                failure: failure, batchID: captured.id, completionDisposition: state == .completed ? .completed : nil))
        }
        try await ledger.setEmbeddingBatchState(batchID: captured.id, state: .paused)
        let promptsBefore = authenticator.calls.withLock { $0 }
        let requestsBefore = await transport.count
        let nativeBefore = probe.calls.withLock { $0 }
        #expect(await model.closeVault())
        await model.open(root, create: false)
        let fresh = try #require(model.sessionManager.accessGate.currentLease)
        #expect(authenticator.calls.withLock { $0 } == promptsBefore)
        #expect(await transport.count == requestsBefore)
        #expect(probe.calls.withLock { $0 } == nativeBefore)
        try await model.retryEmbeddingBackfill(batchID: captured.id, for: fresh)
        let reopenedLedger = try #require(model.aiProcessingLedger)
        var recovered: [EmbeddingBackfillMember] = []
        for _ in 0..<400 {
            recovered = try await reopenedLedger.embeddingBatchMembers(batchID: captured.id)
            if recovered.filter({ eligibleIDs.contains($0.workID) }).allSatisfy({ $0.state == .completed }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(recovered.map(\.workID)) == Set(members.map(\.workID)))
        #expect(recovered.filter { eligibleIDs.contains($0.workID) }.allSatisfy { $0.state == .completed })
        #expect(recovered.first { $0.entityID == originalPage.entityID }?.state == .completed)
        #expect(recovered.first { $0.workID == cancelledID }?.state == .cancelled)
        #expect(recovered.first { $0.workID == unsupportedID }?.failure == .unsupported)
        let works = try await reopenedLedger.snapshotWorkItems(vaultID: fresh.vaultID).filter { $0.batchID == captured.id }
        #expect(works.filter { eligibleIDs.contains($0.id) }.allSatisfy { $0.state == .completed && $0.attemptCount == 1 })
        #expect(works.allSatisfy { work in members.contains { $0.workID == work.id && $0.revision == work.revision } })
        #expect(authenticator.calls.withLock { $0 } == promptsBefore + (cloud ? 1 : 0))
        #expect(await transport.count == requestsBefore + (cloud ? 2 : 0))
        #expect(probe.calls.withLock { $0 } == nativeBefore + (cloud ? 0 : 2))
        #expect(await model.closeVault())
    }

    @Test @MainActor func queueControlsRejectForeignVaultBatch() async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, _, defaults, domain, _, _, _) = try await helper.fixture(pages: 0)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let ledger = try #require(model.aiProcessingLedger)
        let selected = try #require(model.semanticProcessingGeneration)
        let foreignGeneration = try EmbeddingIndexGeneration(vaultID: UUID(), model: selected.model,
            chunkingVersion: selected.chunkingVersion)
        let foreign = try EmbeddingBackfillBatch(generation: foreignGeneration, scopes: [.page], createdAt: Date())
        try await ledger.createEmbeddingBatch(foreign, inventory: [])
        await #expect(throws: (any Error).self) { try await model.pauseEmbeddingBackfill(batchID: foreign.id, for: lease) }
        await #expect(throws: (any Error).self) { try await model.cancelEmbeddingBackfill(batchID: foreign.id, for: lease) }
        await #expect(throws: (any Error).self) { try await model.retryEmbeddingBackfill(batchID: foreign.id, for: lease) }
        #expect(try await ledger.embeddingBatch(id: foreign.id)?.state == .active)
        #expect(await model.closeVault())
    }

    @Test(arguments: [AIWorkState.completed, .cancelled, .suspended]) @MainActor
    func completedQueuePreservesVectorsAndOutcomes(_ stoppedState: AIWorkState) async throws {
        let helper = EmbeddingBackfillApplicationTests()
        let (model, _, defaults, domain, probe, _, _) = try await helper.fixture(pages: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let batchID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        _ = try await helper.completed(model, batchID: batchID)
        let snapshot = try await model.embeddingQueueSnapshot(for: lease)
        #expect(snapshot.batches.first?.members.first?.state == .completed)
        #expect(snapshot.activeCount == 0)
        #expect(probe.calls.withLock { $0 } == 1)
        let index = try #require(model.semanticIndex)
        let generation = try #require(model.semanticProcessingGeneration)
        #expect(try await index.completedDocuments(generation: generation).count == 1)
        // Simulate the exact crash/observer gap: document work is durably complete,
        // while its historical member has not yet consumed that notification.
        let ledger = try #require(model.aiProcessingLedger)
        let repository = try #require(model.repository)
        let captured = try await repository.aiProcessingInventory()
        let stale = try EmbeddingBackfillBatch(generation: generation, scopes: [.page], createdAt: Date())
        try await ledger.createEmbeddingBatch(stale, inventory: captured)
        let member = try #require(try await ledger.embeddingBatchMembers(batchID: stale.id).first)
        try await ledger.markEmbeddingMemberAdmitted(batchID: stale.id, workID: member.workID)
        let key = AIWorkKey(vaultID: lease.vaultID, entityKind: member.entityKind, entityID: member.entityID,
            processorID: EmbeddingWorkProcessor.identifier + ".history." + stale.id.uuidString)
        let work = AIWorkItem(id: member.workID, key: key, revision: member.revision,
            processorVersion: generation.id.uuidString, state: stoppedState, eligibleAt: Date(),
            batchID: stale.id, completionDisposition: .completed)
        try await ledger.save(work)
        try await model.cancelEmbeddingBackfill(batchID: stale.id, for: lease)
        let retained = try await ledger.embeddingBatchMembers(batchID: stale.id)
        #expect(retained.first?.state == .completed)
        #expect(try await index.completedDocuments(generation: generation).count == 1)
        #expect(await model.closeVault())
    }
}
}
