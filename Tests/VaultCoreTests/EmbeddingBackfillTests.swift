import Foundation
import Testing
@testable import VaultCore

@Suite struct EmbeddingBackfillTests {
    private func fixture(provider: String = "apple") throws -> (URL, SQLiteAIWorkLedger, EmbeddingBackfillBatch) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ledger = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let model = try EmbeddingModelDescriptor(providerID: provider, modelID: "test-model", revision: "input-v1",
            dimensions: 3, maximumInputUTF8Bytes: 1024, maximumBatchSize: 16)
        let generation = try EmbeddingIndexGeneration(vaultID: UUID(), model: model, chunkingVersion: "test-chunks")
        let batch = try EmbeddingBackfillBatch(generation: generation, scopes: [.page], createdAt: Date(timeIntervalSince1970: 100))
        return (directory, ledger, batch)
    }
    private func page(_ batch: EmbeddingBackfillBatch) -> AIContentChange {
        AIContentChange(vaultID: batch.vaultID, entityKind: .page, entityID: UUID(), revision: "opaque-revision")
    }

    @Test func exactGenerationAndSelectedInventoryPersistWithoutBodies() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = page(batch)
        let source = AIContentChange(vaultID: batch.vaultID, entityKind: .source, entityID: UUID(), revision: "source-revision")
        let removed = AIContentChange(vaultID: batch.vaultID, entityKind: .page, entityID: UUID(), revision: "removed-revision", kind: .removed)
        try await ledger.createEmbeddingBatch(batch, inventory: [selected, source, removed])
        let recovered = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let batches = try await recovered.embeddingBatches(vaultID: batch.vaultID)
        #expect(batches == [batch])
        let members = try await recovered.embeddingBatchMembers(batchID: batch.id)
        #expect(members.count == 1)
        #expect(members.first?.entityID == selected.entityID)
        #expect(members.first?.revision == selected.revision)
        #expect(try await recovered.embeddingBatches(vaultID: UUID()).isEmpty)
    }

    @Test func persistenceBeforeAdmissionReoffersSameStableJobAfterRestart() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inventory = [page(batch)]
        try await ledger.createEmbeddingBatch(batch, inventory: inventory)
        let before = try await ledger.pendingEmbeddingAdmissions(batchID: batch.id)
        let reopened = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let replay = try await reopened.pendingEmbeddingAdmissions(batchID: batch.id)
        #expect(before == replay)
        #expect(replay.count == 1)
        let member = try #require(replay.first)
        // Simulate the other crash window: the coordinator saved a job but acknowledgment
        // did not run. A resumed admission must be the same job, not a new inference.
        let work = AIWorkItem(id: member.workID,
            key: AIWorkKey(vaultID: batch.vaultID, entityKind: member.entityKind, entityID: member.entityID,
                           processorID: EmbeddingWorkProcessor.identifier),
            revision: member.revision, processorVersion: batch.generation.id.uuidString,
            eligibleAt: Date(timeIntervalSince1970: 100))
        try await reopened.save(work)
        #expect(try await reopened.pendingEmbeddingAdmissions(batchID: batch.id).first?.workID == work.id)
        try await reopened.markEmbeddingMemberAdmitted(batchID: batch.id, workID: work.id)
        try await reopened.markEmbeddingMemberAdmitted(batchID: batch.id, workID: work.id)
        #expect(try await reopened.pendingEmbeddingAdmissions(batchID: batch.id).isEmpty)
        let repeated = try await reopened.createEmbeddingBatch(batch, inventory: inventory)
        #expect(repeated == batch)
        #expect(try await reopened.embeddingBatchMembers(batchID: batch.id).first?.state == .admitted)
    }

    @Test func admissionsAreBoundedAndCompletedMembersNeverReplay() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inventory = (0..<129).map { _ in page(batch) }
        try await ledger.createEmbeddingBatch(batch, inventory: inventory)
        let first = try await ledger.pendingEmbeddingAdmissions(batchID: batch.id, limit: 128)
        #expect(first.count == 128)
        for member in first {
            try await ledger.markEmbeddingMemberAdmitted(batchID: batch.id, workID: member.workID)
            try await ledger.updateEmbeddingMember(batchID: batch.id, workID: member.workID, state: .completed)
        }
        let last = try await ledger.pendingEmbeddingAdmissions(batchID: batch.id, limit: 128)
        #expect(last.count == 1)
        #expect(!Set(first.map(\.workID)).contains(try #require(last.first).workID))
        let reopened = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        #expect(try await reopened.pendingEmbeddingAdmissions(batchID: batch.id, limit: 128) == last)
        #expect(try await reopened.embeddingBatchMembers(batchID: batch.id, limit: 128, offset: 128).count == 1)
    }

    @Test func cloudBatchMetadataDoesNotResumeAsExecutionApproval() async throws {
        let (directory, ledger, batch) = try fixture(provider: "openai")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(batch.state == .awaitingApproval)
        try await ledger.createEmbeddingBatch(batch, inventory: [page(batch)])
        #expect(try await ledger.pendingEmbeddingAdmissions(batchID: batch.id).isEmpty)
        let reopened = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        #expect(try await reopened.embeddingBatch(id: batch.id)?.state == .awaitingApproval)
        #expect(try await reopened.pendingEmbeddingAdmissions(batchID: batch.id).isEmpty)
    }

    @Test func statusReadsDoNotResetRunningWorkAndPendingCannotClaimCompletion() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let change = page(batch)
        try await ledger.createEmbeddingBatch(batch, inventory: [change])
        let member = try #require(try await ledger.pendingEmbeddingAdmissions(batchID: batch.id).first)
        let key = AIWorkKey(vaultID: batch.vaultID, entityKind: .page, entityID: change.entityID,
                            processorID: EmbeddingWorkProcessor.identifier)
        let work = AIWorkItem(id: member.workID, key: key, revision: change.revision,
                             processorVersion: batch.generation.id.uuidString, state: .running,
                             eligibleAt: batch.createdAt)
        try await ledger.save(work)
        #expect(try await ledger.snapshotWorkItems(vaultID: batch.vaultID).first?.state == .running)
        #expect(try await ledger.existingWorkItem(key: key)?.state == .running)
        await #expect(throws: AIWorkLedgerError.self) {
            try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .completed)
        }
        try await ledger.markEmbeddingMemberAdmitted(batchID: batch.id, workID: member.workID)
        try await ledger.updateEmbeddingMember(batchID: batch.id, workID: member.workID, state: .skipped)
        try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .completed)
        #expect(try await ledger.embeddingBatch(id: batch.id)?.state == .completed)
    }

    @Test func duplicateCreationCannotChangeScopeRevisionOrGeneration() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inventory = [page(batch)]
        try await ledger.createEmbeddingBatch(batch, inventory: inventory)
        let changed = AIContentChange(vaultID: batch.vaultID, entityKind: inventory[0].entityKind,
                                      entityID: inventory[0].entityID, revision: "changed-revision")
        await #expect(throws: AIWorkLedgerError.self) { try await ledger.createEmbeddingBatch(batch, inventory: [changed]) }
        let wider = try EmbeddingBackfillBatch(id: batch.id, generation: batch.generation, scopes: [.page, .source], createdAt: batch.createdAt)
        await #expect(throws: AIWorkLedgerError.self) { try await ledger.createEmbeddingBatch(wider, inventory: inventory) }
        #expect(try await ledger.pendingEmbeddingAdmissions(batchID: batch.id).first?.revision == inventory[0].revision)
    }
}

