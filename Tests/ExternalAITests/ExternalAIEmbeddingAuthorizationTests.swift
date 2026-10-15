import Foundation
import Synchronization
import Testing
@testable import ExternalAI
import VaultCore

private struct EmbeddingAuthenticator: ExternalAIAuthenticating { func authenticate() async throws {} }
private final class EmbeddingKeychain: ExternalAIKeychain, Sendable {
    let value = Mutex<Data?>(nil)
    func read() throws -> Data? { value.withLock { $0 } }
    func write(_ data: Data) throws { value.withLock { $0 = data } }
    func delete() throws { value.withLock { $0 = nil } }
}
private struct EmbeddingAuthorityFixture {
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/embedding-security"), generation: 1)
    let gate: VaultAccessGate
    let broker: ExternalAICredentialBroker
    let sessions: ExternalAISessionManager
    let authorizer: ExternalAIEmbeddingAuthorizer
    init() async throws {
        gate = VaultAccessGate(initialState: .open(session))
        broker = ExternalAICredentialBroker(keychain: EmbeddingKeychain())
        try await broker.store("synthetic-embedding-test-credential")
        sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: EmbeddingAuthenticator(), observeSystemEvents: false)
        authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: broker, sessionManager: sessions, accessGate: gate)
    }
    func request(scope: EmbeddingProcessingScope? = nil, id: UUID = UUID(), text: String = "private document") throws -> ExternalAIEmbeddingRequest {
        let entity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page,
            entityID: UUID(), revision: "revision-one")
        return try ExternalAIEmbeddingRequest(id: id, inputs: [text], scope: scope ?? .document(entity),
            model: authorizer.descriptor, authority: ExternalAIVaultAuthority(session: session))
    }
    func context(_ request: ExternalAIEmbeddingRequest) throws -> EmbeddingExecutionContext {
        try EmbeddingExecutionContext(lease: session.lease, scope: request.scope,
            model: authorizer.descriptor, validateCurrentAuthority: {})
    }
}

@Test func embeddingAuthorityRejectsInputAndScopeSubstitutionAndReplay() async throws {
    let f = try await EmbeddingAuthorityFixture()
    let request = try f.request()
    let consent = try ExternalAIEmbeddingConsent(approvingDocument: request)
    let altered = try ExternalAIEmbeddingRequest(id: request.id, inputs: ["substitution"], scope: request.scope,
        model: request.model, authority: request.authority)
    await #expect(throws: ExternalAIError.consentRequired) {
        try await f.authorizer.authorize(altered, consent: consent, context: f.context(altered))
    }
    let token = try await f.authorizer.authorize(request, consent: consent, context: f.context(request))
    try f.authorizer.validateSynchronously(token, request: request)
    #expect(throws: ExternalAIError.authorizationRevoked) { try f.authorizer.validateSynchronously(token, request: altered) }
    try await f.authorizer.consume(token, request: request)
    await #expect(throws: ExternalAIError.consentAlreadyUsed) { try await f.authorizer.consume(token, request: request) }
    await #expect(throws: ExternalAIError.consentAlreadyUsed) {
        try await f.authorizer.authorize(request, consent: consent, context: f.context(request))
    }
}

@Test func embeddingAuthorityScopesRequireDistinctExplicitConsent() async throws {
    let f = try await EmbeddingAuthorityFixture()
    let query = try f.request(scope: .query(vaultID: f.session.vaultID, queryID: UUID()))
    #expect(throws: ExternalAIError.consentRequired) { try ExternalAIEmbeddingConsent(approvingDocument: query) }
    let token = try await f.authorizer.authorize(query, consent: ExternalAIEmbeddingConsent(approvingQuery: query), context: f.context(query))
    try f.authorizer.validateSynchronously(token, request: query)
    let entity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .source, entityID: UUID(), revision: "r")
    let batch = UUID()
    let history = try f.request(scope: .historicalBackfill(jobID: batch, entity: entity))
    #expect(throws: ExternalAIError.consentRequired) { try ExternalAIEmbeddingConsent(approvingQuery: history) }
    #expect(throws: ExternalAIError.consentRequired) { try ExternalAIEmbeddingConsent(approvingHistoricalBatch: history, batchID: UUID()) }
    _ = try await f.authorizer.authorize(history, consent: ExternalAIEmbeddingConsent(approvingHistoricalBatch: history, batchID: batch), context: f.context(history))
}

