import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore
@testable import noema

private final class EmbeddingActivityAppKeychain: ExternalAIKeychain, Sendable {
    private let data = Mutex<Data?>(nil)
    func read() throws -> Data? { data.withLock { $0 } }
    func write(_ value: Data) throws { data.withLock { $0 = value } }
    func delete() throws { data.withLock { $0 = nil } }
}
private final class EmbeddingActivityAppAuthenticator: ExternalAIAuthenticating, Sendable {
    let calls = Mutex(0)
    func authenticate() async throws { calls.withLock { $0 += 1 } }
}
private actor EmbeddingActivityAppTransport: OpenAITransporting {
    private(set) var calls = 0
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void,
                 didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        try beforeDispatch { didDispatch() }
        calls += 1
        return OpenAIHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
            "object": "list", "model": "text-embedding-3-small",
            "data": [["object": "embedding", "index": 0, "embedding": Array(repeating: 0.1, count: 1536)]],
            "usage": ["prompt_tokens": 2, "total_tokens": 2]
        ]))
    }
}
@MainActor private struct EmbeddingActivityAppFixture {
    let defaults: UserDefaults
    let domain: String
    let service: ExternalAIService
    let recorder: AIActivityRecorder
    let session: VaultSession
    let gate: VaultAccessGate
    let generation: EmbeddingIndexGeneration
    let auth: EmbeddingActivityAppAuthenticator
    let transport: EmbeddingActivityAppTransport
    init() async throws {
        domain = "semantic-query-adapter-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: domain))
        session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/semantic-query-adapter"), generation: 1)
        gate = VaultAccessGate(initialState: .open(session))
        defaults.set(try JSONEncoder().encode(VaultAIConfiguration(enabled: true, provider: .openAI)),
            forKey: VaultAIConfigurationStore.key(for: session.vaultID))
        auth = EmbeddingActivityAppAuthenticator(); transport = EmbeddingActivityAppTransport()
        let broker = ExternalAICredentialBroker(keychain: EmbeddingActivityAppKeychain())
        try await broker.store("synthetic-semantic-query-adapter-key")
        let sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: auth, observeSystemEvents: false)
        let grants = ExternalAIVaultGrants(keychain: EmbeddingActivityAppKeychain(), credentialBroker: broker,
            accessGate: gate, revocationDefaults: defaults, authenticator: auth)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/embedding-activity/app-fixtures/\(UUID())/activity.sqlite")
        recorder = AIActivityRecorder(store: try SQLiteAIActivityStore(url: root))
        service = ExternalAIService(accessGate: gate, defaults: defaults, activityRecorder: recorder,
            credentialBroker: broker, vaultGrants: grants, sessionManager: sessions,
            gateway: ExternalAIGateway(credentialBroker: broker, sessionManager: sessions, accessGate: gate))
        let gate = gate, transport = transport
        service.embeddingAuthorizerFactory = { _, configuration in
            ExternalAIEmbeddingAuthorizer(credentialBroker: broker, sessionManager: sessions, accessGate: gate,
                configuration: configuration, transport: transport, allowsAuthentication: false)
        }
        generation = try EmbeddingIndexGeneration(vaultID: session.vaultID,
            model: OpenAIEmbeddingConfiguration.default.embeddingDescriptor, chunkingVersion: EmbeddingChunker.version)
    }
}


@Test @MainActor func embeddingActivityApplicationFactoryRecordsNumericQueryEvidenceWithoutContent() async throws {
    let f = try await EmbeddingActivityAppFixture()
    defer { f.defaults.removePersistentDomain(forName: f.domain) }
    let adapter = try SemanticQueryExecutionAdapter.cloud(service: f.service, lease: f.session.lease,
        generation: f.generation, accessGate: f.gate, validateCurrentAuthority: {}, approveQuery: { _ in true })
    #expect(try await f.recorder.count() == 0)
    let completed = try await adapter.execute(query: "Private query text must never persist")
    try completed.validatePublication()
    var records = [AIActivityRecord]()
    for _ in 0..<200 {
        records = try await f.recorder.query()
        if records.first?.status == .completed { break }
        await Task.yield()
    }
    let row = try #require(records.first)
    #expect(row.status == .completed)
    #expect(row.action == .embedQuery)
    #expect(row.requestCount == 1)
    #expect(row.providerResponseCount == 1)
    #expect(row.embeddingUsageCoverage == .complete)
    #expect(row.usage?.inputTokens == 2)
    #expect(row.estimatedCostUSD == nil)
    #expect(row.target == nil)
    let exported = try AIActivityPrivacy.export(records)
    let text = try #require(String(data: exported, encoding: .utf8))
    #expect(!text.contains("Private query text"))
    #expect(!text.contains(f.session.vaultID.uuidString))
    #expect(!text.contains("synthetic-semantic-query-adapter-key"))
    #expect(text.contains("providerResponseCount"))
    #expect(text.contains("embeddingUsageCoverage"))
    adapter.invalidate()
}
