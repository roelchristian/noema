import Foundation
import PDFKit
import ExternalAI
import VaultCore

extension AppModel {
    /// Creates only the selected backend. Inventory remains a baseline, never historical consent.
    func makeEmbeddingProcessor(repository: FileVaultRepository, lease: VaultSessionLease, bindingID: UUID,
                                validatePolicy: @escaping @Sendable () throws -> Void) async throws -> EmbeddingWorkProcessor? {
        guard let index = semanticIndex else { return nil }
        let configuration = vaultAIConfigurationStore.configuration(for: lease.vaultID)
        guard configuration.enabled else { return nil }
        let native: (any EmbeddingProvider)?
        let model: EmbeddingModelDescriptor
        if configuration.provider == .onDevice {
            let selected = try embeddingProviderFactory()
            native = selected; model = selected.descriptor
        } else {
            native = nil; model = externalAIService.embeddingConfiguration.embeddingDescriptor
        }
        let stored = try await index.generations()
        guard sessionManager.accessGate.currentLease == lease, aiProcessingBindingID == bindingID,
              semanticIndex === index,
              vaultAIConfigurationStore.configuration(for: lease.vaultID) == configuration else { throw CancellationError() }
        try validatePolicy()
        if let ledger = aiProcessingLedger {
            let batches = try await ledger.embeddingBatches(vaultID: lease.vaultID)
            guard sessionManager.accessGate.currentLease == lease, aiProcessingBindingID == bindingID,
                  semanticIndex === index, vaultAIConfigurationStore.configuration(for: lease.vaultID) == configuration else { throw CancellationError() }
            if let replacement = batches.filter({ $0.mode == .rebuild && $0.state == .completed && $0.generation.model == model && $0.generation.chunkingVersion == EmbeddingChunker.version }).max(by: { $0.createdAt < $1.createdAt }) {
                semanticProcessingGeneration = replacement.generation
            }
        }
        let compatibleCached = semanticProcessingGeneration.flatMap {
            $0.vaultID == lease.vaultID && $0.model == model && $0.chunkingVersion == EmbeddingChunker.version ? $0 : nil
        }
        let generation = try compatibleCached
            ?? stored.first(where: { $0.model == model && $0.chunkingVersion == EmbeddingChunker.version })
            ?? EmbeddingIndexGeneration(vaultID: lease.vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
        // Before first publication, preserve this generation across same-session consent rebinds.
        // Otherwise fresh consent could accidentally supersede already admitted incremental jobs.
        semanticProcessingGeneration = generation
        let authority: EmbeddingPublicationAuthority
        let dispatch: EmbeddingWorkProcessor.Dispatch
        if let native {
            authority = try EmbeddingPublicationAuthority(accessGate: sessionManager.accessGate, lease: lease, generation: generation)
            dispatch = { inputs, scope, execution in
                let context = try EmbeddingExecutionContext(lease: execution.lease, scope: scope, model: model,
                    validateCurrentAuthority: { try execution.validate(); try validatePolicy() })
                let vectors = try await native.embed(inputs.map(\.text), scope: scope, context: context)
                return EmbeddingDispatchResult(vectors: vectors, validatePublication: {
                    try context.validate(scope: scope, model: model)
                })
            }
        } else {
            let service = externalAIService
            let executor = try service.makeEmbeddingRequestExecutor(lease: lease, generation: generation,
                approveRequest: { request in try await service.approveEmbeddingRequest(request) })
            authority = executor.publicationAuthority
            dispatch = { inputs, scope, execution in
                let context = try EmbeddingExecutionContext(lease: execution.lease, scope: scope, model: model,
                    validateCurrentAuthority: { try execution.validate(); try validatePolicy() })
                let completed = try await executor.embedWithEvidence(inputs.map(\.text), scope: scope, context: context)
                return EmbeddingDispatchResult(vectors: completed.result.vectors,
                    validatePublication: { try completed.validatePublication() })
            }
        }
        semanticPublicationAuthority = authority
        return try EmbeddingWorkProcessor(repository: repository, index: index, generation: generation,
            lease: lease, publicationAuthority: authority, dispatch: dispatch,
            extractOriginal: Self.embeddingOriginalText, validateAuthority: validatePolicy)
    }

    nonisolated static func embeddingOriginalText(_ snapshot: SourceSummarySnapshot) throws -> String {
        let filename = snapshot.source.metadata.originalFilename.lowercased()
        if filename.hasSuffix(".pdf") {
            guard let document = PDFDocument(data: snapshot.original), let text = document.string else {
                throw EmbeddingInputPreparationError.unavailableOriginal
            }
            return text
        }
        guard let text = String(data: snapshot.original, encoding: .utf8) else {
            throw EmbeddingInputPreparationError.unsupportedSourceType
        }
        if filename.hasSuffix(".html") || filename.hasSuffix(".htm") {
            return text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        return text
    }

    /// The historical prompt's decline actions change no scheduling or cloud authority.
    /// Checking the displayed lease prevents a dismissed old vault prompt targeting a new one.
    func declineEmbeddingBackfill(for lease: VaultSessionLease) throws {
        guard sessionManager.accessGate.currentLease == lease, repository?.sessionLease == lease else {
            throw ExternalAIError.staleSession
        }
    }

    func approveIncrementalEmbeddingDocuments(for lease: VaultSessionLease) async throws {
        guard let repository, sessionManager.accessGate.currentLease == lease else { throw ExternalAIError.staleSession }
        try await externalAIService.approveEmbeddingDocuments(for: lease)
        guard sessionManager.accessGate.currentLease == lease else { throw ExternalAIError.staleSession }
        await bindAIProcessing(repository: repository, lease: lease, preservingEmbeddingApproval: true)
    }
}
