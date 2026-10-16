import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore

private struct QueryFixtureAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws {}
}

private final class QueryFixtureKeychain: ExternalAIKeychain, Sendable {
    private let data = Mutex<Data?>(nil)
    func read() throws -> Data? { data.withLock { $0 } }
    func write(_ value: Data) throws { data.withLock { $0 = value } }
    func delete() throws { data.withLock { $0 = nil } }
}

private actor QueryFixtureTransport: OpenAITransporting {
    private(set) var requests: [URLRequest] = []
    private let afterDispatch: (@Sendable () -> Void)?
    private var statusCode: Int
    init(afterDispatch: (@Sendable () -> Void)? = nil, statusCode: Int = 200) {
        self.afterDispatch = afterDispatch; self.statusCode = statusCode
    }
    func setStatus(_ value: Int) { statusCode = value }
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void,
                 didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        let dispatched = Mutex(false)
        try beforeDispatch { dispatched.withLock { $0 = true } }
        guard dispatched.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        didDispatch()
        requests.append(request)
        afterDispatch?()
        let body = try JSONSerialization.data(withJSONObject: ["object": "list", "model": "text-embedding-3-small",
            "data": [["object": "embedding", "index": 0, "embedding": Array(repeating: 0.01, count: 1_536)]],
            "usage": ["prompt_tokens": 7, "total_tokens": 7]])
        return OpenAIHTTPResponse(statusCode: statusCode, body: body)
    }
}

private final class QueryFixtureClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { value.withLock { $0 } }
    func advance() { value.withLock { $0 = $0.addingTimeInterval(3_600) } }
}

private struct SemanticQueryFixture {
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/semantic-query"), generation: 1)
    let gate: VaultAccessGate
    let broker: ExternalAICredentialBroker
    let sessions: ExternalAISessionManager
    let authorizer: ExternalAIEmbeddingAuthorizer
    let publicationAuthority: EmbeddingPublicationAuthority
    let generation: EmbeddingIndexGeneration
    let transport: QueryFixtureTransport
    let clock: QueryFixtureClock

    init(transport: QueryFixtureTransport = QueryFixtureTransport()) async throws {
        self.transport = transport
        let clock = QueryFixtureClock(); self.clock = clock
        gate = VaultAccessGate(initialState: .open(session))
        broker = ExternalAICredentialBroker(keychain: QueryFixtureKeychain())
        try await broker.store("synthetic-semantic-query-key")
        sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: QueryFixtureAuthenticator(), now: { clock.now }, observeSystemEvents: false)
        authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: broker, sessionManager: sessions,
            accessGate: gate, transport: transport)
        generation = try EmbeddingIndexGeneration(vaultID: session.vaultID,
            model: authorizer.descriptor, chunkingVersion: "executor-test-v1")
        publicationAuthority = try EmbeddingPublicationAuthority(accessGate: gate, lease: session.lease,
            generation: generation)
    }

    func entity() throws -> EmbeddingEntityIdentity {
        try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page, entityID: UUID(), revision: "r1")
    }
    func context(_ scope: EmbeddingProcessingScope) throws -> EmbeddingExecutionContext {
        try EmbeddingExecutionContext(lease: session.lease, scope: scope, model: authorizer.descriptor,
            validateCurrentAuthority: {})
    }
    func executor(approve: @escaping EmbeddingRequestExecutor.ApproveRequest) -> EmbeddingRequestExecutor {
        EmbeddingRequestExecutor(authorizer: authorizer, publicationAuthority: publicationAuthority,
            approveRequest: approve)
    }
}


@Test func semanticQueryCloudAcceptsExactInputAndRetainsUsage() async throws {
    let f = try await SemanticQueryFixture(), queryID = UUID()
    let scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: queryID)
    let query = SemanticQueryExecution(cloud: f.executor { try ExternalAIEmbeddingConsent(approvingQuery: $0) })
    let completed = try await query.execute(query: "  precise submitted query  ", queryID: queryID, context: f.context(scope))
    try completed.validatePublication()
    #expect(completed.usage?.inputTokens == 7)
    #expect(completed.requestCount == 1)
    let requests = await f.transport.requests
    #expect(requests.count == 1)
    let body = try #require(requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["input"] as? [String] == ["  precise submitted query  "])
    query.invalidate()
    #expect(throws: CancellationError.self) { try completed.validatePublication() }
}