@Test func embeddingAuthorityRejectsForeignIssuerEpochAndSessionRevocation() async throws {
    let f = try await EmbeddingAuthorityFixture()
    let request = try f.request()
    let token = try await f.authorizer.authorize(request, consent: ExternalAIEmbeddingConsent(approvingDocument: request), context: f.context(request))
    let foreign = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions, accessGate: f.gate)
    #expect(throws: ExternalAIError.authorizationRevoked) { try foreign.validateSynchronously(token, request: request) }
    f.authorizer.invalidate()
    #expect(throws: ExternalAIError.authorizationRevoked) { try f.authorizer.validateSynchronously(token, request: request) }
    let afterInvalidation = try f.request()
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await f.authorizer.authorize(afterInvalidation,
            consent: ExternalAIEmbeddingConsent(approvingDocument: afterInvalidation), context: f.context(afterInvalidation))
    }
    let second = try f.request()
    let secondToken = try await foreign.authorize(second, consent: ExternalAIEmbeddingConsent(approvingDocument: second), context: f.context(second))
    f.sessions.revoke()
    #expect(throws: ExternalAIError.authorizationRevoked) { try foreign.validateSynchronously(secondToken, request: second) }
}

@Test func embeddingAuthorityRejectsCredentialReplacementAndCallerContext() async throws {
    let f = try await EmbeddingAuthorityFixture()
    let request = try f.request()
    let token = try await f.authorizer.authorize(request, consent: ExternalAIEmbeddingConsent(approvingDocument: request), context: f.context(request))
    try await f.broker.replace("synthetic-replacement-embedding-key")
    #expect(throws: ExternalAIError.authorizationRevoked) { try f.authorizer.validateSynchronously(token, request: request) }
    f.gate.updateState(.locking(f.session))
    await #expect(throws: (any Error).self) {
        try await f.authorizer.authorize(request, consent: ExternalAIEmbeddingConsent(approvingDocument: request), context: f.context(request))
    }
}

@Test func embeddingCredentialEndpointIsSeparateAndStrict() throws {
    let credential = ExternalAICredential(bytes: Data("synthetic-test-key".utf8))
    for url in ["http://api.openai.com/v1/embeddings", "https://evil.example/v1/embeddings",
                "https://api.openai.com/v1/responses", "https://api.openai.com/v1/embeddings?x=1",
                "https://api.openai.com/v1/embeddings#fragment", "https://name@api.openai.com/v1/embeddings",
                "https://api.openai.com:444/v1/embeddings"] {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = "POST"
        #expect(throws: ExternalAIError.invalidConfiguration) { try credential.authorizeEmbedding(&request) }
    }
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/embeddings")!)
    request.httpMethod = "GET"
    #expect(throws: ExternalAIError.invalidConfiguration) { try credential.authorizeEmbedding(&request) }
    request.httpMethod = "POST"
    #expect(throws: ExternalAIError.invalidConfiguration) { try credential.authorize(&request) }
    try credential.authorizeEmbedding(&request)
    #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
}