private struct HistoricalAdmissionPolicy: AIProcessingPolicyResolver {
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority { .blocked(.consent) }
    func validateExecution(lease: VaultSessionLease) throws { throw AIWorkFailure.consent }
}
private struct HistoricalAdmissionSnapshot: AIWorkSnapshot { let revision: String; var inputFingerprint: String { revision } }
private struct HistoricalAdmissionProcessor: AIWorkProcessor {
    let batchID: UUID
    let version: String
    var descriptor: AIProcessorDescriptor {
        .init(identifier: EmbeddingWorkProcessor.identifier + ".history." + batchID.uuidString,
              version: version, targets: [.page, .source], dependencies: [.body], provider: .onDevice,
              recoverOnVersionChange: false, observesCommittedChanges: false)
    }
    func prepare(_ item: AIWorkItem, lease: VaultSessionLease) async throws -> any AIWorkSnapshot {
        HistoricalAdmissionSnapshot(revision: item.revision)
    }
    func execute(_ snapshot: any AIWorkSnapshot, context: AIProcessingExecutionContext) async throws -> AIWorkOutcome { .completed }
    func isCurrent(_ item: AIWorkItem, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async throws -> Bool { true }
}

extension EmbeddingBackfillTests {
    @Test func coordinatorHistoricalAdmissionIsExplicitStableAndDoesNotObserveCommits() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession(vaultID: batch.vaultID, root: directory, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let clock = AIProcessingClock(now: { Date(timeIntervalSince1970: 100) }, sleep: { _ in throw CancellationError() })
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: HistoricalAdmissionPolicy(), clock: clock)
        let processor = HistoricalAdmissionProcessor(batchID: batch.id, version: batch.generation.id.uuidString)
        await coordinator.register(processor)
        let change = page(batch)
        try await coordinator.bind(lease: session.lease, inventory: [change])
        try await coordinator.receive(change)
        #expect(await coordinator.workItems().isEmpty)
        try await ledger.createEmbeddingBatch(batch, inventory: [change])
        let member = try #require(try await ledger.pendingEmbeddingAdmissions(batchID: batch.id).first)
        let candidate = AIWorkItem(id: member.workID,
            key: AIWorkKey(vaultID: batch.vaultID, entityKind: .page, entityID: change.entityID,
                           processorID: processor.descriptor.identifier), revision: change.revision,
            processorVersion: processor.descriptor.version, eligibleAt: batch.createdAt, batchID: batch.id)
        try await coordinator.admitHistorical(candidate)
        try await coordinator.admitHistorical(candidate)
        #expect(await coordinator.workItems().count == 1)
        #expect(await coordinator.workItems().first?.id == member.workID)
        try await coordinator.authorityChanged()
        #expect(await coordinator.workItems().first?.state == .suspended)
        #expect(await coordinator.workItems().first?.id == member.workID)
        try await coordinator.suspend()
        let restored = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: HistoricalAdmissionPolicy(), clock: clock)
        try await restored.bind(lease: session.lease, inventory: [change])
        await restored.register(processor)
        try await restored.admitHistorical(candidate)
        #expect(await restored.workItems().first?.id == member.workID)
        #expect(await restored.workItems().first?.batchID == batch.id)
        try await restored.suspend()
    }

    @Test func coordinatorHistoricalReplayNeverRevivesCompletedOrCancelledWork() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession(vaultID: batch.vaultID, root: directory, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let clock = AIProcessingClock(now: { Date(timeIntervalSince1970: 100) }, sleep: { _ in throw CancellationError() })
        let processor = HistoricalAdmissionProcessor(batchID: batch.id, version: batch.generation.id.uuidString)
        let change = page(batch)
        let key = AIWorkKey(vaultID: batch.vaultID, entityKind: .page, entityID: change.entityID,
                            processorID: processor.descriptor.identifier)
        for state in [AIWorkState.completed, .cancelled, .failed] {
            let item = AIWorkItem(key: key, revision: change.revision, processorVersion: processor.descriptor.version,
                                  state: state, attemptCount: 3, eligibleAt: batch.createdAt, batchID: batch.id)
            try await ledger.save(item)
            let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: HistoricalAdmissionPolicy(), clock: clock)
            try await coordinator.bind(lease: session.lease, inventory: [change])
            await coordinator.register(processor)
            try await coordinator.admitHistorical(item)
            #expect(await coordinator.workItems().first?.state == state)
            #expect(await coordinator.workItems().first?.attemptCount == 3)
            try await coordinator.authorityChanged()
            #expect(await coordinator.workItems().first?.state == state)
            try await coordinator.suspend()
        }
    }
}

