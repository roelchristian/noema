import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore

private struct ExecutorAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws {}
}

private final class ExecutorKeychain: ExternalAIKeychain, Sendable {
    private let data = Mutex<Data?>(nil)
    func read() throws -> Data? { data.withLock { $0 } }
    func write(_ value: Data) throws { data.withLock { $0 = value } }
    func delete() throws { data.withLock { $0 = nil } }
}

private actor ExecutorTransport: OpenAITransporting {
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

private final class ExecutorClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { value.withLock { $0 } }
    func advance() { value.withLock { $0 = $0.addingTimeInterval(3_600) } }
}

private struct ExecutorFixture {
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/embedding-executor"), generation: 1)
    let gate: VaultAccessGate
    let broker: ExternalAICredentialBroker
    let sessions: ExternalAISessionManager
    let authorizer: ExternalAIEmbeddingAuthorizer
    let publicationAuthority: EmbeddingPublicationAuthority
    let generation: EmbeddingIndexGeneration
    let transport: ExecutorTransport
    let clock: ExecutorClock

    init(transport: ExecutorTransport = ExecutorTransport()) async throws {
        self.transport = transport
        let clock = ExecutorClock(); self.clock = clock
        gate = VaultAccessGate(initialState: .open(session))
        broker = ExternalAICredentialBroker(keychain: ExecutorKeychain())
        try await broker.store("synthetic-embedding-executor-key")
        sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: ExecutorAuthenticator(), now: { clock.now }, observeSystemEvents: false)
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

@Test func embeddingExecutorMintsFreshExactRequestForEachHistoricalChunk() async throws {
    let f = try await ExecutorFixture()
    let batchID = UUID(), scope = EmbeddingProcessingScope.historicalBackfill(jobID: batchID, entity: try f.entity())
    let approved = Mutex<[ExternalAIEmbeddingRequest]>([])
    let executor = f.executor { request in
        approved.withLock { $0.append(request) }
        return try ExternalAIEmbeddingConsent(approvingHistoricalBatch: request, batchID: batchID)
    }
    let first = try await executor.embedWithEvidence(["first exact chunk"], scope: scope, context: f.context(scope))
    let second = try await executor.embedWithEvidence(["second exact chunk"], scope: scope, context: f.context(scope))
    let requests = approved.withLock { $0 }
    #expect(requests.count == 2)
    #expect(requests[0].id != requests[1].id)
    #expect(requests.map(\.inputs) == [["first exact chunk"], ["second exact chunk"]])
    #expect(requests.allSatisfy { $0.scope == scope && $0.model == executor.descriptor && $0.authority == ExternalAIVaultAuthority(session: f.session) })
    #expect(await f.transport.requests.count == 2)
    #expect(first.result.usage?.inputTokens == 7 && second.result.requestCount == 1)
    try first.validatePublication()
    try second.validatePublication()
    executor.invalidate()
    #expect(throws: ExternalAIError.authorizationRevoked) { try first.validatePublication() }
    #expect(throws: ExternalAIError.authorizationRevoked) { try second.validatePublication() }
}

@Test func embeddingExecutorContextWithoutEmbeddingConsentNeverDispatches() async throws {
    let f = try await ExecutorFixture(), scope = EmbeddingProcessingScope.document(try f.entity())
    let executor = f.executor { _ in throw ExternalAIError.consentRequired }
    await #expect(throws: ExternalAIError.consentRequired) {
        try await executor.embedWithEvidence(["private input"], scope: scope, context: f.context(scope))
    }
    #expect(await f.transport.requests.isEmpty)
}

@Test func embeddingExecutorRejectsWrongScopeConsentAndOversizedBatch() async throws {
    let f = try await ExecutorFixture(), scope = EmbeddingProcessingScope.document(try f.entity())
    let executor = f.executor { request in try ExternalAIEmbeddingConsent(approvingQuery: request) }
    await #expect(throws: ExternalAIError.consentRequired) {
        try await executor.embedWithEvidence(["private input"], scope: scope, context: f.context(scope))
    }
    await #expect(throws: ExternalAIError.payloadTooLarge) {
        try await executor.embedWithEvidence(["one", "two"], scope: scope, context: f.context(scope))
    }
    #expect(await f.transport.requests.isEmpty)
}

