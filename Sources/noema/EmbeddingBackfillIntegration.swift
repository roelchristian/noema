import Foundation
import Synchronization
import VaultCore
import ExternalAI

struct EmbeddingBackfillInventory: Sendable {
    let pageCount: Int
    let sourceCount: Int
}

enum EmbeddingBackfillApplicationError: Error, LocalizedError {
    case unavailable, anotherBatch, incompatible
    var errorDescription: String? {
        switch self {
        case .unavailable: "Open an enabled vault with a compatible semantic index to index existing content."
        case .anotherBatch: "Finish or cancel the existing semantic indexing batch before starting another."
        case .incompatible: "This batch uses a different provider or model. Rebuild with the current selection."
        }
    }
}

/// Runtime authority is deliberately separate from the durable batch choice. No text,
/// credentials, native capabilities or request tokens enter the work ledger.
@MainActor final class EmbeddingBackfillRuntime {
    let lease: VaultSessionLease
    let repository: FileVaultRepository
    let coordinator: AIProcessingCoordinator
    let ledger: SQLiteAIWorkLedger
    let validatePolicy: @Sendable () throws -> Void
    var sessions: [UUID: EmbeddingBackfillSession] = [:]
    var reconciling: Set<UUID> = []
    var reconcileAgain: Set<UUID> = []
    var reoffered: [UUID: Set<UUID>] = [:]
    /// Injected suspension for deterministic activation/lifecycle tests; no lock spans it.
    var beforeRebuildActivation: (@MainActor () async throws -> Void)?
    var afterRebuildInventoryValidation: (@MainActor () async throws -> Void)?
    init(lease: VaultSessionLease, repository: FileVaultRepository, coordinator: AIProcessingCoordinator,
         ledger: SQLiteAIWorkLedger, validatePolicy: @escaping @Sendable () throws -> Void) {
        self.lease = lease; self.repository = repository; self.coordinator = coordinator
        self.ledger = ledger; self.validatePolicy = validatePolicy
    }
}

final class EmbeddingBackfillSession: Sendable {
    let authority: EmbeddingPublicationAuthority
    let generation: EmbeddingIndexGeneration
    let approval: EmbeddingHistoricalBatchApproval?
    let executor: EmbeddingRequestExecutor?
    private let valid = Mutex(true)
    init(authority: EmbeddingPublicationAuthority, generation: EmbeddingIndexGeneration, approval: EmbeddingHistoricalBatchApproval? = nil,
         executor: EmbeddingRequestExecutor? = nil) {
        self.authority = authority; self.generation = generation; self.approval = approval; self.executor = executor
    }
    func validate(lease: VaultSessionLease, generation: EmbeddingIndexGeneration) throws {
        guard valid.withLock({ $0 }), authority.matches(lease: lease, generation: generation) else { throw AIWorkFailure.authority }
        try approval?.validate(lease: lease, generation: generation)
    }
    func invalidate() {
        authority.invalidate(); valid.withLock { $0 = false }
        approval?.invalidate(); executor?.invalidate()
    }
}

private final class EmbeddingHistoricalApprovalHolder: Sendable {
    let value = Mutex<EmbeddingHistoricalBatchApproval?>(nil)
}

extension AppModel {
    func backfillInventory(for lease: VaultSessionLease) async throws -> EmbeddingBackfillInventory {
        guard let repository, sessionManager.accessGate.currentLease == lease else { throw AIWorkFailure.authority }
        let inventory = try await repository.aiProcessingInventory()
        guard sessionManager.accessGate.currentLease == lease, self.repository === repository else { throw AIWorkFailure.authority }
        return EmbeddingBackfillInventory(pageCount: inventory.filter { $0.entityKind == .page && $0.kind != .removed }.count,
            sourceCount: inventory.filter { $0.entityKind == .source && $0.kind != .removed }.count)
    }

    func invalidateEmbeddingBackfills() {
        if let runtime = embeddingBackfillRuntime {
            for session in runtime.sessions.values { session.invalidate() }
        }
        embeddingBackfillRuntime = nil
    }

    func embeddingHistoricalAuthority(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) -> AIProcessingAuthority {
        guard let runtime = embeddingBackfillRuntime, runtime.lease == lease,
              sessionManager.accessGate.currentLease == lease,
              let batchID = UUID(uuidString: String(descriptor.identifier.dropFirst((EmbeddingWorkProcessor.identifier + ".history.").count))),
              let session = runtime.sessions[batchID] else { return .blocked(.consent) }
        do {
            try runtime.validatePolicy()
            try session.validate(lease: lease, generation: session.generation)
            guard descriptor.version == session.generation.id.uuidString else { return .blocked(.authority) }
            return .allowed
        } catch { return .blocked(.authority) }
    }

