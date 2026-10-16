import Foundation
import ExternalAI
import Synchronization
import VaultCore

/// App composition for one explicitly submitted Meaning search. The owner invalidates
/// on query/scope changes and retains its completion ticket through final assignment.
@MainActor final class SemanticQueryExecutionAdapter {
    let queryID: UUID
    let generation: EmbeddingIndexGeneration
    let publicationAuthority: EmbeddingPublicationAuthority
    private let execution: SemanticQueryExecution
    private let context: EmbeddingExecutionContext
    private let lifetime: SemanticQueryLifetime
    private weak var service: ExternalAIService?
    private var registrations: [UUID] = []

    private init(queryID: UUID, generation: EmbeddingIndexGeneration,
                 execution: SemanticQueryExecution, context: EmbeddingExecutionContext, lifetime: SemanticQueryLifetime,
                 publicationAuthority: EmbeddingPublicationAuthority) throws {
        guard generation.vaultID == context.lease.vaultID, generation.model == execution.descriptor,
              generation.chunkingVersion == EmbeddingChunker.version else {
            throw EmbeddingContractError.incompatibleGeneration
        }
        self.publicationAuthority = publicationAuthority
        self.queryID = queryID; self.generation = generation
        self.execution = execution; self.context = context; self.lifetime = lifetime
    }

    deinit {
        publicationAuthority.invalidate(); lifetime.invalidate(); execution.invalidate()
        let registrations = registrations, service = service
        Task { @MainActor in
            for registration in registrations { service?.removeEmbeddingInvalidator(registration) }
        }
    }

    static func native(provider: any EmbeddingProvider, lease: VaultSessionLease,
                       generation: EmbeddingIndexGeneration, accessGate: VaultAccessGate,
                       queryID: UUID = UUID(), validateCurrentAuthority: @escaping @Sendable () throws -> Void
    ) throws -> SemanticQueryExecutionAdapter {
        let lifetime = SemanticQueryLifetime()
        let context = try makeContext(lease: lease, generation: generation, accessGate: accessGate,
            queryID: queryID, lifetime: lifetime, validateCurrentAuthority: validateCurrentAuthority)
        return try Self(queryID: queryID, generation: generation,
            execution: SemanticQueryExecution(native: provider), context: context, lifetime: lifetime,
            publicationAuthority: EmbeddingPublicationAuthority(accessGate: accessGate, lease: lease, generation: generation))
    }

    /// The callback must present the exact request disclosure and return true only
    /// after explicit acceptance. Construction, typing and Settings never execute it.
    static func cloud(service: ExternalAIService, lease: VaultSessionLease,
                      generation: EmbeddingIndexGeneration, accessGate: VaultAccessGate,
                      queryID: UUID = UUID(),
                      validateCurrentAuthority: @escaping @Sendable () throws -> Void,
                      approveQuery: @escaping @MainActor @Sendable (ExternalAIEmbeddingRequest) async throws -> Bool
    ) throws -> SemanticQueryExecutionAdapter {
        let lifetime = SemanticQueryLifetime()
        let context = try makeContext(lease: lease, generation: generation, accessGate: accessGate,
            queryID: queryID, lifetime: lifetime, validateCurrentAuthority: validateCurrentAuthority)
        var registrations = [UUID]()
        let executor = try service.makeEmbeddingRequestExecutor(lease: lease, generation: generation,
            didRegisterInvalidator: { registrations.append($0) }) { request in
            try context.validate(scope: request.scope, model: request.model)
            guard case .query(let vaultID, let requestedID) = request.scope,
                  vaultID == lease.vaultID, requestedID == queryID,
                  request.authority.matches(lease), request.model == generation.model else {
                throw ExternalAIError.consentRequired
            }
            let credential = await service.credentialBroker.status()
            try context.validate(scope: request.scope, model: request.model)
            guard credential.isAvailable else { throw ExternalAIError.credentialUnavailable }
            guard try await approveQuery(request) else { throw ExternalAIError.consentRequired }
            try context.validate(scope: request.scope, model: request.model)
            guard await service.credentialBroker.status() == credential else {
                throw ExternalAIError.authorizationRevoked
            }
            try context.validate(scope: request.scope, model: request.model)
            // Explicit acceptance permits native authentication, never a document grant.
            _ = try await service.sessionManager.authorize(ExternalAIVaultAuthority(lease: lease))
            try context.validate(scope: request.scope, model: request.model)
            guard await service.credentialBroker.status() == credential else {
                throw ExternalAIError.authorizationRevoked
            }
            try context.validate(scope: request.scope, model: request.model)
            return try ExternalAIEmbeddingConsent(approvingQuery: request)
        }
        let adapter = try Self(queryID: queryID, generation: generation,
            execution: SemanticQueryExecution(cloud: executor), context: context, lifetime: lifetime,
            publicationAuthority: executor.publicationAuthority)
        registrations.append(service.registerEmbeddingInvalidator { [weak lifetime] in lifetime?.invalidate() })
        adapter.service = service; adapter.registrations = registrations
        return adapter
    }

    func invalidate() {
        publicationAuthority.invalidate(); lifetime.invalidate(); execution.invalidate()
        for registration in registrations { service?.removeEmbeddingInvalidator(registration) }
        registrations.removeAll()
    }
    func execute(query: String) async throws -> CompletedSemanticQuery {
        try await execution.execute(query: query, queryID: queryID, context: context)
    }

    private static func makeContext(lease: VaultSessionLease, generation: EmbeddingIndexGeneration,
                                    accessGate: VaultAccessGate, queryID: UUID, lifetime: SemanticQueryLifetime,
                                    validateCurrentAuthority: @escaping @Sendable () throws -> Void
    ) throws -> EmbeddingExecutionContext {
        guard generation.vaultID == lease.vaultID, generation.chunkingVersion == EmbeddingChunker.version else {
            throw EmbeddingContractError.incompatibleGeneration
        }
        let scope = EmbeddingProcessingScope.query(vaultID: lease.vaultID, queryID: queryID)
        let context = try EmbeddingExecutionContext(lease: lease, scope: scope, model: generation.model) {
            try lifetime.validate()
            try accessGate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID,
                                   operation: "semantic.query")
            try validateCurrentAuthority()
        }
        try context.validate(scope: scope, model: generation.model)
        return context
    }
}

/// No content or actor-isolated state is captured by the provider's synchronous validator.
private final class SemanticQueryLifetime: Sendable {
    private let valid = Mutex(true)
    func invalidate() { valid.withLock { $0 = false } }
    func validate() throws {
        try Task.checkCancellation()
        guard valid.withLock({ $0 }) else { throw CancellationError() }
    }
}