@Test func embeddingAuthorityBindsFullModelEntityRevisionAndHistoricalBatch() async throws {
    let f = try await EmbeddingAuthorityFixture()
    let entity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .page, entityID: UUID(), revision: "r1")
    let request = try f.request(scope: .historicalBackfill(jobID: UUID(), entity: entity))
    guard case .historicalBackfill(let batchID, _) = request.scope else { return }
    let consent = try ExternalAIEmbeddingConsent(approvingHistoricalBatch: request, batchID: batchID)
    let token = try await f.authorizer.authorize(request, consent: consent, context: f.context(request))
    let revision = try EmbeddingEntityIdentity(vaultID: entity.vaultID, entityKind: entity.entityKind,
        entityID: entity.entityID, revision: "r2")
    for scope in [EmbeddingProcessingScope.historicalBackfill(jobID: UUID(), entity: entity),
                  .historicalBackfill(jobID: batchID, entity: revision), .document(entity)] {
        let changed = try ExternalAIEmbeddingRequest(id: request.id, inputs: request.inputs, scope: scope,
            model: request.model, authority: request.authority)
        #expect(throws: ExternalAIError.authorizationRevoked) { try f.authorizer.validateSynchronously(token, request: changed) }
    }
    let original = request.model
    let revisionModel = try EmbeddingModelDescriptor(providerID: original.providerID, modelID: original.modelID,
        revision: "different-revision", dimensions: original.dimensions,
        maximumInputUTF8Bytes: original.maximumInputUTF8Bytes, maximumBatchSize: original.maximumBatchSize)
    let changed = try ExternalAIEmbeddingRequest(id: request.id, inputs: request.inputs, scope: request.scope,
        model: revisionModel, authority: request.authority)
    #expect(throws: ExternalAIError.authorizationRevoked) { try f.authorizer.validateSynchronously(token, request: changed) }
}

private actor EmbeddingTransport: OpenAITransporting {
    var requests: [URLRequest] = []
    private var statuses: [Int]
    private let body: Data
    private let before: (@Sendable () -> Void)?
    private let after: (@Sendable () -> Void)?
    init(statuses: [Int] = [200], dimensions: Int = 1_536, before: (@Sendable () -> Void)? = nil,
         after: (@Sendable () -> Void)? = nil) throws {
        self.statuses = statuses; self.before = before; self.after = after
        body = try JSONSerialization.data(withJSONObject: ["object": "list", "model": "text-embedding-3-small",
            "data": [["object": "embedding", "index": 0, "embedding": Array(repeating: 0.01, count: dimensions)]],
            "usage": ["prompt_tokens": 3, "total_tokens": 3]])
    }
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void,
                 didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        before?()
        let dispatched = Mutex(false)
        try beforeDispatch { dispatched.withLock { $0 = true } }
        guard dispatched.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        didDispatch(); requests.append(request)
        after?()
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        return OpenAIHTTPResponse(statusCode: status, body: body)
    }
}

@Test func embeddingProviderSendsOnlyApprovedInputsAndReportsNumericUsage() async throws {
    let f = try await EmbeddingAuthorityFixture(), transport = try EmbeddingTransport()
    let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions,
        accessGate: f.gate, transport: transport)
    let request = try f.request(), context = try f.context(request)
    let token = try await authorizer.authorize(request, consent: ExternalAIEmbeddingConsent(approvingDocument: request), context: context)
    let provider = OpenAIEmbeddingProvider(authorizer: authorizer, authorization: token)
    #expect(throws: ExternalAIError.authorizationRevoked) { try provider.validatePublication() }
    let result = try await provider.embedWithUsage(request.inputs, scope: request.scope, context: context)
    #expect(result.vectors.count == 1 && result.vectors[0].values.count == 1_536)
    #expect(result.usage?.inputTokens == 3 && result.requestCount == 1)
    let sent = try #require(await transport.requests.first)
    #expect(sent.url?.absoluteString == "https://api.openai.com/v1/embeddings")
    let body = try #require(sent.httpBody)
    let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(fields.keys) == ["model", "input", "dimensions", "encoding_format"])
    #expect(fields["input"] as? [String] == request.inputs)
    #expect(!String(decoding: body, as: UTF8.self).contains(f.session.vaultID.uuidString))
    try provider.validatePublication()
    authorizer.invalidate()
    #expect(throws: ExternalAIError.authorizationRevoked) { try provider.validatePublication() }
}

