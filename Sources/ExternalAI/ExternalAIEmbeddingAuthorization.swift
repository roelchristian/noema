import CryptoKit
import Foundation
import Synchronization
import VaultCore

extension OpenAIEmbeddingConfiguration {
    /// The revision identifies our API/input contract, not a pinned provider weight revision.
    /// OpenAI's model aliases do not expose an immutable weight revision.
    public var embeddingDescriptor: EmbeddingModelDescriptor {
        try! EmbeddingModelDescriptor(providerID: "openai", modelID: modelIdentifier,
            revision: "openai-embeddings-api-v1", dimensions: dimensions,
            maximumInputUTF8Bytes: 8_000, maximumBatchSize: 1)
    }
}

/// Transient exact inputs. Neither this request nor its consent is diagnostic/persistence data.
public struct ExternalAIEmbeddingRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let inputs: [String]
    public let scope: EmbeddingProcessingScope
    public let model: EmbeddingModelDescriptor
    public let authority: ExternalAIVaultAuthority
    fileprivate let digest: Data

    public init(id: UUID = UUID(), inputs: [String], scope: EmbeddingProcessingScope,
                model: EmbeddingModelDescriptor, authority: ExternalAIVaultAuthority) throws {
        guard scope.vaultID == authority.vaultID else { throw ExternalAIError.staleSession }
        guard !inputs.isEmpty, inputs.count <= model.maximumBatchSize,
              inputs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.utf8.count <= model.maximumInputUTF8Bytes }),
              inputs.reduce(0, { $0 + $1.utf8.count }) <= ExternalAILimits.maximumContentBytes else {
            throw ExternalAIError.payloadTooLarge
        }
        self.id = id; self.inputs = inputs; self.scope = scope; self.model = model; self.authority = authority
        digest = Data(SHA256.hash(data: try JSONEncoder().encode(inputs)))
    }

    public var description: String { "ExternalAIEmbeddingRequest(inputs: <redacted>)" }
    public var debugDescription: String { description }
}

/// Three explicit disclosure APIs prevent ordinary summary consent or a document approval
/// from being reused as historical/query permission. UI creates a receipt after confirmation;
/// the authorizer, not this caller-mintable receipt, issues actual transport authority.
public struct ExternalAIEmbeddingConsent: Sendable {
    fileprivate let id = UUID()
    fileprivate let binding: ExternalAIEmbeddingBinding

    public init(approvingDocument request: ExternalAIEmbeddingRequest) throws {
        guard case .document = request.scope else { throw ExternalAIError.consentRequired }
        binding = ExternalAIEmbeddingBinding(request)
    }
    public init(approvingQuery request: ExternalAIEmbeddingRequest) throws {
        guard case .query = request.scope else { throw ExternalAIError.consentRequired }
        binding = ExternalAIEmbeddingBinding(request)
    }
    public init(approvingHistoricalBatch request: ExternalAIEmbeddingRequest, batchID: UUID) throws {
        guard case .historicalBackfill(let expected, _) = request.scope, expected == batchID else {
            throw ExternalAIError.consentRequired
        }
        binding = ExternalAIEmbeddingBinding(request)
    }
}

fileprivate struct ExternalAIEmbeddingBinding: Sendable, Equatable {
    let id: UUID
    let digest: Data
    let scope: EmbeddingProcessingScope
    let model: EmbeddingModelDescriptor
    let authority: ExternalAIVaultAuthority
    init(_ request: ExternalAIEmbeddingRequest) {
        id = request.id; digest = request.digest; scope = request.scope
        model = request.model; authority = request.authority
    }
}

/// Opaque issuer-bound, one-use request capability. There is no public initializer, and
/// caller-created EmbeddingExecutionContext or enrichment grants cannot substitute for it.
public final class ExternalAIEmbeddingAuthorization: Sendable {
    fileprivate let issuer: UUID
    fileprivate let epoch: UUID
    fileprivate let binding: ExternalAIEmbeddingBinding
    fileprivate let capability: ExternalAICapability
    fileprivate let context: EmbeddingExecutionContext
    fileprivate let used = Mutex(false)
    fileprivate let completed = Mutex(false)

