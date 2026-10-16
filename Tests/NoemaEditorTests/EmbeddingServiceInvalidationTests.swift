import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore
@testable import noema

private final class EmbeddingServiceKeychain: ExternalAIKeychain, Sendable {
    private struct State { var value: Data?; var rejectsMutation = false }
    private let state = Mutex(State())
    func read() throws -> Data? { state.withLock { $0.value } }
    func write(_ data: Data) throws {
        try state.withLock {
            guard !$0.rejectsMutation else { throw ExternalAIError.credentialUnavailable }
            $0.value = data
        }
    }
    func delete() throws {
        try state.withLock {
            guard !$0.rejectsMutation else { throw ExternalAIError.credentialUnavailable }
            $0.value = nil
        }
    }
    func rejectMutations() { state.withLock { $0.rejectsMutation = true } }
}

private struct EmbeddingServiceAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws {}
}

private func embeddingServiceBoundary(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}

/// Service-only fixtures use no AppModel, window or shared application lifecycle state.
@MainActor private struct EmbeddingServiceFixture {
    let root: URL
    let domain: String
    let defaults: UserDefaults
    let service: ExternalAIService
    let grantsKeychain: EmbeddingServiceKeychain
    let session: VaultSession
    let gate: VaultAccessGate
    let store: SQLiteBlockStore
    let index: SQLiteEmbeddingIndex
    let snapshot: BlockStoreSnapshot
    let identity: EmbeddingEntityIdentity
    let generation: EmbeddingIndexGeneration
    let record: EmbeddingRecord

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-embedding-service-\(UUID())")
        let canonical = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        domain = "noema-embedding-service-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: domain))
        session = VaultSession(vaultID: UUID(), root: canonical, generation: 1)
        gate = VaultAccessGate(initialState: .open(session))
        let broker = ExternalAICredentialBroker(keychain: EmbeddingServiceKeychain())
        try await broker.store("synthetic-embedding-service-credential")
        grantsKeychain = EmbeddingServiceKeychain()
        let authenticator = EmbeddingServiceAuthenticator()
        let sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: authenticator, observeSystemEvents: false)
        let grants = ExternalAIVaultGrants(keychain: grantsKeychain, credentialBroker: broker,
            accessGate: gate, revocationDefaults: defaults, authenticator: authenticator)
        let gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: sessions, accessGate: gate)
        service = ExternalAIService(accessGate: gate, defaults: defaults, activityRecorder: AIActivityRecorder(store: nil),
            credentialBroker: broker, vaultGrants: grants, sessionManager: sessions, gateway: gateway)
        store = try SQLiteBlockStore(canonicalStagingURL: canonical.appendingPathComponent("blocks.sqlite"),
            vaultID: session.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
            schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
        snapshot = try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("Committed original")])]),
            pageID: UUID(), condition: .createOnly)
        generation = try EmbeddingIndexGeneration(vaultID: session.vaultID,
            model: OpenAIEmbeddingConfiguration.default.embeddingDescriptor, chunkingVersion: EmbeddingChunker.version)
        identity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page,
            entityID: snapshot.pageID, revision: snapshot.revision.token.base64EncodedString())
        let chunk = try EmbeddingChunk(identity: identity, chunkID: "original", ordinal: 0,
            contentFingerprint: "original-fingerprint", chunkingVersion: generation.chunkingVersion)
        record = try EmbeddingRecord(generation: generation, chunk: chunk,
            vector: EmbeddingVector(values: Array(repeating: 1, count: generation.model.dimensions), model: generation.model))
        index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"),
            lease: session.lease, accessGate: gate)
    }
    func clean() async throws {
        try await store.close()
        defaults.removePersistentDomain(forName: domain)
        try FileManager.default.removeItem(at: root)
    }
}

private enum EmbeddingServiceChange: String, CaseIterable, Sendable {
    case embeddingModel, generativeModel, consentPolicy, revokeAuthorization, revokeVaultProcessing
    case credentialSaveCleanupFailure, credentialRemovalCleanupFailure
}