@Test func semanticQueryDeclinedAndWrongScopeNeverDispatch() async throws {
    for wrongScope in [false, true] {
        let f = try await SemanticQueryFixture(), queryID = UUID()
        let scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: queryID)
        let query = SemanticQueryExecution(cloud: f.executor { request in
            if wrongScope { return try ExternalAIEmbeddingConsent(approvingDocument: request) }
            throw ExternalAIError.consentRequired
        })
        await #expect(throws: ExternalAIError.consentRequired) {
            try await query.execute(query: "private query", queryID: queryID, context: f.context(scope))
        }
        #expect(await f.transport.requests.isEmpty)
    }
}

@Test func semanticQueryRejectsReplayAndMismatchedQueryIdentity() async throws {
    let f = try await SemanticQueryFixture(), queryID = UUID()
    let scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: queryID)
    let query = SemanticQueryExecution(cloud: f.executor { try ExternalAIEmbeddingConsent(approvingQuery: $0) })
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await query.execute(query: "private query", queryID: UUID(), context: f.context(scope))
    }
    _ = try await query.execute(query: "private query", queryID: queryID, context: f.context(scope))
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await query.execute(query: "private query", queryID: queryID, context: f.context(scope))
    }
    #expect(await f.transport.requests.count == 1)
}

@Test func semanticQueryCloudPublicationRejectsCredentialOrLeaseReplacement() async throws {
    for credential in [true, false] {
        let f = try await SemanticQueryFixture(), queryID = UUID()
        let scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: queryID)
        let query = SemanticQueryExecution(cloud: f.executor { try ExternalAIEmbeddingConsent(approvingQuery: $0) })
        let completed = try await query.execute(query: "private query", queryID: queryID, context: f.context(scope))
        if credential { try await f.broker.replace("synthetic-query-replacement-key") }
        else { f.gate.updateState(.locking(f.session)) }
        #expect(throws: (any Error).self) { try completed.validatePublication() }
    }
}

private struct SuspendedQueryProvider: EmbeddingProvider {
    let descriptor: EmbeddingModelDescriptor
    let duringInference: @Sendable () -> Void
    func embed(_ inputs: [String], scope: EmbeddingProcessingScope,
               context: EmbeddingExecutionContext) async throws -> [EmbeddingVector] {
        duringInference()
        await Task.yield()
        return [try EmbeddingVector(values: [1, 0], model: descriptor)]
    }
}

@Test func semanticQueryNativeRejectsStaleInferenceAndModelSubstitution() async throws {
    let model = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "query", revision: "1", dimensions: 2,
        maximumInputUTF8Bytes: 100, maximumBatchSize: 1)
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/semantic-query-native"), generation: 1)
    let valid = Mutex(true), queryID = UUID()
    let scope = EmbeddingProcessingScope.query(vaultID: session.vaultID, queryID: queryID)
    let context = try EmbeddingExecutionContext(lease: session.lease, scope: scope, model: model) {
        guard valid.withLock({ $0 }) else { throw CancellationError() }
    }
    let provider = SuspendedQueryProvider(descriptor: model, duringInference: { valid.withLock { $0 = false } })
    let query = SemanticQueryExecution(native: provider)
    await #expect(throws: CancellationError.self) {
        try await query.execute(query: "native query", queryID: queryID, context: context)
    }
}

@Test func semanticQueryCloudInvalidationDuringApprovalPreventsTransmission() async throws {
    let f = try await SemanticQueryFixture(), queryID = UUID()
    let scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: queryID)
    let executor = f.executor { request in
        f.authorizer.invalidate()
        return try ExternalAIEmbeddingConsent(approvingQuery: request)
    }
    let query = SemanticQueryExecution(cloud: executor)
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await query.execute(query: "query A", queryID: queryID, context: f.context(scope))
    }
    #expect(await f.transport.requests.isEmpty)
}