@Test func embeddingExecutorRevocationWhileAwaitingApprovalPreventsDispatch() async throws {
    let f = try await ExecutorFixture(), scope = EmbeddingProcessingScope.document(try f.entity())
    let executor = f.executor { request in
        f.authorizer.invalidate()
        return try ExternalAIEmbeddingConsent(approvingDocument: request)
    }
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await executor.embedWithEvidence(["private input"], scope: scope, context: f.context(scope))
    }
    #expect(await f.transport.requests.isEmpty)
}

@Test func embeddingExecutorCredentialReplacementDuringApprovalPreventsDispatch() async throws {
    let f = try await ExecutorFixture(), scope = EmbeddingProcessingScope.document(try f.entity())
    let executor = f.executor { request in
        // Production composition invalidates before changing the credential. A pending
        // approval cannot revive that retired adapter even if authentication succeeds.
        f.authorizer.invalidate()
        try await f.broker.replace("synthetic-replacement-executor-key")
        return try ExternalAIEmbeddingConsent(approvingDocument: request)
    }
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await executor.embedWithEvidence(["private input"], scope: scope, context: f.context(scope))
    }
    #expect(await f.transport.requests.isEmpty)
}

@Test func embeddingExecutorCompletedEvidenceRejectsCredentialAndLeaseChanges() async throws {
    for changeCredential in [false, true] {
        let f = try await ExecutorFixture(), scope = EmbeddingProcessingScope.document(try f.entity())
        let executor = f.executor { try ExternalAIEmbeddingConsent(approvingDocument: $0) }
        let evidence = try await executor.embedWithEvidence(["private input"], scope: scope, context: f.context(scope))
        try evidence.validatePublication()
        if changeCredential { try await f.broker.replace("synthetic-replaced-key") }
        else { f.gate.updateState(.locking(f.session)) }
        #expect(throws: (any Error).self) { try evidence.validatePublication() }
    }
}


private enum ExecutorBoundaryRevocation: CaseIterable, Sendable {
    case issuer, nativeSession, credential, expiry
}

private func executorReachedBoundary(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}

@Test(.serialized, arguments: ExecutorBoundaryRevocation.allCases)
private func embeddingExecutorRevocationAfterFinalValidationRejectsSemanticCommit(_ revocation: ExecutorBoundaryRevocation) async throws {
    let f = try await ExecutorFixture()
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/sem-emb-04-06-continuation/executor-boundary/\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"),
        vaultID: f.session.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
        schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
    let snapshot = try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("committed")])]),
        pageID: UUID(), condition: .createOnly)
    let identity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .page,
        entityID: snapshot.pageID, revision: snapshot.revision.token.base64EncodedString())
    let scope = EmbeddingProcessingScope.document(identity)
    let executor = f.executor { try ExternalAIEmbeddingConsent(approvingDocument: $0) }
    let completed = try await executor.embedWithEvidence(["committed"], scope: scope, context: f.context(scope))
    let generation = f.generation
    let chunk = try EmbeddingChunk(identity: identity, chunkID: "block/one", ordinal: 0,
        contentFingerprint: "exact-input", chunkingVersion: generation.chunkingVersion)
    let record = try EmbeddingRecord(generation: generation, chunk: chunk,
        vector: #require(completed.result.vectors.first))
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"),
        lease: f.session.lease, accessGate: f.gate)
    let initialPermit = try await store.embeddingPublicationPermit(pageID: snapshot.pageID, expected: snapshot.revision)
    try await index.replaceDocument(identity: identity, generation: generation, records: [record],
        permit: initialPermit, authority: executor.publicationAuthority, validatePublication: { try completed.validatePublication() })
    let permit = try await store.embeddingPublicationPermit(pageID: snapshot.pageID, expected: snapshot.revision)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let checks = Mutex(0)
    let publication = Task.detached {
        try await index.replaceDocument(identity: identity, generation: generation, records: [],
            permit: permit, authority: executor.publicationAuthority, validatePublication: {
                try completed.validatePublication()
                let finalCheck = checks.withLock { count in count += 1; return count == 2 }
                if finalCheck {
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else { throw ExternalAIError.timedOut }
                    // Deliberately no additional request validation: the registered storage
                    // barrier must independently reject revocation after this last check.
                }
            })
    }
    #expect(await executorReachedBoundary(entered))
    switch revocation {
    case .issuer: f.authorizer.invalidate()
    case .nativeSession: f.sessions.revoke()
    case .credential: try await f.broker.replace("synthetic-final-boundary-replacement")
    case .expiry:
        f.clock.advance()
        #expect(await f.sessions.state == .expired)
    }
    release.signal()
    await #expect(throws: (any Error).self) { try await publication.value }
    #expect(try await index.records(generation: generation) == [record])
    try await store.close()
}

