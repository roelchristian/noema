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
    func bindAIProcessing(repository: FileVaultRepository, lease: VaultSessionLease) async {
        suspendAIProcessing()
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
            let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: policy)
            let (events, continuation) = AsyncStream<AIContentChange>.makeStream()
            // Buffer commits during baseline admission, then consume them in commit order.
            await repository.setAIContentChangeHandler { _ = continuation.yield($0) }
            let inventory = try await repository.aiProcessingInventory()
            guard aiProcessingBindingID == bindingID, gate.currentLease == lease else {
                continuation.finish()
                return
            }
            try await coordinator.bind(lease: lease, inventory: inventory)
            guard aiProcessingBindingID == bindingID, gate.currentLease == lease else {
                continuation.finish()
                try? await coordinator.suspend()
                return
            }
            aiProcessingFailure = nil
            aiProcessingCoordinator = coordinator
            aiProcessingEventTask = Task { [weak self] in
                for await change in events {
                    guard !Task.isCancelled else { break }
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

    func suspendAIProcessing() {
        semanticPublicationAuthority?.invalidate()
        semanticPublicationAuthority = nil
        externalAIService.invalidateEmbeddingRequests()
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