@Test func semanticQueryNativeRejectsModelMismatchBeforeInference() async throws {
    let model = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "query", revision: "1", dimensions: 2,
        maximumInputUTF8Bytes: 100, maximumBatchSize: 1)
    let other = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "query", revision: "2", dimensions: 2,
        maximumInputUTF8Bytes: 100, maximumBatchSize: 1)
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/semantic-query-model"), generation: 1)
    let called = Mutex(false), queryID = UUID()
    let scope = EmbeddingProcessingScope.query(vaultID: session.vaultID, queryID: queryID)
    let context = try EmbeddingExecutionContext(lease: session.lease, scope: scope, model: other, validateCurrentAuthority: {})
    let query = SemanticQueryExecution(native: SuspendedQueryProvider(descriptor: model,
        duringInference: { called.withLock { $0 = true } }))
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await query.execute(query: "native query", queryID: queryID, context: context)
    }
    #expect(!called.withLock { $0 })
}

@Test func semanticQueryNativeReplacementNeverRevivesOldA() async throws {
    let model = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "query", revision: "1", dimensions: 2,
        maximumInputUTF8Bytes: 100, maximumBatchSize: 1)
    let provider = SuspendedQueryProvider(descriptor: model, duringInference: {})
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/semantic-query-aba"), generation: 1)
    let firstID = UUID(), replacementID = UUID()
    let first = SemanticQueryExecution(native: provider), replacement = SemanticQueryExecution(native: provider)
    let firstScope = EmbeddingProcessingScope.query(vaultID: session.vaultID, queryID: firstID)
    let replacementScope = EmbeddingProcessingScope.query(vaultID: session.vaultID, queryID: replacementID)
    let old = try await first.execute(query: "query A", queryID: firstID, context:
        EmbeddingExecutionContext(lease: session.lease, scope: firstScope, model: model, validateCurrentAuthority: {}))
    first.invalidate()
    let fresh = try await replacement.execute(query: "query A", queryID: replacementID, context:
        EmbeddingExecutionContext(lease: session.lease, scope: replacementScope, model: model, validateCurrentAuthority: {}))
    try fresh.validatePublication()
    #expect(throws: CancellationError.self) { try old.validatePublication() }
}

@Test func semanticQueryTransientFailureRequiresFreshExecutionAndApprovalForRetry() async throws {
    let f = try await SemanticQueryFixture(transport: QueryFixtureTransport(statusCode: 503)), firstID = UUID()
    let firstScope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: firstID)
    let approvals = Mutex(0)
    let approve: EmbeddingRequestExecutor.ApproveRequest = { request in
        approvals.withLock { $0 += 1 }
        return try ExternalAIEmbeddingConsent(approvingQuery: request)
    }
    let first = SemanticQueryExecution(cloud: f.executor(approve: approve))
    await #expect(throws: ExternalAIError.providerUnavailable) {
        try await first.execute(query: "private query", queryID: firstID, context: f.context(firstScope))
    }
    await f.transport.setStatus(200)
    let nextID = UUID(), next = SemanticQueryExecution(cloud: f.executor(approve: approve))
    let nextScope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: nextID)
    _ = try await next.execute(query: "private query", queryID: nextID, context: f.context(nextScope))
    #expect(approvals.withLock { $0 } == 2)
    #expect(await f.transport.requests.count > 1)
}

@Test func semanticQueryCancellationDuringNativeInferenceDiscardsOutput() async throws {
    let model = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "query", revision: "1", dimensions: 2,
        maximumInputUTF8Bytes: 100, maximumBatchSize: 1)
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/semantic-query-cancel"), generation: 1)
    let queryID = UUID(), query = SemanticQueryExecution(native: SuspendedQueryProvider(descriptor: model,
        duringInference: { withUnsafeCurrentTask { $0?.cancel() } }))
    let scope = EmbeddingProcessingScope.query(vaultID: session.vaultID, queryID: queryID)
    let task = Task {
        try await query.execute(query: "private query", queryID: queryID, context:
            EmbeddingExecutionContext(lease: session.lease, scope: scope, model: model, validateCurrentAuthority: {}))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