extension EmbeddingBackfillTests {
    @Test func persistedPauseAndCancelKeepStableHistoricalIdentityAcrossRestart() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession(vaultID: batch.vaultID, root: directory, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let clock = AIProcessingClock(now: { Date(timeIntervalSince1970: 100) }, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let processor = HistoricalAdmissionProcessor(batchID: batch.id, version: batch.generation.id.uuidString)
        let change = page(batch)
        try await ledger.createEmbeddingBatch(batch, inventory: [change])
        let member = try #require(try await ledger.pendingEmbeddingAdmissions(batchID: batch.id).first)
        let candidate = AIWorkItem(id: member.workID,
            key: AIWorkKey(vaultID: batch.vaultID, entityKind: .page, entityID: change.entityID,
                           processorID: processor.descriptor.identifier), revision: change.revision,
            processorVersion: processor.descriptor.version, eligibleAt: batch.createdAt, batchID: batch.id)
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: HistoricalAdmissionPolicy(), clock: clock)
        await coordinator.register(processor)
        try await coordinator.bind(lease: session.lease, inventory: [change])
        try await coordinator.admitHistorical(candidate)
        try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .paused)
        try await coordinator.pauseHistorical(batchID: batch.id)
        #expect(try await ledger.existingWorkItem(key: candidate.key)?.state == .suspended)
        #expect(try await ledger.existingWorkItem(key: candidate.key)?.attemptCount == 0)
        let reopened = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        #expect(try await reopened.embeddingBatch(id: batch.id)?.state == .paused)
        #expect(try await reopened.pendingEmbeddingAdmissions(batchID: batch.id).isEmpty)
        try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .active)
        try await coordinator.admitHistorical(candidate)
        try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .cancellationRequested)
        try await coordinator.cancelHistorical(batchID: batch.id)
        #expect(try await ledger.embeddingBatch(id: batch.id)?.state == .cancellationRequested)
        #expect(try await ledger.existingWorkItem(key: candidate.key)?.state == .cancelled)
        #expect(try await ledger.cancelEmbeddingMembers(batchID: batch.id) == 1)
        try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .cancelled)
        try await coordinator.admitHistorical(candidate)
        #expect(await coordinator.workItems().first?.state == .cancelled)
        #expect(await coordinator.workItems().first?.id == member.workID)
    }

    @Test func retryAndCancellationPreserveDistinctDurableOutcomes() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inventory = (0..<8).map { _ in page(batch) }
        try await ledger.createEmbeddingBatch(batch, inventory: inventory)
        let members = try await ledger.embeddingBatchMembers(batchID: batch.id)
        let states: [EmbeddingBackfillMemberState] = [.completed, .skipped, .failed, .failed, .unavailable, .blocked, .interrupted, .cancelled]
        let failures: [AIWorkFailure?] = [nil, nil, .transient, .corruptContent, .unavailable, .consent, .authority, nil]
        for (index, member) in members.enumerated() {
            try await ledger.updateEmbeddingMember(batchID: batch.id, workID: member.workID, state: states[index], failure: failures[index])
        }
        #expect(try await ledger.retryEmbeddingMembers(batchID: batch.id) == 4)
        let retried = try await ledger.embeddingBatchMembers(batchID: batch.id)
        #expect(retried.map(\.workID) == members.map(\.workID))
        #expect(retried.map(\.state) == [.completed, .skipped, .pending, .failed, .pending, .pending, .pending, .cancelled])
        try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .cancellationRequested)
        #expect(try await ledger.cancelEmbeddingMembers(batchID: batch.id) == 4)
        let cancelled = try await ledger.embeddingBatchMembers(batchID: batch.id)
        #expect(cancelled.map(\.state) == [.completed, .skipped, .cancelled, .failed, .cancelled, .cancelled, .cancelled, .cancelled])
        await #expect(throws: AIWorkLedgerError.self) { try await ledger.retryEmbeddingMembers(batchID: batch.id) }
    }

    @Test func incrementalPauseIntentSurvivesReopenAndIsVaultScoped() async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ledger.setProcessorPaused(vaultID: batch.vaultID, processorID: EmbeddingWorkProcessor.identifier, paused: true)
        let reopened = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        #expect(try await reopened.pausedProcessors(vaultID: batch.vaultID) == [EmbeddingWorkProcessor.identifier])
        #expect(try await reopened.pausedProcessors(vaultID: UUID()).isEmpty)
        try await reopened.setProcessorPaused(vaultID: batch.vaultID, processorID: EmbeddingWorkProcessor.identifier, paused: false)
        #expect(try await ledger.pausedProcessors(vaultID: batch.vaultID).isEmpty)
    }
}