@Suite("Embedding service publication invalidation", .serialized)
struct EmbeddingServiceInvalidationTests {
    @Test(arguments: EmbeddingServiceChange.allCases) @MainActor
    private func serviceMutationRejectsPublicationAtFinalSQLiteBoundary(_ change: EmbeddingServiceChange) async throws {
        let f = try await EmbeddingServiceFixture()
        let authority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: f.generation)
        let registration = f.service.registerEmbeddingInvalidator { authority.invalidate() }
        defer { f.service.removeEmbeddingInvalidator(registration) }
        let initial = try await f.store.embeddingPublicationPermit(pageID: f.snapshot.pageID, expected: f.snapshot.revision)
        try await f.index.replaceDocument(identity: f.identity, generation: f.generation, records: [f.record],
            permit: initial, authority: authority, validatePublication: {})
        let permit = try await f.store.embeddingPublicationPermit(pageID: f.snapshot.pageID, expected: f.snapshot.revision)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let validations = Mutex(0)
        let index = f.index, identity = f.identity, generation = f.generation
        let publication = Task.detached {
            try await index.replaceDocument(identity: identity, generation: generation, records: [],
                permit: permit, authority: authority, validatePublication: {
                    if validations.withLock({ $0 += 1; return $0 == 2 }) {
                        entered.signal()
                        guard release.wait(timeout: .now() + 5) == .success else { throw AIWorkFailure.validation }
                    }
                })
        }
        #expect(await embeddingServiceBoundary(entered))
        switch change {
        case .embeddingModel: try f.service.setEmbeddingModel("text-embedding-3-large")
        case .generativeModel: try f.service.setModel("gpt-4.1")
        case .consentPolicy: f.service.setConsentPolicy(.neverAsk)
        case .revokeAuthorization: f.service.revokeAuthorization()
        case .revokeVaultProcessing: try f.service.revokeVaultProcessing(for: f.session.lease)
        case .credentialSaveCleanupFailure:
            f.grantsKeychain.rejectMutations()
            await #expect(throws: (any Error).self) {
                try await f.service.saveCredential("synthetic-replacement-credential", thirtyDayPolicy: false)
            }
        case .credentialRemovalCleanupFailure:
            f.grantsKeychain.rejectMutations()
            await #expect(throws: (any Error).self) { try await f.service.removeCredential() }
        }
        release.signal()
        await #expect(throws: (any Error).self) { try await publication.value }
        #expect(try await f.index.records(generation: f.generation) == [f.record])
        #expect(try await f.store.load(pageID: f.snapshot.pageID) == f.snapshot)
        try await f.clean()
    }

    @Test @MainActor
    func staleVaultRevocationCannotRetireCurrentVaultPublication() async throws {
        let f = try await EmbeddingServiceFixture()
        let authority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: f.generation)
        let registration = f.service.registerEmbeddingInvalidator { authority.invalidate() }
        defer { f.service.removeEmbeddingInvalidator(registration) }
        let stale = VaultSession(vaultID: UUID(), root: f.root.appendingPathComponent("previous-vault"), generation: 2)
        #expect(throws: ExternalAIError.staleSession) { try f.service.revokeVaultProcessing(for: stale.lease) }
        let permit = try await f.store.embeddingPublicationPermit(pageID: f.snapshot.pageID, expected: f.snapshot.revision)
        try await f.index.replaceDocument(identity: f.identity, generation: f.generation, records: [f.record],
            permit: permit, authority: authority, validatePublication: {})
        #expect(try await f.index.records(generation: f.generation) == [f.record])
        try await f.clean()
    }

    @Test @MainActor
    func rejectedAndEqualModelSelectionsPreserveCurrentAuthority() async throws {
        let f = try await EmbeddingServiceFixture()
        let authority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: f.generation)
        let registration = f.service.registerEmbeddingInvalidator { authority.invalidate() }
        defer { f.service.removeEmbeddingInvalidator(registration) }
        #expect(throws: ExternalAIError.invalidConfiguration) { try f.service.setEmbeddingModel("gpt-4.1") }
        try f.service.setEmbeddingModel("text-embedding-3-small")
        let permit = try await f.store.embeddingPublicationPermit(pageID: f.snapshot.pageID, expected: f.snapshot.revision)
        try await f.index.replaceDocument(identity: f.identity, generation: f.generation, records: [f.record],
            permit: permit, authority: authority, validatePublication: {})
        #expect(try await f.index.records(generation: f.generation) == [f.record])
        try await f.clean()
    }
}