    fileprivate init(issuer: UUID, epoch: UUID, request: ExternalAIEmbeddingRequest,
                     capability: ExternalAICapability, context: EmbeddingExecutionContext) {
        self.issuer = issuer; self.epoch = epoch; binding = ExternalAIEmbeddingBinding(request)
        self.capability = capability; self.context = context
    }
}

/// Dedicated embedding authority. Existing enrichment grants are deliberately absent from
/// this API. A fresh exact-input receipt and a live native-authenticated D02A session are required.
public actor ExternalAIEmbeddingAuthorizer {
    public nonisolated let descriptor: EmbeddingModelDescriptor
    private nonisolated let issuer = UUID()
    private struct EpochState: Sendable {
        var id = UUID()
        var valid = true
        var cancellations: [UUID: @Sendable () -> Void] = [:]
    }
    private nonisolated let epoch = Mutex(EpochState())
    private let allowsAuthentication: Bool
    private let sessions: ExternalAISessionManager
    private let broker: ExternalAICredentialBroker
    private let gate: VaultAccessGate
    private let transport: any OpenAITransporting
    private var usedReceipts = Set<UUID>()
    private var usedRequests = Set<UUID>()

    public init(credentialBroker: ExternalAICredentialBroker, sessionManager: ExternalAISessionManager,
                accessGate: VaultAccessGate, configuration: OpenAIEmbeddingConfiguration = .default, allowsAuthentication: Bool = true) {
        self.allowsAuthentication = allowsAuthentication
        broker = credentialBroker; sessions = sessionManager; gate = accessGate
        descriptor = configuration.embeddingDescriptor
        transport = OpenAITransport()
    }

    init(credentialBroker: ExternalAICredentialBroker, sessionManager: ExternalAISessionManager,
         accessGate: VaultAccessGate, configuration: OpenAIEmbeddingConfiguration = .default,
         transport: any OpenAITransporting, allowsAuthentication: Bool = true) {
        self.allowsAuthentication = allowsAuthentication
        broker = credentialBroker; sessions = sessionManager; gate = accessGate
        descriptor = configuration.embeddingDescriptor; self.transport = transport
    }

    /// Invalidate on provider/model preference changes before installing a new authorizer.
    /// Tokens also retain their lease, session credential version and full model descriptor.
    public nonisolated func invalidate() {
        let handlers = epoch.withLock {
            $0.id = UUID()
            $0.valid = false
            let handlers = Array($0.cancellations.values)
            $0.cancellations.removeAll()
            return handlers
        }
        for handler in handlers { handler() }
    }

    public func authorize(_ request: ExternalAIEmbeddingRequest, consent: ExternalAIEmbeddingConsent,
                          context: EmbeddingExecutionContext) async throws -> ExternalAIEmbeddingAuthorization {
        do { return try await issue(request, consent: consent, context: context) }
        catch { throw sanitized(error) }
    }

    private func issue(_ request: ExternalAIEmbeddingRequest, consent: ExternalAIEmbeddingConsent,
                       context: EmbeddingExecutionContext) async throws -> ExternalAIEmbeddingAuthorization {
        try context.validate(scope: request.scope, model: descriptor)
        guard request.model == descriptor, request.authority.matches(context.lease),
              consent.binding == ExternalAIEmbeddingBinding(request) else { throw ExternalAIError.consentRequired }
        guard !usedReceipts.contains(consent.id), !usedRequests.contains(request.id) else {
            throw ExternalAIError.consentAlreadyUsed
        }
        let startedEpoch = try epoch.withLock {
            guard $0.valid else { throw ExternalAIError.authorizationRevoked }
            return $0.id
        }
        let capability = try await sessions.authorize(request.authority, allowAuthentication: allowsAuthentication)
        try await sessions.validate(capability)
        try context.validate(scope: request.scope, model: descriptor)
        guard epoch.withLock({ $0.id }) == startedEpoch else { throw ExternalAIError.authorizationRevoked }
        guard !usedReceipts.contains(consent.id), !usedRequests.contains(request.id) else {
            throw ExternalAIError.consentAlreadyUsed
        }
        // A bounded issuer lifetime fails closed rather than evicting replay protection.
        guard usedRequests.count < 4_096 else { throw ExternalAIError.authorizationRevoked }
        usedReceipts.insert(consent.id); usedRequests.insert(request.id)
        let authorization = ExternalAIEmbeddingAuthorization(issuer: issuer, epoch: startedEpoch,
            request: request, capability: capability, context: context)
        try validateSynchronously(authorization, request: request)
        return authorization
    }

    nonisolated func validateSynchronously(_ authorization: ExternalAIEmbeddingAuthorization,
                                          request: ExternalAIEmbeddingRequest) throws {
        try Task.checkCancellation()
        guard authorization.issuer == issuer, authorization.binding == ExternalAIEmbeddingBinding(request),
              authorization.epoch == epoch.withLock({ $0.id }), request.model == descriptor else {
            throw ExternalAIError.authorizationRevoked
        }
        try authorization.context.validate(scope: request.scope, model: descriptor)
        try gate.validate(lease: authorization.context.lease, targetRoot: authorization.context.lease.root,
                          targetVaultID: request.authority.vaultID, operation: "externalAIEmbedding")
        try sessions.validateSynchronously(authorization.capability)
        try broker.withValidatedCredential(version: authorization.capability.credentialVersion) {}
    }

    func consume(_ authorization: ExternalAIEmbeddingAuthorization, request: ExternalAIEmbeddingRequest) throws {
        try validateSynchronously(authorization, request: request)
        try authorization.used.withLock {
            guard !$0 else { throw ExternalAIError.consentAlreadyUsed }
            $0 = true
        }
    }
}