private actor ControlledBackfillExecution {
    private var entered = false
    private var stopped = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func execute() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func markStopped() { stopped = true; stopWaiter?.resume(); stopWaiter = nil }
    func waitForStop() async {
        if !stopped { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
private struct ControlledBackfillPolicy: AIProcessingPolicyResolver {
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority { .allowed }
    func validateExecution(lease: VaultSessionLease) throws {}
}
private struct ControlledBackfillProcessor: AIWorkProcessor {
    let batchID: UUID
    let version: String
    let execution: ControlledBackfillExecution
    var descriptor: AIProcessorDescriptor {
        .init(identifier: EmbeddingWorkProcessor.identifier + ".history." + batchID.uuidString,
              version: version, targets: [.page], dependencies: [.body], provider: .cloud,
              recoverOnVersionChange: false, observesCommittedChanges: false)
    }
    func prepare(_ item: AIWorkItem, lease: VaultSessionLease) async throws -> any AIWorkSnapshot {
        HistoricalAdmissionSnapshot(revision: item.revision)
    }
    func execute(_ snapshot: any AIWorkSnapshot, context: AIProcessingExecutionContext) async throws -> AIWorkOutcome {
        // Emulates a provider that acknowledges cancellation late with an authority error.
        await execution.execute()
        throw AIWorkFailure.authority
    }
    func isCurrent(_ item: AIWorkItem, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async throws -> Bool { true }
}
extension EmbeddingBackfillTests {
    @Test(arguments: [false, true])
    func runningControlsPersistIntentBeforeAuthorityRetirementAndAwaitAcknowledgment(cancel: Bool) async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession(vaultID: batch.vaultID, root: directory, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let execution = ControlledBackfillExecution()
        let processor = ControlledBackfillProcessor(batchID: batch.id, version: batch.generation.id.uuidString, execution: execution)
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: ControlledBackfillPolicy(),
            clock: AIProcessingClock(now: { Date(timeIntervalSince1970: 100) }, sleep: { _ in }))
        await coordinator.register(processor)
        let change = page(batch)
        try await coordinator.bind(lease: session.lease, inventory: [change])
        let candidate = AIWorkItem(key: .init(vaultID: batch.vaultID, entityKind: .page, entityID: change.entityID,
            processorID: processor.descriptor.identifier), revision: change.revision,
            processorVersion: processor.descriptor.version, eligibleAt: batch.createdAt, batchID: batch.id)
        try await coordinator.admitHistorical(candidate)
        await execution.waitForEntry()
        let control = Task {
            let retired: @Sendable () -> Void = { Task { await execution.markStopped() } }
            if cancel { try await coordinator.cancelHistorical(batchID: batch.id, retireAuthority: retired) }
            else { try await coordinator.pauseHistorical(batchID: batch.id, retireAuthority: retired) }
        }
        await execution.waitForStop()
        #expect(await coordinator.workItems().first?.state == (cancel ? .cancellationRequested : .suspended))
        #expect(await coordinator.workItems().first?.possibleTransmittedUsage == true)
        await execution.release()
        try await control.value
        #expect(try await ledger.existingWorkItem(key: candidate.key)?.state == (cancel ? .cancelled : .suspended))
        #expect(await coordinator.status().failedCount == 0)
        #expect(try await ledger.existingWorkItem(key: candidate.key)?.possibleTransmittedUsage == true)
    }
}

extension EmbeddingBackfillTests {
    @Test(arguments: [AIWorkState.blocked, .suspended])
    func pausingStoppedHistoricalWorkPreservesItsDistinctOutcomeAndRetryCause(state: AIWorkState) async throws {
        let (directory, ledger, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = VaultSession(vaultID: batch.vaultID, root: directory, generation: 1)
        let change = page(batch)
        let processor = HistoricalAdmissionProcessor(batchID: batch.id, version: batch.generation.id.uuidString)
        let item = AIWorkItem(key: .init(vaultID: batch.vaultID, entityKind: .page, entityID: change.entityID,
            processorID: processor.descriptor.identifier), revision: change.revision,
            processorVersion: processor.descriptor.version, state: state, attemptCount: 4,
            eligibleAt: batch.createdAt, failure: state == .blocked ? .consent : .authority, batchID: batch.id)
        try await ledger.save(item)
        let coordinator = AIProcessingCoordinator(ledger: ledger,
            gate: VaultAccessGate(initialState: .open(session)), policy: HistoricalAdmissionPolicy())
        await coordinator.register(processor)
        try await coordinator.bind(lease: session.lease, inventory: [change])
        try await coordinator.pauseHistorical(batchID: batch.id)
        let paused = try #require(try await ledger.existingWorkItem(key: item.key))
        #expect(paused.state == state)
        #expect(paused.failure == (state == .blocked ? .consent : .authority))
        #expect(paused.attemptCount == 4)
        try await coordinator.retryHistorical(paused, admit: false)
        let retried = try #require(try await ledger.existingWorkItem(key: item.key))
        #expect(retried.id == item.id)
        #expect(retried.state == .suspended)
        #expect(retried.attemptCount == 0)
    }
}
