import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore
@testable import noema

private final class QueryAdapterKeychain: ExternalAIKeychain, Sendable {
    private let data = Mutex<Data?>(nil)
    func read() throws -> Data? { data.withLock { $0 } }
    func write(_ value: Data) throws { data.withLock { $0 = value } }
    func delete() throws { data.withLock { $0 = nil } }
}
private final class QueryAdapterAuthenticator: ExternalAIAuthenticating, Sendable {
    let calls = Mutex(0)
    func authenticate() async throws { calls.withLock { $0 += 1 } }
}
private actor QueryAdapterTransport: OpenAITransporting {
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
@MainActor private final class QueryApprovalSuspension {
    private var receipt: CheckedContinuation<Bool, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func approve() async -> Bool {
        await withCheckedContinuation { receipt in
            self.receipt = receipt; observer?.resume(); observer = nil
        }
    }
    func entered() async {
        if receipt != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish() { receipt?.resume(returning: true); receipt = nil }
}
@MainActor private struct QueryAdapterFixture {
    let defaults: UserDefaults
    let domain: String
    let service: ExternalAIService
    let session: VaultSession
    let gate: VaultAccessGate
    let generation: EmbeddingIndexGeneration
    let auth: QueryAdapterAuthenticator
    let transport: QueryAdapterTransport
    init() async throws {
        domain = "semantic-query-adapter-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: domain))
        session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/semantic-query-adapter"), generation: 1)
        gate = VaultAccessGate(initialState: .open(session))
        defaults.set(try JSONEncoder().encode(VaultAIConfiguration(enabled: true, provider: .openAI)),
            forKey: VaultAIConfigurationStore.key(for: session.vaultID))
        auth = QueryAdapterAuthenticator(); transport = QueryAdapterTransport()
        let broker = ExternalAICredentialBroker(keychain: QueryAdapterKeychain())
        try await broker.store("synthetic-semantic-query-adapter-key")
        let sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: auth, observeSystemEvents: false)
        let grants = ExternalAIVaultGrants(keychain: QueryAdapterKeychain(), credentialBroker: broker,
            accessGate: gate, revocationDefaults: defaults, authenticator: auth)
        service = ExternalAIService(accessGate: gate, defaults: defaults, activityRecorder: AIActivityRecorder(store: nil),
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

@Suite("Semantic query application adapter", .serialized)
struct SemanticQueryExecutionAdapterTests {
    @Test @MainActor func semanticQueryAdapterInvalidatedApprovalNeverAuthenticates() async throws {
        let f = try await QueryAdapterFixture(), approval = QueryApprovalSuspension()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let adapter = try SemanticQueryExecutionAdapter.cloud(service: f.service, lease: f.session.lease,
            generation: f.generation, accessGate: f.gate, validateCurrentAuthority: {},
            approveQuery: { _ in await approval.approve() })
        #expect(f.auth.calls.withLock { $0 } == 0)
        #expect(await f.transport.calls == 0)
        let task = Task { try await adapter.execute(query: "private query") }
        await approval.entered()
        adapter.invalidate(); approval.finish()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(f.auth.calls.withLock { $0 } == 0)
        #expect(await f.transport.calls == 0)
    }

    @Test(arguments: ["model", "lease", "credential", "directCredential"]) @MainActor
    func semanticQueryAdapterAuthorityChangesDuringApprovalNeverDispatch(_ change: String) async throws {
        let f = try await QueryAdapterFixture(), approval = QueryApprovalSuspension()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let adapter = try SemanticQueryExecutionAdapter.cloud(service: f.service, lease: f.session.lease,
            generation: f.generation, accessGate: f.gate, validateCurrentAuthority: {},
            approveQuery: { _ in await approval.approve() })
        let task = Task { try await adapter.execute(query: "private query") }
        await approval.entered()
        switch change {
        case "model": try f.service.setEmbeddingModel("text-embedding-3-large")
        case "lease": f.gate.updateState(.locking(f.session))
        case "credential": f.service.invalidateEmbeddingRequests(); try await f.service.credentialBroker.replace("synthetic-replacement-query-key")
        default: try await f.service.credentialBroker.replace("synthetic-direct-replacement-query-key")
        }
        approval.finish()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(f.auth.calls.withLock { $0 } == 0)
        #expect(await f.transport.calls == 0)
    }

    @Test @MainActor func semanticQueryAdapterExplicitAcceptAuthenticatesAndReturnsTransientUsage() async throws {
        let f = try await QueryAdapterFixture()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let adapter = try SemanticQueryExecutionAdapter.cloud(service: f.service, lease: f.session.lease,
            generation: f.generation, accessGate: f.gate, validateCurrentAuthority: {}, approveQuery: { _ in true })
        let result = try await adapter.execute(query: "private query")
        try result.validatePublication()
        #expect(f.auth.calls.withLock { $0 } == 1)
        #expect(await f.transport.calls == 1)
        #expect(result.usage?.inputTokens == 2)
    }
    @Test @MainActor func semanticQueryAdapterRepeatedRetirementReleasesServiceRegistrations() async throws {
        let f = try await QueryAdapterFixture()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let baseline = f.service.embeddingInvalidatorCount
        for _ in 0..<100 {
            let adapter = try SemanticQueryExecutionAdapter.cloud(service: f.service, lease: f.session.lease,
                generation: f.generation, accessGate: f.gate, validateCurrentAuthority: {}, approveQuery: { _ in true })
            #expect(f.service.embeddingInvalidatorCount == baseline + 2)
            adapter.invalidate()
            #expect(f.service.embeddingInvalidatorCount == baseline)
        }
        #expect(f.auth.calls.withLock { $0 } == 0)
        #expect(await f.transport.calls == 0)
    }

    @Test(arguments: ["model", "credential", "lease", "invalidate"]) @MainActor
    func semanticQueryAdapterRetiresExactCloudPublicationBarrier(_ change: String) async throws {
        let f = try await QueryAdapterFixture()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/query-consent/barriers/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"),
            vaultID: f.session.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
            schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
        let snapshot = try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("Canonical evidence")])]),
            pageID: UUID(), condition: .createOnly)
        let permit = try await store.embeddingPublicationPermit(pageID: snapshot.pageID, expected: snapshot.revision)
        let adapter = try SemanticQueryExecutionAdapter.cloud(service: f.service, lease: f.session.lease,
            generation: f.generation, accessGate: f.gate, validateCurrentAuthority: {}, approveQuery: { _ in true })
        let completed = try await adapter.execute(query: "private query")
        try completed.validatePublication()
        #expect(adapter.publicationAuthority.matches(lease: f.session.lease, generation: f.generation))
        try permit.withPublication(authority: adapter.publicationAuthority) {}
        switch change {
        case "model": try f.service.setEmbeddingModel("text-embedding-3-large")
        case "credential": try await f.service.credentialBroker.replace("synthetic-retired-query-key")
        case "lease": f.gate.updateState(.locking(f.session))
        default: adapter.invalidate()
        }
        #expect(throws: (any Error).self) {
            try permit.withPublication(authority: adapter.publicationAuthority) { Issue.record("Stale query published") }
        }
        try await store.close()
    }

    @Test @MainActor func semanticQueryAdapterRetiresNativePublicationBarrier() async throws {
        let f = try await QueryAdapterFixture()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let descriptor = try EmbeddingModelDescriptor(providerID: "synthetic", modelID: "native-query", revision: "1",
            dimensions: 2, maximumInputUTF8Bytes: 100, maximumBatchSize: 1)
        let generation = try EmbeddingIndexGeneration(vaultID: f.session.vaultID, model: descriptor,
            chunkingVersion: EmbeddingChunker.version)
        let adapter = try SemanticQueryExecutionAdapter.native(provider: MockEmbeddingProvider(descriptor: descriptor),
            lease: f.session.lease, generation: generation, accessGate: f.gate, validateCurrentAuthority: {})
        let completed = try await adapter.execute(query: "native query")
        try completed.validatePublication()
        #expect(adapter.publicationAuthority.matches(lease: f.session.lease, generation: generation))
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/query-consent/native-barriers/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"),
            vaultID: f.session.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
            schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
        let snapshot = try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("Canonical evidence")])]),
            pageID: UUID(), condition: .createOnly)
        let permit = try await store.embeddingPublicationPermit(pageID: snapshot.pageID, expected: snapshot.revision)
        try permit.withPublication(authority: adapter.publicationAuthority) {}
        adapter.invalidate()
        #expect(throws: CancellationError.self) { try completed.validatePublication() }
        #expect(throws: (any Error).self) {
            try permit.withPublication(authority: adapter.publicationAuthority) { Issue.record("Stale native query published") }
        }
        try await store.close()
    }

    @Test @MainActor func semanticQueryAdapterRejectsWrongChunkerBeforeRegisteringAuthority() async throws {
        let f = try await QueryAdapterFixture()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let generation = try EmbeddingIndexGeneration(vaultID: f.session.vaultID,
            model: f.generation.model, chunkingVersion: "unsupported-query-chunker")
        let baseline = f.service.embeddingInvalidatorCount
        #expect(throws: EmbeddingContractError.incompatibleGeneration) {
            try SemanticQueryExecutionAdapter.cloud(service: f.service, lease: f.session.lease,
                generation: generation, accessGate: f.gate, validateCurrentAuthority: {}, approveQuery: { _ in true })
        }
        #expect(f.service.embeddingInvalidatorCount == baseline)
        #expect(f.auth.calls.withLock { $0 } == 0)
        #expect(await f.transport.calls == 0)
    }

}
