import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore

private struct ActivityFixtureAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws {}
}

private final class ActivityFixtureKeychain: ExternalAIKeychain, Sendable {
    private let data = Mutex<Data?>(nil)
    func read() throws -> Data? { data.withLock { $0 } }
    func write(_ value: Data) throws { data.withLock { $0 = value } }
    func delete() throws { data.withLock { $0 = nil } }
}

private actor ActivityFixtureTransport: OpenAITransporting {
    private(set) var requests = 0
    private var statuses: [Int]
    private let usageMode: String
    private let failAfterDispatch: Bool
    private var afterResponse: (@Sendable () -> Void)?
    init(statuses: [Int] = [200], usageMode: String = "valid", failAfterDispatch: Bool = false) {
        self.statuses = statuses; self.usageMode = usageMode; self.failAfterDispatch = failAfterDispatch
    }
    func setAfterResponse(_ callback: @escaping @Sendable () -> Void) { afterResponse = callback }
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void,
                 didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        let dispatched = Mutex(false)
        try beforeDispatch { dispatched.withLock { $0 = true } }
        guard dispatched.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        didDispatch(); requests += 1
        if failAfterDispatch { throw ExternalAIError.cancelled }
        let status = statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? 200)
        var body: [String: Any] = ["object": "list", "model": "text-embedding-3-small",
            "data": [["object": "embedding", "index": 0, "embedding": Array(repeating: 0.01, count: 1_536)]]]
        if usageMode == "valid" { body["usage"] = ["prompt_tokens": 7, "total_tokens": 7] }
        if usageMode == "malformed" { body["usage"] = ["prompt_tokens": 7, "total_tokens": 8] }
        let response = OpenAIHTTPResponse(statusCode: status, body: try JSONSerialization.data(withJSONObject: body))
        afterResponse?()
        return response
    }
}

private final class ActivityFixtureClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { value.withLock { $0 } }
    func advance() { value.withLock { $0 = $0.addingTimeInterval(3_600) } }
}

private struct EmbeddingActivityFixture {
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/semantic-query"), generation: 1)
    let gate: VaultAccessGate
    let broker: ExternalAICredentialBroker
    let sessions: ExternalAISessionManager
    let authorizer: ExternalAIEmbeddingAuthorizer
    let publicationAuthority: EmbeddingPublicationAuthority
    let generation: EmbeddingIndexGeneration
    let transport: ActivityFixtureTransport
    let clock: ActivityFixtureClock

    init(transport: ActivityFixtureTransport = ActivityFixtureTransport()) async throws {
        self.transport = transport
        let clock = ActivityFixtureClock(); self.clock = clock
        gate = VaultAccessGate(initialState: .open(session))
        broker = ExternalAICredentialBroker(keychain: ActivityFixtureKeychain())
        try await broker.store("synthetic-semantic-query-key")
        sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: ActivityFixtureAuthenticator(), now: { clock.now }, observeSystemEvents: false)
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
    func executor(recorder: AIActivityRecorder? = nil, approve: @escaping EmbeddingRequestExecutor.ApproveRequest) -> EmbeddingRequestExecutor {
        EmbeddingRequestExecutor(authorizer: authorizer, publicationAuthority: publicationAuthority,
            activityRecorder: recorder, approveRequest: approve)
    }
}



private func embeddingActivityRecorder() throws -> AIActivityRecorder {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/embedding-activity/fixtures/\(UUID())")
    return AIActivityRecorder(store: try SQLiteAIActivityStore(url: root.appendingPathComponent("activity.sqlite")))
}
private func embeddingActivityFinished(_ recorder: AIActivityRecorder) async throws -> AIActivityRecord {
    for _ in 0..<200 {
        let rows = try await recorder.query()
        if let row = rows.first, row.status != .running { return row }
        await Task.yield()
    }
    throw AIActivityStoreError.unavailable
}
private func embeddingActivityConsent(_ request: ExternalAIEmbeddingRequest) throws -> ExternalAIEmbeddingConsent {
    switch request.scope {
    case .query: try ExternalAIEmbeddingConsent(approvingQuery: request)
    case .document: try ExternalAIEmbeddingConsent(approvingDocument: request)
    case .historicalBackfill(let id, _): try ExternalAIEmbeddingConsent(approvingHistoricalBatch: request, batchID: id)
    }
}