    /// Called only after coordinator.bind. Recovered cloud intent stays blocked until a
    /// deliberate, disclosed resume action supplies fresh session authority.
    func restoreEmbeddingBackfills(repository: FileVaultRepository, lease: VaultSessionLease,
        coordinator: AIProcessingCoordinator, ledger: SQLiteAIWorkLedger, inventory: [AIContentChange],
        validatePolicy: @escaping @Sendable () throws -> Void) async throws {
        guard sessionManager.accessGate.currentLease == lease, self.repository === repository else { throw AIWorkFailure.authority }
        let runtime = EmbeddingBackfillRuntime(lease: lease, repository: repository, coordinator: coordinator,
            ledger: ledger, validatePolicy: validatePolicy)
        embeddingBackfillRuntime = runtime
        await coordinator.setWorkChangeHandler { [weak self, weak runtime] item in
            guard let batchID = item.batchID else { return }
            Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime, self.embeddingBackfillRuntime === runtime else { return }
                do { try await self.reconcileEmbeddingBackfill(batchID: batchID, runtime: runtime) }
                catch {
                    guard self.embeddingBackfillRuntime === runtime else { return }
                    self.semanticIndexIssue = "Historical indexing needs attention. Open Semantic Indexing to resume or rebuild."
                }
            }
        }
        let batches = try await ledger.embeddingBatches(vaultID: lease.vaultID)
        try validateEmbeddingRuntime(runtime)
        guard let selected = semanticProcessingGeneration else { return }
        for batch in batches where ![.completed, .cancelled, .incompatible].contains(batch.state) {
            if batch.generation.model != selected.model || batch.generation.chunkingVersion != selected.chunkingVersion {
                try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .incompatible)
            } else if batch.generation.model.providerID == "openai" {
                if batch.state == .active { try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .awaitingApproval) }
            } else if batch.state == .active {
                try await activateEmbeddingBackfill(batch, runtime: runtime, explicitCloudApproval: false)
            }
            try validateEmbeddingRuntime(runtime)
        }
    }

    @discardableResult
    func startEmbeddingBackfill(for lease: VaultSessionLease, scopes: Set<AIEntityKind>, rebuild: Bool = false) async throws -> UUID {
        guard let runtime = embeddingBackfillRuntime, runtime.lease == lease,
              let selected = semanticProcessingGeneration else { throw EmbeddingBackfillApplicationError.unavailable }
        try validateEmbeddingRuntime(runtime)
        let prior = try await runtime.ledger.embeddingBatches(vaultID: lease.vaultID)
        try validateEmbeddingRuntime(runtime)
        guard !prior.contains(where: { ![.completed, .cancelled, .incompatible].contains($0.state) }) else {
            throw EmbeddingBackfillApplicationError.anotherBatch
        }
        let inventory = try await runtime.repository.aiProcessingInventory()
        try validateEmbeddingRuntime(runtime)
        let generation = rebuild ? try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: selected.model,
            chunkingVersion: selected.chunkingVersion) : selected
        let batch = try EmbeddingBackfillBatch(generation: generation, scopes: scopes,
            mode: rebuild ? .rebuild : .indexExisting, createdAt: aiProcessingClock.now())
        // Persist the fixed membership before either authentication or coordinator admission.
        try await runtime.ledger.createEmbeddingBatch(batch, inventory: inventory)
        try validateEmbeddingRuntime(runtime)
        try await activateEmbeddingBackfill(batch, runtime: runtime, explicitCloudApproval: true)
        return batch.id
    }

    /// This is an explicit user action. Restart restoration never invokes it for cloud batches.
    func resumeEmbeddingBackfill(batchID: UUID, for lease: VaultSessionLease) async throws {
        guard let runtime = embeddingBackfillRuntime, runtime.lease == lease,
              let batch = try await runtime.ledger.embeddingBatch(id: batchID), batch.vaultID == lease.vaultID else {
            throw EmbeddingBackfillApplicationError.unavailable
        }
        try validateEmbeddingRuntime(runtime)
        guard [.active, .awaitingApproval, .paused].contains(batch.state) else { throw EmbeddingBackfillApplicationError.incompatible }
        try await activateEmbeddingBackfill(batch, runtime: runtime, explicitCloudApproval: true)
    }

    private func activateEmbeddingBackfill(_ batch: EmbeddingBackfillBatch, runtime: EmbeddingBackfillRuntime,
                                           explicitCloudApproval: Bool) async throws {
        try validateEmbeddingRuntime(runtime)
        guard let index = semanticIndex, let selected = semanticProcessingGeneration,
              selected.model == batch.generation.model, selected.chunkingVersion == batch.generation.chunkingVersion else {
            throw EmbeddingBackfillApplicationError.incompatible
        }
        if let existing = runtime.sessions[batch.id],
           (try? existing.validate(lease: runtime.lease, generation: batch.generation)) != nil {
            try await reconcileEmbeddingBackfill(batchID: batch.id, runtime: runtime)
            return
        }
        runtime.sessions.removeValue(forKey: batch.id)?.invalidate()
        runtime.reoffered[batch.id] = []
        let session: EmbeddingBackfillSession
        let dispatch: EmbeddingWorkProcessor.Dispatch
        let generation = batch.generation
        let lease = runtime.lease
        let policyValidation = runtime.validatePolicy
        if generation.model.providerID == "openai" {
            guard explicitCloudApproval else { throw ExternalAIError.consentRequired }
            let service = externalAIService
            guard service.embeddingConfiguration.embeddingDescriptor == generation.model else { throw ExternalAIError.authorizationRevoked }
            // This is the only native-authentication point for historical batches.
            let capability = try await service.sessionManager.authorize(ExternalAIVaultAuthority(lease: lease))
            try validateEmbeddingRuntime(runtime)
            guard service.embeddingConfiguration.embeddingDescriptor == generation.model else { throw ExternalAIError.authorizationRevoked }
            let holder = EmbeddingHistoricalApprovalHolder()
            let executor = try service.makeEmbeddingRequestExecutor(lease: lease, generation: generation, approveRequest: { request in
                guard let approval = holder.value.withLock({ $0 }) else { throw ExternalAIError.consentRequired }
                return try approval.consent(for: request, generation: generation)
            })
            let approval: EmbeddingHistoricalBatchApproval
            do {
                approval = try EmbeddingHistoricalBatchApproval(approvingBatchID: batch.id, lease: lease,
                    generation: generation, includePages: batch.scopes.contains(.page), includeSources: batch.scopes.contains(.source),
                    sessions: service.sessionManager, capability: capability, publicationAuthority: executor.publicationAuthority,
                    validateCurrentAuthority: policyValidation)
            } catch { executor.invalidate(); throw error }
            holder.value.withLock { $0 = approval }
            session = EmbeddingBackfillSession(authority: executor.publicationAuthority, generation: generation, approval: approval, executor: executor)
            service.registerEmbeddingInvalidator { [weak session] in session?.invalidate() }
            dispatch = { inputs, scope, execution in
                let context = try EmbeddingExecutionContext(lease: execution.lease, scope: scope, model: generation.model,
                    validateCurrentAuthority: {
                        try execution.validate(); try policyValidation()
                        try session.validate(lease: lease, generation: generation)
                    })
                let completed = try await executor.embedWithEvidence(inputs.map(\.text), scope: scope, context: context)
                return EmbeddingDispatchResult(vectors: completed.result.vectors, validatePublication: { try completed.validatePublication() })
            }
        } else {
            let provider = try embeddingProviderFactory()
            guard provider.descriptor == generation.model else { throw EmbeddingBackfillApplicationError.incompatible }
            session = try EmbeddingBackfillSession(authority: EmbeddingPublicationAuthority(
                accessGate: sessionManager.accessGate, lease: lease, generation: generation), generation: generation)
            dispatch = { inputs, scope, execution in
                let context = try EmbeddingExecutionContext(lease: execution.lease, scope: scope, model: generation.model,
                    validateCurrentAuthority: {
                        try execution.validate(); try policyValidation()
                        try session.validate(lease: lease, generation: generation)
                    })
                let vectors = try await provider.embed(inputs.map(\.text), scope: scope, context: context)
                return EmbeddingDispatchResult(vectors: vectors, validatePublication: { try context.validate(scope: scope, model: generation.model) })
            }
        }
        try validateEmbeddingRuntime(runtime)
        let processor = try EmbeddingWorkProcessor(repository: runtime.repository, index: index, generation: generation,
            lease: lease, publicationAuthority: session.authority, dispatch: dispatch, extractOriginal: Self.embeddingOriginalText,
            validateAuthority: {
                try policyValidation(); try session.validate(lease: lease, generation: generation)
            }, batchID: batch.id)
        runtime.sessions[batch.id] = session
        await runtime.coordinator.register(processor)
        try validateEmbeddingRuntime(runtime)
        try await runtime.ledger.setEmbeddingBatchState(batchID: batch.id, state: .active)
        try await reconcileEmbeddingBackfill(batchID: batch.id, runtime: runtime)
    }

    private func validateEmbeddingRuntime(_ runtime: EmbeddingBackfillRuntime) throws {
        guard embeddingBackfillRuntime === runtime, sessionManager.accessGate.currentLease == runtime.lease,
              repository === runtime.repository else { throw AIWorkFailure.authority }
        try runtime.validatePolicy()
    }

    /// A completion observation advances metadata admission only; all delays, concurrency,
    /// retries and provider execution remain in AIProcessingCoordinator.
    private func reconcileEmbeddingBackfill(batchID: UUID, runtime: EmbeddingBackfillRuntime) async throws {
        try validateEmbeddingRuntime(runtime)
        guard !runtime.reconciling.contains(batchID) else { runtime.reconcileAgain.insert(batchID); return }
        runtime.reconciling.insert(batchID)
        defer { runtime.reconciling.remove(batchID) }
        repeat {
            runtime.reconcileAgain.remove(batchID)
            try await reconcileEmbeddingBackfillPass(batchID: batchID, runtime: runtime)
            if embeddingBackfillRuntime !== runtime { return }
            try validateEmbeddingRuntime(runtime)
        } while runtime.reconcileAgain.contains(batchID)
    }

    private func reconcileEmbeddingBackfillPass(batchID: UUID, runtime: EmbeddingBackfillRuntime) async throws {
        guard let batch = try await runtime.ledger.embeddingBatch(id: batchID), batch.state == .active,
              let session = runtime.sessions[batchID], let index = semanticIndex else { return }
        try validateEmbeddingRuntime(runtime)
        try session.validate(lease: runtime.lease, generation: batch.generation)
        let works = try await runtime.ledger.snapshotWorkItems(vaultID: runtime.lease.vaultID).filter { $0.batchID == batchID }
        let byID = Dictionary(works.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let completions = try await index.completedDocuments(generation: batch.generation)
        let inventory = try await runtime.repository.aiProcessingInventory()
        try validateEmbeddingRuntime(runtime)
        var members: [EmbeddingBackfillMember] = []
        var offset = 0
        while true {
            let page = try await runtime.ledger.embeddingBatchMembers(batchID: batchID, limit: 128, offset: offset)
            members += page; offset += page.count
            if page.count < 128 { break }
            try validateEmbeddingRuntime(runtime)
        }
        var retiredMembers = Set(members.filter { $0.state.isTerminal }.map(\.workID))
        for member in members where !member.state.isTerminal {
            var state: EmbeddingBackfillMemberState?
            var failure: AIWorkFailure?
            let current = inventory.first { $0.entityKind == member.entityKind && $0.entityID == member.entityID && $0.kind != .removed }
            if current == nil {
                state = .unavailable; failure = .unavailable; retiredMembers.insert(member.workID)
            } else if let current, current.revision != member.revision &&
                !(member.entityKind == .source && current.revision.hasPrefix(member.revision + ":")) {
                state = .superseded; retiredMembers.insert(member.workID)
            } else if let work = byID[member.workID] {
                failure = work.failure
                switch work.state {
                case .completed:
                    let durable = completions.contains { $0.identity.entityKind == member.entityKind && $0.identity.entityID == member.entityID && $0.workRevision == work.revision }
                    state = durable ? (work.completionDisposition == .skipped ? .skipped : .completed) : .failed
                    if !durable { failure = .validation }
                case .failed: state = work.failure == .unavailable ? .unavailable : .failed
                case .blocked: state = .blocked
                case .cancelled: state = .cancelled
                case .superseded: state = .superseded
                case .suspended: state = .interrupted
                default: break
                }
            } else if !inventory.contains(where: { $0.entityKind == member.entityKind && $0.entityID == member.entityID && $0.kind != .removed }) {
                state = .unavailable; failure = .unavailable
            } else if !inventory.contains(where: { $0.entityKind == member.entityKind && $0.entityID == member.entityID && ($0.revision == member.revision || (member.entityKind == .source && $0.revision.hasPrefix(member.revision + ":"))) }) {
                state = .superseded
            } else if member.entityKind == .page, completions.contains(where: {
                $0.identity.entityKind == .page && $0.identity.entityID == member.entityID && $0.workRevision == member.revision
            }) { state = .skipped }
            if let state {
                try await runtime.ledger.updateEmbeddingMember(batchID: batchID, workID: member.workID, state: state, failure: failure)
            }
            try validateEmbeddingRuntime(runtime)
        }
        let active = works.filter { [.pending, .scheduled, .running, .retryable].contains($0.state)
            && (runtime.reoffered[batchID] ?? []).contains($0.id) }.count
        var capacity = max(0, 32 - active)
        // Fresh runtime authority permits explicit replay of interrupted admissions, using
        // the same IDs. Bounded replay advances from coordinator observations, never timers.
        for work in works where !retiredMembers.contains(work.id) && capacity > 0 && [.pending, .scheduled, .running, .retryable, .suspended, .blocked].contains(work.state)
            && !(runtime.reoffered[batchID] ?? []).contains(work.id) {
            try validateEmbeddingRuntime(runtime)
            try session.validate(lease: runtime.lease, generation: batch.generation)
            runtime.reoffered[batchID, default: []].insert(work.id)
            try await runtime.coordinator.admitHistorical(work)
            capacity -= 1
        }
        if capacity > 0 {
            let pending = try await runtime.ledger.pendingEmbeddingAdmissions(batchID: batchID, limit: max(1, capacity))
            for member in pending {
                try validateEmbeddingRuntime(runtime)
                try session.validate(lease: runtime.lease, generation: batch.generation)
                let key = AIWorkKey(vaultID: member.vaultID, entityKind: member.entityKind,
                    entityID: member.entityID, processorID: EmbeddingWorkProcessor.identifier + ".history." + batchID.uuidString)
                let work = AIWorkItem(id: member.workID, key: key, revision: member.revision,
                    processorVersion: batch.generation.id.uuidString, eligibleAt: aiProcessingClock.now(),
                    updatedAt: aiProcessingClock.now(), batchID: batchID)
                runtime.reoffered[batchID, default: []].insert(work.id)
                try await runtime.coordinator.admitHistorical(work)
                try validateEmbeddingRuntime(runtime)
                try await runtime.ledger.markEmbeddingMemberAdmitted(batchID: batchID, workID: member.workID)
            }
        }
        var allComplete = true
        offset = 0
        while true {
            let page = try await runtime.ledger.embeddingBatchMembers(batchID: batchID, limit: 128, offset: offset)
            allComplete = allComplete && page.allSatisfy { [.completed, .skipped].contains($0.state) }
            offset += page.count
            if page.count < 128 { break }
            try validateEmbeddingRuntime(runtime)
        }
        if allComplete, batch.mode == .rebuild {
            try await runtime.beforeRebuildActivation?()
            try validateEmbeddingRuntime(runtime)
            // A replacement cannot become active on the strength of superseded captured
            // revisions. Incremental edits may still target the previously active generation.
            let live = try await runtime.repository.aiProcessingInventory()
            try validateEmbeddingRuntime(runtime)
            let unchanged = members.allSatisfy { member in
                live.contains { $0.entityKind == member.entityKind && $0.entityID == member.entityID &&
                    ($0.revision == member.revision || (member.entityKind == .source && $0.revision.hasPrefix(member.revision + ":"))) }
            }
            if !unchanged {
                try await runtime.ledger.setEmbeddingBatchState(batchID: batchID, state: .incompatible)
                try validateEmbeddingRuntime(runtime)
                runtime.sessions.removeValue(forKey: batchID)?.invalidate()
                semanticIndexIssue = "Content changed during rebuild. The previous generation remains active; rebuild again to replace it."
                return
            }
        }
        if allComplete {
            if batch.mode == .rebuild {
                // Activation selects a vector space for the captured membership. It is
                // not a claim of complete/current vault coverage after this snapshot.
                try await runtime.afterRebuildInventoryValidation?()
            }
            try validateEmbeddingRuntime(runtime)
            try await runtime.ledger.setEmbeddingBatchState(batchID: batchID, state: .completed)
            // The durable write suspends. A retired callback cannot select a generation
            // or remove a replacement runtime's authority after lock/switch/rebind.
            try validateEmbeddingRuntime(runtime)
            try session.validate(lease: runtime.lease, generation: batch.generation)
            runtime.sessions.removeValue(forKey: batchID)?.invalidate()
            if batch.mode == .rebuild {
                semanticProcessingGeneration = batch.generation
                await bindAIProcessing(repository: runtime.repository, lease: runtime.lease, preservingEmbeddingApproval: true, reconcileSemanticIndex: false)
            }
        }
    }
}
