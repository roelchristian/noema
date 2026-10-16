import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore
@testable import noema

private final class IncrementalApprovalKeychain: ExternalAIKeychain, Sendable {
    private let value = Mutex<Data?>(nil)
    func read() throws -> Data? { value.withLock { $0 } }
    func write(_ data: Data) throws { value.withLock { $0 = data } }
    func delete() throws { value.withLock { $0 = nil } }
}
private struct IncrementalApprovalAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws {}
}

@MainActor private struct IncrementalApprovalFixture {
    let defaults: UserDefaults
    let domain: String
    let gate: VaultAccessGate
    let session: VaultSession
    let service: ExternalAIService

    init() async throws {
        domain = "noema-embedding-document-approval-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: domain))
        session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-embedding-approval-\(UUID())"), generation: 1)
        gate = VaultAccessGate(initialState: .open(session))
        let broker = ExternalAICredentialBroker(keychain: IncrementalApprovalKeychain())
        try await broker.store("synthetic-incremental-approval-key")
        let authenticator = IncrementalApprovalAuthenticator()
        let sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: authenticator, observeSystemEvents: false)
        let grants = ExternalAIVaultGrants(keychain: IncrementalApprovalKeychain(), credentialBroker: broker,
            accessGate: gate, revocationDefaults: defaults, authenticator: authenticator)
        service = ExternalAIService(accessGate: gate, defaults: defaults, activityRecorder: AIActivityRecorder(store: nil),
            credentialBroker: broker, vaultGrants: grants, sessionManager: sessions,
            gateway: ExternalAIGateway(credentialBroker: broker, sessionManager: sessions, accessGate: gate))
        try VaultAIConfigurationStore(defaults: defaults).set(.init(enabled: true, provider: .openAI),
            lease: session.lease, gate: gate)
    }
    func request(scope: EmbeddingProcessingScope? = nil) throws -> ExternalAIEmbeddingRequest {
        let entity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page, entityID: UUID(), revision: "committed-revision")
        return try ExternalAIEmbeddingRequest(inputs: ["Committed original human text."], scope: scope ?? .document(entity),
            model: service.embeddingConfiguration.embeddingDescriptor, authority: ExternalAIVaultAuthority(session: session))
    }
}

private final class AppIncrementalEmbeddingProvider: EmbeddingProvider, Sendable {
    let descriptor: EmbeddingModelDescriptor
    let calls = Mutex(0)
    init() throws {
        descriptor = try .init(providerID: "synthetic-on-device", modelID: "app-integration", revision: "1",
            dimensions: 3, maximumInputUTF8Bytes: 1024, maximumBatchSize: 16)
    }
    func embed(_ inputs: [String], scope: EmbeddingProcessingScope,
               context: EmbeddingExecutionContext) async throws -> [EmbeddingVector] {
        calls.withLock { $0 += inputs.count }
        return try await MockEmbeddingProvider(descriptor: descriptor).embed(inputs, scope: scope, context: context)
    }
    var count: Int { calls.withLock { $0 } }
}

// AppModel lifecycle fixtures stay in the repository's shared serialized suite.
extension VaultUIIntegrationTests {
@Suite(.serialized)
struct EmbeddingDocumentApprovalTests {
    @Test @MainActor func embeddingDocumentApprovalDoesNotBorrowEnrichmentOrExtendToHistoryOrQueries() async throws {
        let f = try await IncrementalApprovalFixture()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let request = try f.request()
        #expect(!f.service.embeddingDocumentsApproved(for: f.session.lease))
        await #expect(throws: (any Error).self) { try await f.service.approveEmbeddingRequest(request) }
        try await f.service.approveEmbeddingDocuments(for: f.session.lease)
        #expect(f.service.embeddingDocumentsApproved(for: f.session.lease))
        _ = try await f.service.approveEmbeddingRequest(request)
        let identity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .source, entityID: UUID(), revision: "committed-revision")
        let historical = try f.request(scope: .historicalBackfill(jobID: UUID(), entity: identity))
        let query = try f.request(scope: .query(vaultID: f.session.vaultID, queryID: UUID()))
        await #expect(throws: ExternalAIError.consentRequired) { try await f.service.approveEmbeddingRequest(historical) }
        await #expect(throws: ExternalAIError.consentRequired) { try await f.service.approveEmbeddingRequest(query) }
        #expect(!f.service.vaultGrantApproved)
    }

    @Test(arguments: ["model", "consent", "credential", "nativeSession", "revoke"])
    @MainActor func embeddingDocumentApprovalRetiresSynchronouslyWithPolicyChanges(_ mutation: String) async throws {
        let f = try await IncrementalApprovalFixture()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        try await f.service.approveEmbeddingDocuments(for: f.session.lease)
        let validation = try f.service.embeddingDocumentValidation(for: f.session.lease)
        try validation()
        switch mutation {
        case "model": try f.service.setEmbeddingModel("text-embedding-3-large")
        case "consent": f.service.setConsentPolicy(.neverAsk)
        case "credential":
            try await f.service.credentialBroker.replace("synthetic-replaced-incremental-key")
            await f.service.refreshStatus()
        case "nativeSession": f.service.sessionManager.revoke()
        default: f.service.revokeAuthorization()
        }
        #expect(throws: (any Error).self) { try validation() }
        #expect(!f.service.embeddingDocumentsApproved(for: f.session.lease))
    }