@Test func embeddingProviderRejectsInputSubstitutionBeforeDispatch() async throws {
    let f = try await EmbeddingAuthorityFixture(), transport = try EmbeddingTransport()
    let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions, accessGate: f.gate, transport: transport)
    let request = try f.request(), context = try f.context(request)
    let token = try await authorizer.authorize(request, consent: ExternalAIEmbeddingConsent(approvingDocument: request), context: context)
    let provider = OpenAIEmbeddingProvider(authorizer: authorizer, authorization: token)
    await #expect(throws: ExternalAIError.authorizationRevoked) { try await provider.embed(["substitution"], scope: request.scope, context: context) }
    #expect(await transport.requests.isEmpty)
}

@Test func embeddingProviderRevocationAtDispatchAndAfterResponseFailsClosed() async throws {
    for revokeBefore in [true, false] {
        let f = try await EmbeddingAuthorityFixture()
        let revoke: @Sendable () -> Void = { f.sessions.revoke() }
        let transport = try EmbeddingTransport(before: revokeBefore ? revoke : nil, after: revokeBefore ? nil : revoke)
        let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions, accessGate: f.gate, transport: transport)
        let request = try f.request(), context = try f.context(request)
        let token = try await authorizer.authorize(request, consent: ExternalAIEmbeddingConsent(approvingDocument: request), context: context)
        let provider = OpenAIEmbeddingProvider(authorizer: authorizer, authorization: token)
        await #expect(throws: (any Error).self) { try await provider.embed(request.inputs, scope: request.scope, context: context) }
        #expect(await transport.requests.count == (revokeBefore ? 0 : 1))
    }
}

@Test func embeddingProviderBoundedRetryAndInvalidDimensions() async throws {
    for invalid in [false, true] {
        let f = try await EmbeddingAuthorityFixture()
        let transport = try EmbeddingTransport(statuses: invalid ? [200] : [503, 200], dimensions: invalid ? 2 : 1_536)
        let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions, accessGate: f.gate, transport: transport)
        let request = try f.request(), context = try f.context(request)
        let token = try await authorizer.authorize(request, consent: ExternalAIEmbeddingConsent(approvingDocument: request), context: context)
        let provider = OpenAIEmbeddingProvider(authorizer: authorizer, authorization: token)
        if invalid {
            await #expect(throws: ExternalAIError.invalidResponse) { try await provider.embed(request.inputs, scope: request.scope, context: context) }
            #expect(await transport.requests.count == 1)
        } else {
            let result = try await provider.embedWithUsage(request.inputs, scope: request.scope, context: context)
            #expect(result.requestCount == 2)
            #expect(await transport.requests.count == 2)
        }
    }
}

@Test func embeddingProviderPersistsCommonVectorsAndRevocationPreservesPreviousRevision() async throws {
    let f = try await EmbeddingAuthorityFixture(), transport = try EmbeddingTransport()
    let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions,
        accessGate: f.gate, transport: transport)
    let request = try f.request(), context = try f.context(request)
    let token = try await authorizer.authorize(request, consent: ExternalAIEmbeddingConsent(approvingDocument: request), context: context)
    let provider = OpenAIEmbeddingProvider(authorizer: authorizer, authorization: token)
    let vectors = try await provider.embed(request.inputs, scope: request.scope, context: context)
    let vector = try #require(vectors.first)
    guard case .document(let entity) = request.scope else { Issue.record("Expected document scope"); return }
    let generation = try EmbeddingIndexGeneration(vaultID: f.session.vaultID, model: provider.descriptor, chunkingVersion: "cloud-test-v1")
    let chunk = try EmbeddingChunk(identity: entity, chunkID: "block/one", ordinal: 0,
        contentFingerprint: "cloud-test-input-fingerprint", chunkingVersion: generation.chunkingVersion)
    let record = try EmbeddingRecord(generation: generation, chunk: chunk, vector: vector)
    let support = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/sem-emb-extended/cloud-index/\(UUID())")
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: f.session.lease, accessGate: f.gate)
    try await index.replaceDocument(identity: entity, generation: generation, records: [record], validatePublication: { try provider.validatePublication() })
    #expect(try await index.records(generation: generation) == [record])
    authorizer.invalidate()
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await index.replaceDocument(identity: entity, generation: generation, records: [], validatePublication: { try provider.validatePublication() })
    }
    #expect(try await index.records(generation: generation) == [record])
}
