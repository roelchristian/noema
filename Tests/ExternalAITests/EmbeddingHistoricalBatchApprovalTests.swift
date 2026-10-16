import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore

private final class HistoricalApprovalState: Sendable {
    let authenticationCalls = Mutex(0)
    let currentPolicy = Mutex(true)
}

private struct HistoricalAuthenticator: ExternalAIAuthenticating {
    let state: HistoricalApprovalState
    func authenticate() async throws { state.authenticationCalls.withLock { $0 += 1 } }
}

private final class HistoricalKeychain: ExternalAIKeychain, Sendable {
    private let value = Mutex<Data?>(nil)
    func read() throws -> Data? { value.withLock { $0 } }
    func write(_ data: Data) throws { value.withLock { $0 = data } }
    func delete() throws { value.withLock { $0 = nil } }
}

private struct HistoricalApprovalFixture {
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/historical-approval"), generation: 1)
    let gate: VaultAccessGate
    let broker: ExternalAICredentialBroker
    let sessions: ExternalAISessionManager
    let capability: ExternalAICapability
    let generation: EmbeddingIndexGeneration
    let state: HistoricalApprovalState
    let batchID = UUID()

    init() async throws {
        gate = VaultAccessGate(initialState: .open(session))
        broker = ExternalAICredentialBroker(keychain: HistoricalKeychain())
        try await broker.store("synthetic-historical-approval-key")
        let state = HistoricalApprovalState(); self.state = state
        sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: HistoricalAuthenticator(state: state), observeSystemEvents: false)
        capability = try await sessions.authorize(ExternalAIVaultAuthority(session: session))
        generation = try EmbeddingIndexGeneration(vaultID: session.vaultID,
            model: OpenAIEmbeddingConfiguration.default.embeddingDescriptor,
            chunkingVersion: EmbeddingChunker.version)
    }

    func authority() throws -> EmbeddingPublicationAuthority {
        try EmbeddingPublicationAuthority(accessGate: gate, lease: session.lease, generation: generation)
    }

    func approval(pages: Bool = true, sources: Bool = true, batch: UUID? = nil,
                  publicationAuthority: EmbeddingPublicationAuthority? = nil) throws -> EmbeddingHistoricalBatchApproval {
        let state = self.state
        return try EmbeddingHistoricalBatchApproval(approvingBatchID: batch ?? batchID, lease: session.lease,
            generation: generation, includePages: pages, includeSources: sources,
            sessions: sessions, capability: capability, publicationAuthority: publicationAuthority ?? authority(),
            validateCurrentAuthority: {
                guard state.currentPolicy.withLock({ $0 }) else { throw ExternalAIError.authorizationRevoked }
            })
    }

    func request(kind: AIEntityKind = .page, batch: UUID? = nil, text: String = "one exact chunk",
                 scope: EmbeddingProcessingScope? = nil, model: EmbeddingModelDescriptor? = nil,
                 lease: VaultSessionLease? = nil) throws -> ExternalAIEmbeddingRequest {
        let entity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: kind,
            entityID: UUID(), revision: "committed-revision")
        return try ExternalAIEmbeddingRequest(inputs: [text], scope: scope ?? .historicalBackfill(jobID: batch ?? batchID, entity: entity),
            model: model ?? generation.model, authority: ExternalAIVaultAuthority(lease: lease ?? session.lease))
    }
}

@Test func historicalApprovalRequiresExactSelectedPageAndSourceScopes() async throws {
    let f = try await HistoricalApprovalFixture()
    for pages in [false, true] {
        let approval = try f.approval(pages: pages, sources: !pages)
        _ = try approval.consent(for: f.request(kind: pages ? .page : .source), generation: f.generation)
        #expect(throws: ExternalAIError.consentRequired) {
            try approval.consent(for: f.request(kind: pages ? .source : .page), generation: f.generation)
        }
    }
    #expect(throws: ExternalAIError.consentRequired) { try f.approval(pages: false, sources: false) }
}

@Test func historicalApprovalRejectsOtherBatchDocumentAndQueryScopes() async throws {
    let f = try await HistoricalApprovalFixture(), approval = try f.approval()
    let entity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .page,
        entityID: UUID(), revision: "r1")
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.consent(for: f.request(batch: UUID()), generation: f.generation)
    }
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.consent(for: f.request(scope: .document(entity)), generation: f.generation)
    }
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.consent(for: f.request(scope: .query(vaultID: f.session.vaultID, queryID: UUID())), generation: f.generation)
    }
}

@Test func historicalApprovalBindsFullGenerationModelAndPreciseLease() async throws {
    let f = try await HistoricalApprovalFixture(), approval = try f.approval()
    let replacement = try EmbeddingIndexGeneration(vaultID: f.session.vaultID,
        model: f.generation.model, chunkingVersion: f.generation.chunkingVersion)
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.consent(for: f.request(), generation: replacement)
    }
    let old = f.generation.model
    let revised = try EmbeddingModelDescriptor(providerID: old.providerID, modelID: old.modelID,
        revision: "different-api-contract", dimensions: old.dimensions,
        maximumInputUTF8Bytes: old.maximumInputUTF8Bytes, maximumBatchSize: old.maximumBatchSize)
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.consent(for: f.request(model: revised), generation: f.generation)
    }
    let otherSession = VaultSessionLease(vaultID: f.session.vaultID, root: f.session.root, generation: 2)
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.consent(for: f.request(lease: otherSession), generation: f.generation)
    }
    let otherRoot = VaultSessionLease(sessionID: f.session.id, vaultID: f.session.vaultID,
        root: URL(fileURLWithPath: "/tmp/other-historical-root"), generation: f.session.generation)
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.validate(lease: otherRoot, generation: f.generation)
    }
}