    @Test @MainActor func embeddingBackgroundAdmissionCannotPromptForFreshNativeAuthority() async throws {
        let f = try await IncrementalApprovalFixture()
        defer { f.defaults.removePersistentDomain(forName: f.domain) }
        let authority = ExternalAIVaultAuthority(lease: f.session.lease)
        await #expect(throws: ExternalAIError.authorizationRevoked) {
            try await f.service.sessionManager.authorize(authority, allowAuthentication: false)
        }
        #expect(await f.service.sessionManager.state != .authorized)
        try await f.service.approveEmbeddingDocuments(for: f.session.lease)
        _ = try await f.service.sessionManager.authorize(authority, allowAuthentication: false)
        f.service.sessionManager.revoke()
        #expect(!f.service.embeddingDocumentsApproved(for: f.session.lease))
        await #expect(throws: ExternalAIError.authorizationRevoked) {
            try await f.service.sessionManager.authorize(authority, allowAuthentication: false)
        }
    }

    @Test @MainActor func embeddingAppBaselineNewChangeEmptyRemovalAndStaleRebindUseActualCoordinator() async throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-04b/app-fixtures/\(UUID())")
        let root = base.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let beforeOpen = try await openCanonicalAppFixture(root: root, create: true)
        _ = try await beforeOpen.create(title: "Historical baseline", body: "This historical paragraph remains unsubmitted.")
        let domain = "noema-embedding-app-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(try JSONEncoder().encode(VaultAIConfiguration(enabled: true, provider: .onDevice)),
            forKey: VaultAIConfigurationStore.key(for: beforeOpen.manifest.id))
        try await beforeOpen.shutdownPageStorage()
        let provider = try AppIncrementalEmbeddingProvider()
        let model = AppModel(aiDefaults: defaults)
        model.localStorageRoot = base.appendingPathComponent("support")
        model.persistSecurityScopedBookmark = false
        model.embeddingProviderFactory = { provider }
        var configuration = AIProcessingConfiguration()
        configuration.newPageDelay = 0; configuration.updatedPageDelay = 0
        configuration.newSourceDelay = 0; configuration.updatedSourceDelay = 0; configuration.recoveryDelay = 0
        model.aiProcessingConfiguration = configuration
        await model.open(root, create: false)
        try #require(model.isVaultAvailable)
        let repository = try #require(model.repository)
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let index = try #require(model.semanticIndex)
        let unpublished = try #require(model.semanticProcessingGeneration)
        await model.bindAIProcessing(repository: repository, lease: lease, preservingEmbeddingApproval: true)
        #expect(model.semanticProcessingGeneration == unpublished)
        let coordinator = try #require(model.aiProcessingCoordinator)
        #expect(provider.count == 0)
        #expect(await coordinator.workItems().isEmpty)
        let page = try await repository.create(title: "New human page", body: "This new human paragraph describes a distant city.")
        try await awaitEmbeddingCompletion(index, entityID: page.id)
        #expect(provider.count == 1)
        let saved = try await repository.save(note: page, title: page.title, body: "This changed human paragraph describes another city.", tags: [])
        try await awaitEmbeddingCompletion(index, entityID: saved.id, revision: saved.contentHash)
        #expect(provider.count == 2)
        let empty = try await repository.create(title: "Empty new page", body: "")
        try await awaitEmbeddingCompletion(index, entityID: empty.id)
        #expect(provider.count == 2)
        try await repository.trash(note: saved)
        for _ in 0..<200 {
            let generations = try await index.generations()
            if try await generations.asyncAllDocuments(in: index).allSatisfy({ $0.identity.entityID != saved.id }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let generations = try await index.generations()
        #expect(try await generations.asyncAllDocuments(in: index).allSatisfy { $0.identity.entityID != saved.id })
        let staleSession = VaultSession(vaultID: UUID(), root: base.appendingPathComponent("other"), generation: 99)
        await model.bindAIProcessing(repository: repository, lease: staleSession.lease)
        #expect(model.aiProcessingCoordinator === coordinator)
        #expect(model.sessionManager.accessGate.currentLease == lease)
        #expect(await model.closeVault())
        // Remove a previously completed empty entity while the application is closed.
        // Reopening cleans the derived row without admitting the historical baseline.
        let closedRepository = try await openCanonicalAppFixture(root: root)
        try await closedRepository.trash(note: empty)
        try await closedRepository.shutdownPageStorage()
        await model.open(root, create: false)
        try #require(model.isVaultAvailable)
        let reopenedIndex = try #require(model.semanticIndex)
        let reopenedGenerations = try await reopenedIndex.generations()
        #expect(try await reopenedGenerations.asyncAllDocuments(in: reopenedIndex).allSatisfy {
            $0.identity.entityID != empty.id && $0.identity.entityID != saved.id
        })
        #expect(provider.count == 2)
        #expect(await model.closeVault())
    }

    @MainActor private func awaitEmbeddingCompletion(_ index: SQLiteEmbeddingIndex, entityID: UUID, revision: String? = nil) async throws {
        for _ in 0..<200 {
            let generations = try await index.generations()
            for generation in generations {
                if try await index.completedDocuments(generation: generation).contains(where: {
                    $0.identity.entityID == entityID && (revision == nil || $0.workRevision == revision)
                }) { return }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Actual coordinator did not durably complete the requested embedding document")
    }
}
}

private extension Array where Element == EmbeddingIndexGeneration {
    func asyncAllDocuments(in index: SQLiteEmbeddingIndex) async throws -> [EmbeddingDocumentCompletion] {
        var result: [EmbeddingDocumentCompletion] = []
        for generation in self { result += try await index.completedDocuments(generation: generation) }
        return result
    }
}
