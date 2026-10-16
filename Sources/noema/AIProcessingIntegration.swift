import Foundation
import VaultCore
import ExternalAI

/// Runtime policy is re-read at dispatch. Cloud automation remains blocked until a
/// processor supplies the existing request-bound AI.VAULT / D02A gateway flow.
/// Future cloud processors must bind the exact authoritative snapshot request and
/// retain its single-use capability only in memory until gateway submission.
protocol AICloudProcessingSnapshot: AIWorkSnapshot {
    func automaticRequest(lease: VaultSessionLease) throws -> ExternalAISummaryRequest
    func acceptAuthorization(_ authorization: ExternalAIBackgroundAuthorization) async
}

private struct AppAIProcessingPolicy: AIProcessingPolicyResolver {
    let resolve: @Sendable (AIProcessorDescriptor, VaultSessionLease) async -> AIProcessingAuthority
    let resolveSnapshot: @Sendable (AIProcessorDescriptor, any AIWorkSnapshot, VaultSessionLease) async -> AIProcessingAuthority
    let validate: @Sendable (VaultSessionLease) throws -> Void
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority {
        await resolve(descriptor, lease)
    }
    func authorize(_ descriptor: AIProcessorDescriptor, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async -> AIProcessingAuthority {
        await resolveSnapshot(descriptor, snapshot, lease)
    }
    func validateExecution(lease: VaultSessionLease) throws { try validate(lease) }
}

extension AppModel {
    func bindAIProcessing(repository: FileVaultRepository, lease: VaultSessionLease, preservingEmbeddingApproval: Bool = false, reconcileSemanticIndex: Bool = true) async {
        guard sessionManager.accessGate.currentLease == lease, self.repository === repository,
              repository.sessionLease == lease, repository.manifest.id == lease.vaultID else { return }
        suspendAIProcessing(preservingEmbeddingApproval: preservingEmbeddingApproval)
        let bindingID = aiProcessingBindingID
        await aiProcessingRetirementTask?.value
        let gate = sessionManager.accessGate
        guard aiProcessingBindingID == bindingID, gate.currentLease == lease else { return }
        let runtimeValidation = try? vaultAIConfigurationStore.processingPolicyValidation(lease: lease, gate: gate)
        let policy = AppAIProcessingPolicy(resolve: { [weak self] descriptor, lease in
            await MainActor.run {
                guard let self, gate.currentLease == lease else { return .blocked(.authority) }
                let configuration = self.vaultAIConfigurationStore.configuration(for: lease.vaultID)
                guard configuration.enabled else { return .blocked(.authority) }
                guard descriptor.provider == .onDevice, configuration.provider == .onDevice else { return .blocked(.consent) }
                return .allowed
            }
        }, resolveSnapshot: { [weak self] descriptor, snapshot, lease in
            guard let self else { return .blocked(.authority) }
            return await self.authorizeAIProcessing(descriptor, snapshot: snapshot, lease: lease)
        }, validate: { lease in
            try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "aiProcessing")
            guard let runtimeValidation else { throw AIWorkFailure.authority }
            try runtimeValidation()
        })
        do {
            let ledgerURL = localStorageRoot?.appendingPathComponent("Noema/Processing/work.sqlite") ?? SQLiteAIWorkLedger.defaultURL
            let ledger = try await Task.detached { try SQLiteAIWorkLedger(url: ledgerURL) }.value
            guard aiProcessingBindingID == bindingID, gate.currentLease == lease else { return }
            aiProcessingLedger = ledger
            let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: policy,
                clock: aiProcessingClock, configuration: aiProcessingConfiguration)
            let (events, continuation) = AsyncStream<AIContentChange>.makeStream()
            // Buffer commits during baseline admission, then consume them in commit order.
            await repository.setAIContentChangeHandler { _ = continuation.yield($0) }
            let inventory = try await repository.aiProcessingInventory()
            guard aiProcessingBindingID == bindingID, gate.currentLease == lease else {
                continuation.finish()
                return
            }
            // Cleanup is explicit: the coordinator intentionally never executes removed jobs.
            // Projection failures are isolated from canonical saving and all other processors.
            if let semanticIndex {
                do {
                    if reconcileSemanticIndex {
                        try await semanticIndex.reconcile(current: inventory, validatePublication: {
                            try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.reconcile")
                        })
                    }
                    if let runtimeValidation,
                       let processor = try await makeEmbeddingProcessor(repository: repository, lease: lease, bindingID: bindingID,
                           validatePolicy: runtimeValidation) {
                        await coordinator.register(processor)
                    }
                } catch {
                    if aiProcessingBindingID == bindingID, gate.currentLease == lease {
                        semanticPublicationAuthority?.invalidate(); semanticPublicationAuthority = nil
                        semanticIndexIssue = "Semantic indexing unavailable. Editing and lexical search remain available."
                    }
                }
            }
            guard aiProcessingBindingID == bindingID, gate.currentLease == lease else {
                continuation.finish(); return
            }
            try await coordinator.bind(lease: lease, inventory: inventory)
            guard aiProcessingBindingID == bindingID, gate.currentLease == lease else {
                continuation.finish()
                try? await coordinator.suspend()
                return
            }
            aiProcessingFailure = nil
            aiProcessingCoordinator = coordinator
            if let runtimeValidation {
                do {
                    try await restoreEmbeddingBackfills(repository: repository, lease: lease, coordinator: coordinator,
                        ledger: ledger, inventory: inventory, validatePolicy: runtimeValidation)
                } catch {
                    guard aiProcessingBindingID == bindingID, gate.currentLease == lease else { return }
                    semanticIndexIssue = "Historical indexing needs attention. New and changed content can still be indexed."
                }
            }
            aiProcessingEventTask = Task { [weak self] in
                for await change in events {
                    guard !Task.isCancelled else { break }
                    if change.kind == .removed, let self, self.aiProcessingBindingID == bindingID,
                       let semantic = self.semanticIndex {
                        do {
                            let canonicalRevision = change.revision.components(separatedBy: ":").first ?? ""
                            let identity = try EmbeddingEntityIdentity(vaultID: lease.vaultID, entityKind: change.entityKind,
                                entityID: change.entityID, revision: canonicalRevision)
                            try await semantic.removeEntity(identity: identity, validatePublication: {
                                try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.remove")
                            })
                        } catch { self.semanticIndexIssue = "Semantic cleanup needs a retry. Editing and lexical search remain available." }
                    }
                    do { try await coordinator.receive(change) }
                    catch {
                        guard let self, self.aiProcessingBindingID == bindingID else { break }
                        self.aiProcessingFailure = .ledger
                        try? await coordinator.suspend(reason: .ledger)
                        break
                    }
                }
            }
        } catch {
            // Scheduling failures never turn a successful canonical save into failure.
            guard aiProcessingBindingID == bindingID else { return }
            aiProcessingFailure = .ledger
            aiProcessingCoordinator = nil
        }
    }

    private func authorizeAIProcessing(_ descriptor: AIProcessorDescriptor, snapshot: any AIWorkSnapshot,
                                       lease: VaultSessionLease) async -> AIProcessingAuthority {
        guard sessionManager.accessGate.currentLease == lease else { return .blocked(.authority) }
        let policy = vaultAIConfigurationStore.configuration(for: lease.vaultID)
        guard policy.enabled else { return .blocked(.authority) }
        if descriptor.provider == .onDevice {
            return policy.provider == .onDevice ? .allowed : .blocked(.authority)
        }
        if descriptor.identifier == EmbeddingWorkProcessor.identifier {
            guard policy.provider == .openAI else { return .blocked(.authority) }
            return externalAIService.embeddingDocumentsApproved(for: lease) ? .allowed : .blocked(.consent)
        }
        if descriptor.identifier.hasPrefix(EmbeddingWorkProcessor.identifier + ".history.") {
            guard policy.provider == .openAI else { return .blocked(.authority) }
            return embeddingHistoricalAuthority(descriptor, lease: lease)
        }
        guard policy.provider == .openAI, let cloud = snapshot as? any AICloudProcessingSnapshot else { return .blocked(.unsupported) }
        do {
            let request = try cloud.automaticRequest(lease: lease)
            let authorization = try await externalAIService.authorizeAutomaticSubmission(request)
            try authorization.validate(for: request)
            guard sessionManager.accessGate.currentLease == lease else { return .blocked(.authority) }
            await cloud.acceptAuthorization(authorization)
            return .allowed
        } catch { return .blocked(.consent) }
    }

    func suspendAIProcessing(preservingEmbeddingApproval: Bool = false) {
        invalidateEmbeddingBackfills()
        aiProcessingLedger = nil
        semanticPublicationAuthority?.invalidate()
        semanticPublicationAuthority = nil
        externalAIService.invalidateEmbeddingRequests(preservingDocumentApproval: preservingEmbeddingApproval)
        aiProcessingBindingID = UUID()
        aiProcessingEventTask?.cancel()
        aiProcessingEventTask = nil
        let previousRetirement = aiProcessingRetirementTask
        let coordinator = aiProcessingCoordinator
        aiProcessingCoordinator = nil
        aiProcessingRetirementTask = Task {
            await previousRetirement?.value
            if let coordinator { try? await coordinator.suspend(reason: .authority) }
        }
    }
}
