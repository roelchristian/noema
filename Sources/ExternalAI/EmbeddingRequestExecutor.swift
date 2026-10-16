import Foundation
import VaultCore

/// Completed exact-request evidence, retained only for the owning indexing operation.
/// Validate after the final await and before entering the canonical publication barrier.
/// The same publication authority supplied to the executor must span semantic COMMIT.
public final class CompletedEmbeddingRequest: Sendable {
    public let result: OpenAIEmbeddingResult
    private let provider: OpenAIEmbeddingProvider
    private let publicationLifetime: EmbeddingPublicationLifetime

    fileprivate init(result: OpenAIEmbeddingResult, provider: OpenAIEmbeddingProvider,
                     publicationLifetime: EmbeddingPublicationLifetime) {
        self.result = result
        self.provider = provider
        self.publicationLifetime = publicationLifetime
    }

    public func validatePublication() throws { try provider.validatePublication() }
}

/// Embedding-only dispatch adapter. Every call obtains explicit exact-request consent and
/// a fresh one-use capability; a context or a persisted work/batch row is never permission.
/// Approval may suspend for UI, but must fail closed when that scope has no current approval.
/// In particular this adapter never creates historical, document or query consent itself.
public final class EmbeddingRequestExecutor: Sendable {
    public typealias ApproveRequest = @Sendable (ExternalAIEmbeddingRequest) async throws -> ExternalAIEmbeddingConsent

    public let descriptor: EmbeddingModelDescriptor
    private let authorizer: ExternalAIEmbeddingAuthorizer
    public let publicationAuthority: EmbeddingPublicationAuthority
    private let approveRequest: ApproveRequest
    private let activityRecorder: AIActivityRecorder?

    public init(authorizer: ExternalAIEmbeddingAuthorizer,
                publicationAuthority: EmbeddingPublicationAuthority,
                activityRecorder: AIActivityRecorder? = nil,
                approveRequest: @escaping ApproveRequest) {
        self.authorizer = authorizer
        self.publicationAuthority = publicationAuthority
        self.activityRecorder = activityRecorder
        self.approveRequest = approveRequest
        descriptor = authorizer.descriptor
    }

    /// Invoke synchronously before replacing configuration/credentials/consent/session.
    /// Retire the storage barrier first so returning from invalidation also establishes
    /// that any already admitted semantic COMMIT has finished. Never call under that barrier.
    public func invalidate() {
        publicationAuthority.invalidate()
        authorizer.invalidate()
    }

    public func embedWithEvidence(_ inputs: [String], scope: EmbeddingProcessingScope,
                                  context: EmbeddingExecutionContext) async throws -> CompletedEmbeddingRequest {
        try context.validate(scope: scope, model: descriptor)
        let request = try ExternalAIEmbeddingRequest(inputs: inputs, scope: scope, model: descriptor,
            authority: ExternalAIVaultAuthority(lease: context.lease))
        let observation = EmbeddingActivityObservation()
        let action: AIActivityAction
        let target: AIActivityTarget?
        let mode: AIActivityExecutionMode
        switch scope {
        case .query:
            action = .embedQuery; target = nil; mode = .userInvoked
        case .document(let identity):
            action = .embedDocument; target = .init(type: identity.entityKind == .page ? .page : .source, id: identity.entityID)
            mode = .automatic
        case .historicalBackfill(_, let identity):
            action = .embedHistoricalBatch; target = .init(type: identity.entityKind == .page ? .page : .source, id: identity.entityID)
            mode = .userInvoked
        }
        _ = await activityRecorder?.begin(id: request.id, vaultID: scope.vaultID, target: target,
            action: action, executionMode: mode, provider: .openAI, modelID: descriptor.modelID,
            providerResponseCount: 0)
        do {
            try context.validate(scope: scope, model: descriptor)
            let consent = try await approveRequest(request)
            try context.validate(scope: scope, model: descriptor)
            let capability = try await authorizer.authorize(request, consent: consent, context: context)
            let provider = OpenAIEmbeddingProvider(authorizer: authorizer, authorization: capability, activity: observation)
            let result = try await provider.embedWithUsage(inputs, scope: scope, context: context)
            let lifetime = try authorizer.retainPublicationAuthority(for: capability, authority: publicationAuthority)
            let completed = CompletedEmbeddingRequest(result: result, provider: provider, publicationLifetime: lifetime)
            await observation.flush(id: request.id, recorder: activityRecorder)
            try context.validate(scope: scope, model: descriptor)
            try completed.validatePublication()
            // No await after final authority validation. This metadata task captures no
            // provider, credential, context or capability and grants no publication rights.
            let recorder = activityRecorder, id = request.id
            Task { await recorder?.finish(id, status: .completed, outcome: .notApplicable) }
            return completed
        } catch {
            await observation.flush(id: request.id, recorder: activityRecorder)
            let failure = sanitized(error)
            await activityRecorder?.finish(request.id,
                status: failure == .cancelled || failure == .authenticationCancelled || Task.isCancelled ? .cancelled : .failed,
                failureCode: failure.activityFailureCode)
            throw error
        }
    }

    /// Scheduler adapter: retain exact-request evidence while preserving recoverable provider
    /// failures. The raw request API above continues to expose ExternalAI's own error contract.
    public func embedForProcessing(_ inputs: [String], scope: EmbeddingProcessingScope,
                                   context: EmbeddingExecutionContext) async throws -> EmbeddingDispatchResult {
        do {
            let completed = try await embedWithEvidence(inputs, scope: scope, context: context)
            return EmbeddingDispatchResult(vectors: completed.result.vectors, validatePublication: {
                do { try completed.validatePublication() }
                catch { throw Self.processingError(error) }
            })
        } catch { throw Self.processingError(error) }
    }

    private static func processingError(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        guard let failure = error as? ExternalAIError else { return error }
        switch failure {
        case .cancelled, .authenticationCancelled, .staleContent: return CancellationError()
        case .networkUnavailable, .timedOut, .rateLimited, .providerUnavailable: return AIWorkFailure.transient
        case .credentialMissing, .credentialMalformed, .credentialUnavailable, .credentialExpired,
             .authenticationFailed, .authorizationRequired, .authorizationExpired, .authorizationRevoked,
             .vaultUnavailable, .staleSession, .providerRejected: return AIWorkFailure.authority
        case .consentRequired: return AIWorkFailure.consent
        case .unsupportedAction, .emptyContent, .payloadTooLarge: return AIWorkFailure.unsupported
        default: return AIWorkFailure.validation
        }
    }
}