extension ExternalAIEmbeddingAuthorizer {
    /// Recheck after the final storage actor hop; the index must also validate its live
    /// entity revision, generation and admitted D02 lease inside conditional publication.
    public nonisolated func validatePublication(_ authorization: ExternalAIEmbeddingAuthorization) throws {
        do {
            guard authorization.completed.withLock({ $0 }), authorization.issuer == issuer,
                  authorization.epoch == epoch.withLock({ $0.id }) else { throw ExternalAIError.authorizationRevoked }
            try authorization.context.validate(scope: authorization.binding.scope, model: descriptor)
            let lease = authorization.context.lease
            try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID,
                              operation: "externalAIEmbedding.publication")
            try sessions.validateSynchronously(authorization.capability)
            try broker.withValidatedCredential(version: authorization.capability.credentialVersion) {}
        } catch { throw sanitized(error) }
    }

    func performEmbedding(_ inputs: [String], scope: EmbeddingProcessingScope,
                          context: EmbeddingExecutionContext,
                          authorization: ExternalAIEmbeddingAuthorization) async throws -> OpenAIEmbeddingResult {
        do {
            try context.validate(scope: scope, model: descriptor)
            guard context.lease == authorization.context.lease else { throw ExternalAIError.staleSession }
            let request = try ExternalAIEmbeddingRequest(id: authorization.binding.id, inputs: inputs,
                scope: scope, model: descriptor, authority: ExternalAIVaultAuthority(lease: context.lease))
            try consume(authorization, request: request)
            let capability = authorization.capability
            try await sessions.validate(capability, activity: true)
            try validateSynchronously(authorization, request: request)
            let registration = try gate.admitOperation(operation: "externalAIEmbedding", lease: context.lease,
                targetRoot: context.lease.root, targetVaultID: scope.vaultID, id: request.id)
            defer { registration.complete(disposition: Task.isCancelled ? .cancelled : .completed) }
            let cancellation = EmbeddingRequestCancellation()
            let sessionCancellation = try sessions.registerCancellation(for: capability) { cancellation.cancel() }
            defer { sessions.unregisterCancellation(sessionCancellation) }
            let epochCancellation = UUID()
            try epoch.withLock {
                guard $0.id == authorization.epoch else { throw ExternalAIError.authorizationRevoked }
                $0.cancellations[epochCancellation] = { cancellation.cancel() }
            }
            defer { _ = epoch.withLock { $0.cancellations.removeValue(forKey: epochCancellation) } }
            let body = try JSONEncoder().encode(EmbeddingRequestBody(model: descriptor.modelID,
                input: inputs, dimensions: descriptor.dimensions))
            let sessions = self.sessions, broker = self.broker, gate = self.gate, transport = self.transport
            let worker = Task { [self] in
                var attempt = 0
                while true {
                    try await sessions.validate(capability)
                    try self.validateSynchronously(authorization, request: request)
                    do {
                        let response = try await broker.withCredential(version: capability.credentialVersion) { credential in
                            try self.validateSynchronously(authorization, request: request)
                            var network = URLRequest(url: URL(string: "https://api.openai.com/v1/embeddings")!)
                            network.httpMethod = "POST"; network.httpBody = body
                            network.timeoutInterval = ExternalAILimits.requestTimeout
                            network.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            network.setValue("application/json", forHTTPHeaderField: "Accept")
                            try credential.authorizeEmbedding(&network)
                            return try await transport.perform(network, beforeDispatch: { resume in
                                try context.validate(scope: scope, model: self.descriptor)
                                try gate.withOpenSession(lease: context.lease, operation: "externalAIEmbedding.dispatch") {
                                    try sessions.withValidatedAuthorization(capability) {
                                        try self.epoch.withLock {
                                            guard $0.id == authorization.epoch else { throw ExternalAIError.authorizationRevoked }
                                            try broker.withValidatedCredential(version: capability.credentialVersion, body: resume)
                                        }
                                    }
                                }
                            })
                        }
                        try ExternalAIGateway.checkStatus(response.statusCode)
                        let result = try OpenAIEmbeddingResult.decode(response.body, descriptor: self.descriptor, count: inputs.count,
                            requestCount: attempt + 1)
                        try await sessions.validate(capability)
                        try self.validateSynchronously(authorization, request: request)
                        return result
                    } catch {
                        let failure = sanitized(error)
                        guard attempt < ExternalAILimits.maximumRetryCount,
                              [.networkUnavailable, .timedOut, .rateLimited, .providerUnavailable].contains(failure) else { throw failure }
                        attempt += 1
                        try self.validateSynchronously(authorization, request: request)
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            cancellation.install(worker)
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel() }
            try validateSynchronously(authorization, request: request)
            authorization.completed.withLock { $0 = true }
            return result
        } catch { throw sanitized(error) }
    }
}

private struct EmbeddingRequestBody: Encodable {
    let model: String
    let input: [String]
    let dimensions: Int
    let encoding_format = "float"
}

private final class EmbeddingRequestCancellation: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var task: Task<OpenAIEmbeddingResult, Error>?
    }
    private let state = Mutex(State())
    func install(_ task: Task<OpenAIEmbeddingResult, Error>) {
        state.withLock { if $0.cancelled { task.cancel() } else { $0.task = task } }
    }
    func cancel() { state.withLock { $0.cancelled = true; $0.task?.cancel() } }
}

