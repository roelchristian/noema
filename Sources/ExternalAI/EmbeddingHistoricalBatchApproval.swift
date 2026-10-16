import Foundation
import Synchronization
import VaultCore

/// Explicit, session-only approval for exactly one historical batch and scope selection.
/// A persisted batch choice never reconstructs this object. Resume after revocation requires
/// another deliberate approval; obtaining request consent here cannot prompt or authenticate.
/// This object contains no request text and must never be serialized.
public final class EmbeddingHistoricalBatchApproval: Sendable {
    public let batchID: UUID
    public let lease: VaultSessionLease
    public let generation: EmbeddingIndexGeneration
    public let includePages: Bool
    public let includeSources: Bool

    private let sessions: ExternalAISessionManager
    private let capability: ExternalAICapability
    private let publicationAuthority: EmbeddingPublicationAuthority
    private let validateCurrentAuthority: @Sendable () throws -> Void
    private let valid = Mutex(true)
    private let registration = Mutex<UUID?>(nil)

    /// Invoke only following explicit historical-cloud disclosure and native authorization.
    /// `publicationAuthority` must belong to this batch and be shared with its executor and
    /// processor, rather than incremental work or another batch. The service must invalidate
    /// both this approval and its executor before changing provider/model/consent policy.
    public init(approvingBatchID batchID: UUID, lease: VaultSessionLease,
                generation: EmbeddingIndexGeneration, includePages: Bool, includeSources: Bool,
                sessions: ExternalAISessionManager, capability: ExternalAICapability,
                publicationAuthority: EmbeddingPublicationAuthority,
                validateCurrentAuthority: @escaping @Sendable () throws -> Void) throws {
        guard includePages || includeSources, generation.vaultID == lease.vaultID,
              generation.model.providerID == "openai", capability.authority.matches(lease),
              publicationAuthority.matches(lease: lease, generation: generation) else {
            throw ExternalAIError.consentRequired
        }
        self.batchID = batchID; self.lease = lease; self.generation = generation
        self.includePages = includePages; self.includeSources = includeSources
        self.sessions = sessions; self.capability = capability
        self.publicationAuthority = publicationAuthority
        self.validateCurrentAuthority = validateCurrentAuthority
        // Register before final validation, so concurrent revocation cannot be missed.
        let cancellation = try sessions.registerCancellation(for: capability) { [weak self] in
            self?.invalidate()
        }
        registration.withLock { $0 = cancellation }
        do { try validate(lease: lease, generation: generation) }
        catch {
            invalidate()
            sessions.unregisterCancellation(cancellation)
            registration.withLock { $0 = nil }
            throw error
        }
    }

    deinit {
        if let cancellation = registration.withLock({ $0 }) { sessions.unregisterCancellation(cancellation) }
    }

    /// Retire only this batch's short storage barrier. Caller also cancels active work and
    /// invalidates the corresponding request executor; already transmitted bytes remain sent.
    public func invalidate() {
        publicationAuthority.invalidate()
        valid.withLock { $0 = false }
    }

    /// Use in execution-context and final publication validation as well as dispatch.
    /// Validation never renews native-session activity or initiates authentication.
    public func validate(lease: VaultSessionLease, generation: EmbeddingIndexGeneration) throws {
        try Task.checkCancellation()
        guard self.lease == lease, self.generation == generation, valid.withLock({ $0 }) else {
            throw ExternalAIError.consentRequired
        }
        do {
            try sessions.validateSynchronously(capability)
            try validateCurrentAuthority()
        } catch {
            // A failed live-policy check retires this approval permanently; equal-value
            // re-enabling cannot revive authority captured before the observed change.
            invalidate()
            throw error
        }
        guard valid.withLock({ $0 }) else { throw ExternalAIError.consentRequired }
    }

    /// Each call mints fresh exact-input consent. The executor independently obtains and
    /// consumes a fresh one-use request capability; this batch approval is not that capability.
    public func consent(for request: ExternalAIEmbeddingRequest,
                        generation: EmbeddingIndexGeneration) throws -> ExternalAIEmbeddingConsent {
        try validate(lease: lease, generation: generation)
        guard request.authority.matches(lease), request.model == self.generation.model,
              case .historicalBackfill(let requestedBatch, let entity) = request.scope,
              requestedBatch == batchID, entity.vaultID == lease.vaultID,
              (entity.entityKind == .page ? includePages : includeSources) else {
            throw ExternalAIError.consentRequired
        }
        return try ExternalAIEmbeddingConsent(approvingHistoricalBatch: request, batchID: batchID)
    }
}