@Test func embeddingActivityCategoriesRetainOnlyValidatedNumericEvidence() async throws {
    for category in ["query", "document", "historical"] {
        let f = try await EmbeddingActivityFixture(), recorder = try embeddingActivityRecorder()
        let scope: EmbeddingProcessingScope
        let action: AIActivityAction
        switch category {
        case "query": scope = .query(vaultID: f.session.vaultID, queryID: UUID()); action = .embedQuery
        case "document": scope = .document(try f.entity()); action = .embedDocument
        default: scope = .historicalBackfill(jobID: UUID(), entity: try f.entity()); action = .embedHistoricalBatch
        }
        let executor = f.executor(recorder: recorder, approve: embeddingActivityConsent)
        #expect(try await recorder.count() == 0)
        let completed = try await executor.embedWithEvidence(["private query/document sentinel"], scope: scope, context: f.context(scope))
        try completed.validatePublication()
        let row = try await embeddingActivityFinished(recorder)
        #expect(row.action == action)
        #expect(row.requestCount == 1)
        #expect(row.providerResponseCount == 1)
        #expect(row.embeddingUsageCoverage == .complete)
        #expect(row.usage?.inputTokens == 7)
        #expect(row.estimatedCostUSD == nil)
        #expect(row.outcome == .notApplicable)
        if category == "query" { #expect(row.target == nil) }
        let bytes = try await recorder.exportMetadata()
        let exported = try #require(String(data: bytes, encoding: .utf8))
        #expect(!exported.contains("private query/document sentinel"))
        #expect(!exported.contains("synthetic-semantic-query-key"))
        #expect(!exported.contains("authorization"))
        #expect(!exported.contains("vectors"))
    }
}

@Test(arguments: ["missing", "malformed"]) func embeddingActivityMissingUsageRemainsUnknown(_ usageMode: String) async throws {
    let f = try await EmbeddingActivityFixture(transport: ActivityFixtureTransport(usageMode: usageMode))
    let recorder = try embeddingActivityRecorder(), scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: UUID())
    _ = try await f.executor(recorder: recorder, approve: embeddingActivityConsent)
        .embedWithEvidence(["private query"], scope: scope, context: f.context(scope))
    let row = try await embeddingActivityFinished(recorder)
    #expect(row.providerResponseCount == 1)
    #expect(row.usage == nil)
    #expect(row.embeddingUsageCoverage == .unknown)
    #expect(row.estimatedCostUSD == nil)
}

@Test func embeddingActivityRetryRetainsActualDispatchesAndPartialReportedUsage() async throws {
    let f = try await EmbeddingActivityFixture(transport: ActivityFixtureTransport(statuses: [503, 200]))
    let recorder = try embeddingActivityRecorder(), scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: UUID())
    _ = try await f.executor(recorder: recorder, approve: embeddingActivityConsent)
        .embedWithEvidence(["private query"], scope: scope, context: f.context(scope))
    let row = try await embeddingActivityFinished(recorder)
    #expect(row.requestCount == 2)
    #expect(row.providerResponseCount == 1)
    #expect(row.usage?.inputTokens == 7)
    #expect(row.embeddingUsageCoverage == .partial)
    #expect(row.estimatedCostUSD == nil)
}

@Test func embeddingActivityDeclinedApprovalHasZeroDispatchAndUnknownUsage() async throws {
    let f = try await EmbeddingActivityFixture(), recorder = try embeddingActivityRecorder()
    let scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: UUID())
    let executor = f.executor(recorder: recorder, approve: { _ in throw ExternalAIError.consentRequired })
    await #expect(throws: ExternalAIError.consentRequired) {
        try await executor.embedWithEvidence(["private query"], scope: scope, context: f.context(scope))
    }
    let row = try await embeddingActivityFinished(recorder)
    #expect(row.requestCount == 0)
    #expect(row.providerResponseCount == 0)
    #expect(row.usage == nil)
    #expect(row.embeddingUsageCoverage == .unknown)
    #expect(row.failureCode == .consent)
}

@Test func embeddingActivityCancelledAfterDispatchNeverClaimsZeroProviderUsage() async throws {
    let f = try await EmbeddingActivityFixture(transport: ActivityFixtureTransport(failAfterDispatch: true))
    let recorder = try embeddingActivityRecorder(), scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: UUID())
    await #expect(throws: ExternalAIError.cancelled) {
        try await f.executor(recorder: recorder, approve: embeddingActivityConsent)
            .embedWithEvidence(["private query"], scope: scope, context: f.context(scope))
    }
    let row = try await embeddingActivityFinished(recorder)
    #expect(row.status == .cancelled)
    #expect(row.requestCount == 1)
    #expect(row.providerResponseCount == 0)
    #expect(row.usage == nil)
    #expect(row.embeddingUsageCoverage == .unknown)
    #expect(row.estimatedCostUSD == nil)
}

@Test func embeddingActivityPreservesUsageWhenResponseAuthorityIsRevoked() async throws {
    let f = try await EmbeddingActivityFixture(), recorder = try embeddingActivityRecorder()
    await f.transport.setAfterResponse { f.authorizer.invalidate() }
    let scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: UUID())
    await #expect(throws: (any Error).self) {
        try await f.executor(recorder: recorder, approve: embeddingActivityConsent)
            .embedWithEvidence(["private query"], scope: scope, context: f.context(scope))
    }
    let row = try await embeddingActivityFinished(recorder)
    #expect(row.requestCount == 1)
    #expect(row.providerResponseCount == 1)
    #expect(row.usage?.inputTokens == 7)
    #expect(row.status != .completed)
}

@Test func embeddingActivityRecorderFailureCannotChangeProviderSuccess() async throws {
    let f = try await EmbeddingActivityFixture(), recorder = AIActivityRecorder(store: nil)
    let scope = EmbeddingProcessingScope.query(vaultID: f.session.vaultID, queryID: UUID())
    let completed = try await f.executor(recorder: recorder, approve: embeddingActivityConsent)
        .embedWithEvidence(["private query"], scope: scope, context: f.context(scope))
    try completed.validatePublication()
    #expect(completed.result.usage?.inputTokens == 7)
    #expect(await recorder.recordingUnavailable)
}