/// Registration lifetime spans the completed response through conditional storage publication.
/// It contains no durable authority; releasing it only detaches revocation callbacks.
final class EmbeddingPublicationLifetime: Sendable {
    private let unregister: @Sendable () -> Void
    init(unregister: @escaping @Sendable () -> Void) { self.unregister = unregister }
    deinit { unregister() }
}

extension ExternalAIEmbeddingAuthorizer {
    /// Bridge native-session, credential and issuer revocation to the same short storage
    /// barrier used at COMMIT. Registration precedes final live-state validation, so
    /// revocation between response completion and registration cannot escape detection.
    /// Call outside canonical/publication locks; callbacks only retire the storage barrier.
    nonisolated func retainPublicationAuthority(for authorization: ExternalAIEmbeddingAuthorization,
                                                authority: EmbeddingPublicationAuthority) throws -> EmbeddingPublicationLifetime {
        let sessionRegistration: UUID
        do {
            sessionRegistration = try sessions.registerCancellation(for: authorization.capability) {
                authority.invalidate()
            }
        } catch {
            authority.invalidate()
            throw sanitized(error)
        }
        let epochRegistration = UUID()
        do {
            try epoch.withLock {
                guard $0.valid, $0.id == authorization.epoch, authorization.issuer == issuer else {
                    throw ExternalAIError.authorizationRevoked
                }
                $0.cancellations[epochRegistration] = { authority.invalidate() }
            }
            try validatePublication(authorization)
        } catch {
            authority.invalidate()
            sessions.unregisterCancellation(sessionRegistration)
            _ = epoch.withLock { $0.cancellations.removeValue(forKey: epochRegistration) }
            throw sanitized(error)
        }
        return EmbeddingPublicationLifetime { [self] in
            sessions.unregisterCancellation(sessionRegistration)
            _ = epoch.withLock { $0.cancellations.removeValue(forKey: epochRegistration) }
        }
    }
}