@Test func embeddingProcessingAdapterPreservesTransientProviderFailureAfterBoundedRetry() async throws {
    let transport = ExecutorTransport(statusCode: 503)
    let f = try await ExecutorFixture(transport: transport)
    let scope = EmbeddingProcessingScope.document(try f.entity())
    let executor = f.executor { try ExternalAIEmbeddingConsent(approvingDocument: $0) }
    await #expect(throws: AIWorkFailure.transient) {
        try await executor.embedForProcessing(["committed original paragraph"], scope: scope, context: f.context(scope))
    }
    // The provider's bounded exact-request retry stays inside one capability. The scheduler
    // receives a transient failure rather than a permanent malformed-result diagnosis.
    #expect(await transport.requests.count == 2)
    #expect(!Task.isCancelled)
}

@Test func embeddingProcessingAdapterBlocksExpiredAuthorityAndPreservesPublicationValidation() async throws {
    let f = try await ExecutorFixture()
    let scope = EmbeddingProcessingScope.document(try f.entity())
    let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions,
        accessGate: f.gate, transport: f.transport, allowsAuthentication: false)
    let executor = EmbeddingRequestExecutor(authorizer: authorizer, publicationAuthority: f.publicationAuthority,
        approveRequest: { try ExternalAIEmbeddingConsent(approvingDocument: $0) })
    _ = try await f.sessions.authorize(ExternalAIVaultAuthority(session: f.session))
    f.clock.advance()
    await #expect(throws: AIWorkFailure.authority) {
        try await executor.embedForProcessing(["committed original paragraph"], scope: scope, context: f.context(scope))
    }
    #expect(await f.transport.requests.isEmpty)
    // Explicit fresh authorization permits a new exact request; background dispatch never
    // renews authority itself. Completed evidence still rejects expiry before publication.
    _ = try await f.sessions.authorize(ExternalAIVaultAuthority(session: f.session))
    let completed = try await executor.embedForProcessing(["committed original paragraph"], scope: scope,
        context: f.context(scope))
    try completed.validatePublication()
    f.clock.advance()
    #expect(throws: AIWorkFailure.authority) { try completed.validatePublication() }
    #expect(await f.transport.requests.count == 1)
}

@Test func embeddingProcessingAdapterKeepsRefusedConsentBlockedWithoutDispatch() async throws {
    let f = try await ExecutorFixture()
    let scope = EmbeddingProcessingScope.document(try f.entity())
    let executor = f.executor { _ in throw ExternalAIError.consentRequired }
    await #expect(throws: AIWorkFailure.consent) {
        try await executor.embedForProcessing(["committed original paragraph"], scope: scope, context: f.context(scope))
    }
    #expect(await f.transport.requests.isEmpty)
}

@Test func embeddingProcessingAdapterAllowsExplicitCredentialRecoveryAfterProviderRejection() async throws {
    let transport = ExecutorTransport(statusCode: 401)
    let f = try await ExecutorFixture(transport: transport)
    let scope = EmbeddingProcessingScope.document(try f.entity())
    let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: f.broker, sessionManager: f.sessions,
        accessGate: f.gate, transport: transport, allowsAuthentication: false)
    let executor = EmbeddingRequestExecutor(authorizer: authorizer, publicationAuthority: f.publicationAuthority,
        approveRequest: { try ExternalAIEmbeddingConsent(approvingDocument: $0) })
    _ = try await f.sessions.authorize(ExternalAIVaultAuthority(session: f.session))
    await #expect(throws: AIWorkFailure.authority) {
        try await executor.embedForProcessing(["committed original paragraph"], scope: scope, context: f.context(scope))
    }
    #expect(await transport.requests.count == 1) // Settings failures never retry automatically.
    try await f.broker.store("synthetic-replacement-embedding-key")
    await transport.setStatus(200)
    await #expect(throws: AIWorkFailure.authority) {
        try await executor.embedForProcessing(["committed original paragraph"], scope: scope, context: f.context(scope))
    }
    #expect(await transport.requests.count == 1)
    _ = try await f.sessions.authorize(ExternalAIVaultAuthority(session: f.session))
    let completed = try await executor.embedForProcessing(["committed original paragraph"], scope: scope,
        context: f.context(scope))
    try completed.validatePublication()
    #expect(completed.vectors.count == 1)
    #expect(await transport.requests.count == 2)
}