@Test func historicalApprovalMintsFreshRequestBoundConsentPerChunk() async throws {
    let f = try await HistoricalApprovalFixture(), approval = try f.approval()
    let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions,
        accessGate: f.gate, allowsAuthentication: false)
    let first = try f.request(text: "first exact chunk"), second = try f.request(text: "second exact chunk")
    let firstConsent = try approval.consent(for: first, generation: f.generation)
    let secondConsent = try approval.consent(for: second, generation: f.generation)
    func context(_ request: ExternalAIEmbeddingRequest) throws -> EmbeddingExecutionContext {
        try EmbeddingExecutionContext(lease: f.session.lease, scope: request.scope, model: f.generation.model,
            validateCurrentAuthority: { try approval.validate(lease: f.session.lease, generation: f.generation) })
    }
    let firstCapability = try await authorizer.authorize(first, consent: firstConsent, context: context(first))
    let secondCapability = try await authorizer.authorize(second, consent: secondConsent, context: context(second))
    #expect(firstCapability !== secondCapability)
    await #expect(throws: ExternalAIError.consentAlreadyUsed) {
        try await authorizer.authorize(first, consent: firstConsent, context: context(first))
    }
    let changed = try ExternalAIEmbeddingRequest(inputs: ["changed input"], scope: second.scope,
        model: second.model, authority: second.authority)
    await #expect(throws: ExternalAIError.consentRequired) {
        try await authorizer.authorize(changed, consent: secondConsent, context: context(changed))
    }
    #expect(f.state.authenticationCalls.withLock({ $0 }) == 1)
}

@Test func historicalApprovalRevocationRequiresExplicitNewApprovalWithoutPrompting() async throws {
    let f = try await HistoricalApprovalFixture(), approval = try f.approval()
    approval.invalidate()
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.consent(for: f.request(), generation: f.generation)
    }
    #expect(f.state.authenticationCalls.withLock({ $0 }) == 1)
    // A different batch's explicit approval in the same live session remains usable.
    let independentID = UUID()
    let independent = try f.approval(batch: independentID)
    _ = try independent.consent(for: f.request(batch: independentID), generation: f.generation)
}

@Test func historicalApprovalNativeSessionAndCredentialRevocationAreSynchronous() async throws {
    for changeCredential in [false, true] {
        let f = try await HistoricalApprovalFixture(), approval = try f.approval()
        if changeCredential { try await f.broker.replace("synthetic-historical-replacement-key") }
        else { f.sessions.revoke() }
        #expect(throws: (any Error).self) {
            try approval.consent(for: f.request(), generation: f.generation)
        }
        #expect(throws: (any Error).self) { try f.approval() }
        #expect(f.state.authenticationCalls.withLock({ $0 }) == 1)
    }
}

@Test func historicalApprovalLivePolicyAndVaultLockCannotBeRestoredByPersistedChoice() async throws {
    let f = try await HistoricalApprovalFixture(), approval = try f.approval()
    f.state.currentPolicy.withLock { $0 = false }
    #expect(throws: ExternalAIError.authorizationRevoked) {
        try approval.consent(for: f.request(), generation: f.generation)
    }
    f.state.currentPolicy.withLock { $0 = true }
    #expect(throws: ExternalAIError.consentRequired) {
        try approval.consent(for: f.request(), generation: f.generation)
    }
    let fresh = try f.approval()
    f.gate.updateState(.locking(f.session))
    #expect(throws: (any Error).self) {
        try fresh.consent(for: f.request(), generation: f.generation)
    }
    #expect(f.state.authenticationCalls.withLock({ $0 }) == 1)
}

@Test func historicalApprovalRejectsPublicationAuthorityForOtherLeaseOrGeneration() async throws {
    let f = try await HistoricalApprovalFixture()
    let otherGeneration = try EmbeddingIndexGeneration(vaultID: f.session.vaultID,
        model: f.generation.model, chunkingVersion: f.generation.chunkingVersion)
    let wrongGenerationAuthority = try EmbeddingPublicationAuthority(accessGate: f.gate,
        lease: f.session.lease, generation: otherGeneration)
    #expect(throws: ExternalAIError.consentRequired) {
        try f.approval(publicationAuthority: wrongGenerationAuthority)
    }
    let otherSession = VaultSession(vaultID: f.session.vaultID,
        root: URL(fileURLWithPath: "/tmp/other-historical-approval-root"), generation: 2)
    let otherGate = VaultAccessGate(initialState: .open(otherSession))
    let wrongLeaseAuthority = try EmbeddingPublicationAuthority(accessGate: otherGate,
        lease: otherSession.lease, generation: f.generation)
    #expect(throws: ExternalAIError.consentRequired) {
        try f.approval(publicationAuthority: wrongLeaseAuthority)
    }
}
