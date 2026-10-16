import Foundation
import VaultCore

struct EmbeddingQueueBatch: Identifiable, Sendable {
    let batch: EmbeddingBackfillBatch
    let members: [EmbeddingBackfillMember]
    let work: [AIWorkItem]
    var id: UUID { batch.id }
}

/// Presentation reads the persisted ledger without recovering or scheduling work.
struct EmbeddingQueueSnapshot: Sendable {
    let incremental: [AIWorkItem]
    let batches: [EmbeddingQueueBatch]
    var incrementalPaused = false
    var activeCount: Int {
        (incrementalPaused ? 0 : incremental.filter { [.pending, .scheduled, .running, .retryable].contains($0.state) }.count) +
        batches.filter { $0.batch.state == .active }.reduce(0) { count, batch in
            count + batch.members.filter { [.pending, .admitted].contains($0.state) }.count
        }
    }
    static let empty = Self(incremental: [], batches: [])
    static func status(_ item: AIWorkItem) -> String {
        if item.state == .completed, item.completionDisposition == .skipped { return "Skipped (unchanged)" }
        if item.state == .suspended { return "Interrupted / paused" }
        if item.state == .cancellationRequested { return "Cancellation requested" }
        if item.failure == .unavailable { return "Unavailable" }
        switch item.state {
        case .pending: return "Waiting"
        case .scheduled: return "Scheduled"
        case .running: return "Indexing"
        case .completed: return "Completed"
        case .superseded: return "Content changed"
        case .suspended: return "Paused"
        case .retryable: return "Waiting to retry"
        case .blocked: return "Needs attention"
        case .failed: return "Failed"
        case .cancellationRequested: return "Cancellation requested"
        case .cancelled: return "Cancelled"
        }
    }
    static func failureLabel(_ failure: AIWorkFailure) -> String {
        switch failure {
        case .authority: "Session or permission changed"
        case .consent: "Approval required"
        case .unavailable: "Content or provider unavailable"
        case .transient: "Temporary provider problem"
        case .unsupported: "Unsupported content"
        case .corruptContent: "Content could not be read"
        case .validation: "Result could not be verified"
        case .ledger: "Queue could not be saved"
        case .attemptsExhausted: "Retry limit reached"
        }
    }
    static func batchStatus(_ state: EmbeddingBackfillState) -> String {
        switch state {
        case .active: "In progress"
        case .paused: "Paused"
        case .awaitingApproval: "Approval required"
        case .cancellationRequested: "Cancellation requested"
        case .cancelled: "Cancelled"
        case .completed: "Completed"
        case .incompatible: "Rebuild required"
        }
    }
    static func memberStatus(_ state: EmbeddingBackfillMemberState) -> String {
        switch state {
        case .pending: "Waiting"
        case .admitted: "Queued"
        case .completed: "Completed"
        case .skipped: "Skipped (unchanged)"
        case .blocked: "Needs attention"
        case .failed: "Failed"
        case .unavailable: "Unavailable"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        case .superseded: "Content changed"
        }
    }
}

extension AppModel {
    func embeddingQueueSnapshot(for lease: VaultSessionLease) async throws -> EmbeddingQueueSnapshot {
        guard let ledger = aiProcessingLedger, sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        let works = try await ledger.snapshotWorkItems(vaultID: lease.vaultID)
        let batches = try await ledger.embeddingBatches(vaultID: lease.vaultID)
        let paused = try await ledger.pausedProcessors(vaultID: lease.vaultID)
        var values: [EmbeddingQueueBatch] = []
        for batch in batches {
            var members: [EmbeddingBackfillMember] = [], offset = 0
            while true {
                let page = try await ledger.embeddingBatchMembers(batchID: batch.id, limit: 128, offset: offset)
                members += page; offset += page.count
                if page.count < 128 { break }
            }
            values.append(EmbeddingQueueBatch(batch: batch, members: members, work: works.filter { $0.batchID == batch.id }))
        }
        guard sessionManager.accessGate.currentLease == lease, aiProcessingLedger === ledger else { throw AIWorkFailure.authority }
        return EmbeddingQueueSnapshot(incremental: works.filter { $0.key.processorID == EmbeddingWorkProcessor.identifier && $0.batchID == nil }
            .sorted { $0.updatedAt > $1.updatedAt }, batches: values.reversed(), incrementalPaused: paused.contains(EmbeddingWorkProcessor.identifier))
    }

    func pauseEmbeddingBackfill(batchID: UUID, for lease: VaultSessionLease) async throws {
        guard let runtime = embeddingBackfillRuntime, runtime.lease == lease,
              sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        guard let batch = try await runtime.ledger.embeddingBatch(id: batchID), batch.vaultID == lease.vaultID,
              embeddingBackfillRuntime === runtime, sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        let session = runtime.sessions[batchID]
        try await runtime.ledger.setEmbeddingBatchState(batchID: batchID, state: .paused)
        try await runtime.coordinator.pauseHistorical(batchID: batchID, retireAuthority: { session?.invalidate() })
        runtime.sessions.removeValue(forKey: batchID)
        try await reconcileStoppedEmbeddingMembers(batchID: batchID, runtime: runtime)
    }

