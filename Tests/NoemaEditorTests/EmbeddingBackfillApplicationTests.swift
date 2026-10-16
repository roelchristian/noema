import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore
@testable import noema

final class BackfillNativeProbe: Sendable { let calls = Mutex(0) }
final class BackfillNativeBackend: AppleSentenceEmbeddingBackend {
    let languageCode = "en", dimension = 3
    let revision: Int
    let probe: BackfillNativeProbe
    init(_ probe: BackfillNativeProbe, revision: Int = 1) { self.probe = probe; self.revision = revision }
    func dominantLanguage(for text: String) -> String? { "en" }
    func wordCount(for text: String) -> Int { text.split(separator: " ").count }
    func vector(for text: String) -> [Double]? { probe.calls.withLock { $0 += 1 }; return [0.25, 0.5, 0.75] }
}
final class BackfillKeychain: ExternalAIKeychain, Sendable {
    let value = Mutex<Data?>(nil)
    func read() throws -> Data? { value.withLock { $0 } }
    func write(_ data: Data) throws { value.withLock { $0 = data } }
    func delete() throws { value.withLock { $0 = nil } }
}
final class BackfillAuthenticator: ExternalAIAuthenticating, Sendable {
    let calls = Mutex(0)
    let beforeAuthentication = Mutex<(@Sendable () async throws -> Void)?>(nil)
    func authenticate() async throws {
        calls.withLock { $0 += 1 }
        let callback = beforeAuthentication.withLock { $0 }
        try await callback?()
    }
}
actor BackfillTransport: OpenAITransporting {
    private(set) var count = 0
    private(set) var models: [String] = []
    private(set) var inputs: [[String]] = []
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void,
                 didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        let started = Mutex(false)
        try beforeDispatch { started.withLock { $0 = true } }
        guard started.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        let body = try #require(request.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let model = try #require(payload["model"] as? String)
        let input = try #require(payload["input"] as? [String])
        let selection = try #require(OpenAIEmbeddingModel(rawValue: model))
        count += 1; models.append(model); inputs.append(input); didDispatch()
        return OpenAIHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
            "object": "list", "model": model,
            "data": [["object": "embedding", "index": 0, "embedding": Array(repeating: 0.25, count: selection.dimensions)]],
            "usage": ["prompt_tokens": 9, "total_tokens": 9]
        ]))
    }
}

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct EmbeddingBackfillApplicationTests {
    @MainActor func fixture(pages: Int, sources: Int = 0, cloud: Bool = false, sessionNow: @escaping @Sendable () -> Date = { Date() }) async throws -> (AppModel, URL, UserDefaults, String, BackfillNativeProbe, BackfillAuthenticator, BackfillTransport) {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-05-app/app-fixtures/\(UUID())")
        let root = base.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        for n in 0..<pages { _ = try await repository.create(title: "Historical page \(n)", body: "This historical human paragraph describes a city numbered \(n).") }
        for n in 0..<sources { _ = try await repository.importSource(data: Data("This historical source describes a distant island numbered \(n).".utf8), filename: "evidence\(n).txt", title: "Source \(n)", originURL: nil) }
        let domain = "noema-backfill-app-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(try JSONEncoder().encode(VaultAIConfiguration(enabled: true, provider: cloud ? .openAI : .onDevice)),
            forKey: VaultAIConfigurationStore.key(for: repository.manifest.id))
        try await repository.shutdownPageStorage()
        let probe = BackfillNativeProbe(), authenticator = BackfillAuthenticator(), transport = BackfillTransport()
        let broker = ExternalAICredentialBroker(keychain: BackfillKeychain())
        try await broker.store("synthetic-historical-app-key")
        let model = AppModel(aiDefaults: defaults, activityRecorder: AIActivityRecorder(store: nil), externalAIServiceFactory: { gate, defaults, recorder in
            let sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
                authenticator: authenticator, now: sessionNow, observeSystemEvents: false)
            let grants = ExternalAIVaultGrants(keychain: BackfillKeychain(), credentialBroker: broker, accessGate: gate,
                revocationDefaults: defaults, authenticator: authenticator)
            let service = ExternalAIService(accessGate: gate, defaults: defaults, activityRecorder: recorder,
                credentialBroker: broker, vaultGrants: grants, sessionManager: sessions,
                gateway: ExternalAIGateway(credentialBroker: broker, sessionManager: sessions, accessGate: gate))
            service.embeddingAuthorizerFactory = { _, configuration in
                ExternalAIEmbeddingAuthorizer(credentialBroker: broker, sessionManager: sessions, accessGate: gate,
                    configuration: configuration, transport: transport, allowsAuthentication: false)
            }
            return service
        })
        model.localStorageRoot = base.appendingPathComponent("support"); model.persistSecurityScopedBookmark = false
        let provider = try AppleSentenceEmbeddingProvider(backend: BackfillNativeBackend(probe))
        model.embeddingProviderFactory = { provider }
        var configuration = AIProcessingConfiguration()
        configuration.newPageDelay = 0; configuration.updatedPageDelay = 0
        configuration.newSourceDelay = 0; configuration.updatedSourceDelay = 0; configuration.recoveryDelay = 0
        model.aiProcessingConfiguration = configuration
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try Task.checkCancellation(); await Task.yield() })
        await model.open(root, create: false)
        try #require(model.isVaultAvailable)
        return (model, root, defaults, domain, probe, authenticator, transport)
    }

    @MainActor func completed(_ model: AppModel, batchID: UUID) async throws -> EmbeddingBackfillBatch {
        for _ in 0..<400 {
            if let ledger = model.aiProcessingLedger, let batch = try await ledger.embeddingBatch(id: batchID), batch.state == .completed { return batch }
            try await Task.sleep(for: .milliseconds(10))
        }
        let ledger = try #require(model.aiProcessingLedger)
        let members = try await ledger.embeddingBatchMembers(batchID: batchID)
        Issue.record("Historical batch did not complete: \(members.map { $0.state.rawValue })")
        return try #require(try await ledger.embeddingBatch(id: batchID))
    }

    @Test @MainActor func actualNativeBackfillUsesExactScopesBoundedAdmissionAndDurableReuse() async throws {
        let (model, _, defaults, domain, probe, _, _) = try await fixture(pages: 35, sources: 2)
        defer { defaults.removePersistentDomain(forName: domain) }
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let inventory = try await model.backfillInventory(for: lease)
        #expect(inventory.pageCount == 35); #expect(inventory.sourceCount == 2)
        #expect(probe.calls.withLock { $0 } == 0)
        let repository = try #require(model.repository)
        let original = try await repository.scan().notes
        let batchID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        let batch = try await completed(model, batchID: batchID)
        #expect(batch.scopes == [.page]); #expect(probe.calls.withLock { $0 } == 35)
        #expect(try await repository.scan().notes.map { ($0.id.uuidString + $0.body + $0.contentHash) }.sorted() == original.map { ($0.id.uuidString + $0.body + $0.contentHash) }.sorted())
        let ledger = try #require(model.aiProcessingLedger)
        #expect(try await ledger.embeddingBatchMembers(batchID: batchID).allSatisfy { $0.entityKind == .page && $0.state == .completed })
        let repeatID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        _ = try await completed(model, batchID: repeatID)
        #expect(probe.calls.withLock { $0 } == 35)
        #expect(try await ledger.embeddingBatchMembers(batchID: repeatID).allSatisfy { $0.state == .skipped })
        let sourceID = try await model.startEmbeddingBackfill(for: lease, scopes: [.source])
        _ = try await completed(model, batchID: sourceID)
        #expect(probe.calls.withLock { $0 } == 37)
        #expect(try await ledger.embeddingBatchMembers(batchID: sourceID).allSatisfy { $0.entityKind == .source })
        #expect(await model.closeVault())
    }

    @Test(arguments: [false, true]) @MainActor func restartRequiresFreshHistoricalCloudApprovalAndResumesNativeAutomatically(_ cloud: Bool) async throws {
        let (model, root, defaults, domain, probe, authenticator, transport) = try await fixture(pages: 35, cloud: cloud)
        defer { defaults.removePersistentDomain(forName: domain) }
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let repository = try #require(model.repository)
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        await model.bindAIProcessing(repository: repository, lease: lease)
        let batchID = try await model.startEmbeddingBackfill(for: lease, scopes: [.page])
        #expect(probe.calls.withLock { $0 } == 0); #expect(await transport.count == 0)
        let beforePrompts = authenticator.calls.withLock { $0 }
        #expect(beforePrompts == (cloud ? 1 : 0))
        #expect(await model.closeVault())
        model.aiProcessingClock = AIProcessingClock(now: { Date() }, sleep: { _ in try Task.checkCancellation(); await Task.yield() })
        await model.open(root, create: false)
        let fresh = try #require(model.sessionManager.accessGate.currentLease)
        #expect(fresh != lease)
        if cloud {
            let ledger = try #require(model.aiProcessingLedger)
            #expect(try await ledger.embeddingBatch(id: batchID)?.state == .awaitingApproval)
            #expect(await transport.count == 0)
            #expect(authenticator.calls.withLock { $0 } == beforePrompts)
            try await model.resumeEmbeddingBackfill(batchID: batchID, for: fresh)
        }
        _ = try await completed(model, batchID: batchID)
        if cloud { #expect(await transport.count == 35) }
        else { #expect(probe.calls.withLock { $0 } == 35) }
        await #expect(throws: (any Error).self) { try await model.resumeEmbeddingBackfill(batchID: batchID, for: lease) }
        #expect(await model.closeVault())
    }
}
}