    func cancelEmbeddingBackfill(batchID: UUID, for lease: VaultSessionLease) async throws {
        guard let runtime = embeddingBackfillRuntime, runtime.lease == lease,
              sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        guard let batch = try await runtime.ledger.embeddingBatch(id: batchID), batch.vaultID == lease.vaultID,
              embeddingBackfillRuntime === runtime, sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        let session = runtime.sessions[batchID]
        try await runtime.ledger.setEmbeddingBatchState(batchID: batchID, state: .cancellationRequested)
        try await runtime.coordinator.cancelHistorical(batchID: batchID, retireAuthority: { session?.invalidate() })
        runtime.sessions.removeValue(forKey: batchID)
        guard embeddingBackfillRuntime === runtime, sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        try await reconcileStoppedEmbeddingMembers(batchID: batchID, runtime: runtime)
        _ = try await runtime.ledger.cancelEmbeddingMembers(batchID: batchID)
        try await runtime.ledger.setEmbeddingBatchState(batchID: batchID, state: .cancelled)
    }

    /// Reconcile settled jobs without admission. Paused/cancelling batches have no
    /// live session, but already committed completions must survive their stop intent.
    func reconcileStoppedEmbeddingMembers(batchID: UUID, runtime: EmbeddingBackfillRuntime) async throws {
        guard embeddingBackfillRuntime === runtime, sessionManager.accessGate.currentLease == runtime.lease,
              let batch = try await runtime.ledger.embeddingBatch(id: batchID), batch.vaultID == runtime.lease.vaultID else { throw AIWorkFailure.authority }
        let works = try await runtime.ledger.snapshotWorkItems(vaultID: runtime.lease.vaultID)
        let byID = Dictionary(works.filter { $0.batchID == batchID }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let completions = try await semanticIndex?.completedDocuments(generation: batch.generation) ?? []
        var offset = 0
        while true {
            let members = try await runtime.ledger.embeddingBatchMembers(batchID: batchID, limit: 128, offset: offset)
            for member in members where !member.state.isTerminal {
                guard embeddingBackfillRuntime === runtime, sessionManager.accessGate.currentLease == runtime.lease else { throw AIWorkFailure.authority }
                guard let work = byID[member.workID] else { continue }
                let state: EmbeddingBackfillMemberState
                var failure = work.failure
                let durable = completions.contains {
                    $0.identity.entityKind == member.entityKind && $0.identity.entityID == member.entityID &&
                    $0.workRevision == work.revision
                }
                // Final index COMMIT can precede the coordinator's outcome write.
                // Publication evidence wins when stop intent overtakes that write.
                if durable {
                    state = work.completionDisposition == .skipped ? .skipped : .completed
                    failure = nil
                } else {
                    switch work.state {
                    case .completed: state = .failed; failure = .validation
                    case .failed: state = failure == .unavailable ? .unavailable : .failed
                    case .blocked: state = .blocked
                    case .cancelled: state = .cancelled
                    case .superseded: state = .superseded
                    case .suspended: state = .interrupted
                    default: continue
                    }
                }
                try await runtime.ledger.updateEmbeddingMember(batchID: batchID, workID: member.workID, state: state, failure: failure)
            }
            offset += members.count
            if members.count < 128 { break }
        }
    }

    /// Invoked only by an explicit disclosure action; native authority is freshly minted
    /// by activation. The ledger retry reset never creates cloud request permission.
    func retryEmbeddingBackfill(batchID: UUID, for lease: VaultSessionLease) async throws {
        guard let runtime = embeddingBackfillRuntime, runtime.lease == lease,
              sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        guard let batch = try await runtime.ledger.embeddingBatch(id: batchID), batch.vaultID == lease.vaultID,
              embeddingBackfillRuntime === runtime, sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        try await pauseEmbeddingBackfill(batchID: batchID, for: lease)
        _ = try await runtime.ledger.retryEmbeddingMembers(batchID: batchID)
        let works = try await runtime.ledger.snapshotWorkItems(vaultID: lease.vaultID)
        for work in works where work.batchID == batchID && [.failed, .blocked, .suspended].contains(work.state) {
            guard let failure = work.failure,
                  failure.permitsExplicitRetry else { continue }
            try await runtime.coordinator.retryHistorical(work, admit: false)
        }
        try await resumeEmbeddingBackfill(batchID: batchID, for: lease)
    }
}

extension AppModel {
    private func embeddingQueueCoordinator(for lease: VaultSessionLease) throws -> AIProcessingCoordinator {
        guard sessionManager.accessGate.currentLease == lease, let coordinator = aiProcessingCoordinator else { throw AIWorkFailure.authority }
        return coordinator
    }
    func pauseIncrementalEmbeddingQueue(for lease: VaultSessionLease) async throws {
        try await embeddingQueueCoordinator(for: lease).pauseProcessor(EmbeddingWorkProcessor.identifier)
    }
    func resumeIncrementalEmbeddingQueue(for lease: VaultSessionLease) async throws {
        try await embeddingQueueCoordinator(for: lease).resumeProcessor(EmbeddingWorkProcessor.identifier)
    }
    func cancelIncrementalEmbeddingQueue(for lease: VaultSessionLease) async throws {
        try await embeddingQueueCoordinator(for: lease).cancelProcessorRemaining(EmbeddingWorkProcessor.identifier)
    }
    func retryIncrementalEmbeddingQueue(for lease: VaultSessionLease) async throws {
        let coordinator = try embeddingQueueCoordinator(for: lease)
        try await coordinator.retryEligibleEmbeddingWork(processorID: EmbeddingWorkProcessor.identifier)
        try await coordinator.resumeProcessor(EmbeddingWorkProcessor.identifier)
    }
}
