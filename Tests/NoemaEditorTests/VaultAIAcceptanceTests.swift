import Foundation
import Synchronization
import Testing
@testable import ExternalAI
import VaultCore
@testable import noema

private enum VaultAcceptanceFailure: Error { case timedOut }

private final class AcceptanceKeychain: ExternalAIKeychain, Sendable {
    private struct State { var data: Data?; var fail = false; var mutations = 0 }
    private let state = Mutex(State())
    func read() throws -> Data? { state.withLock { $0.data } }
    func write(_ data: Data) throws {
        try state.withLock {
            $0.mutations += 1
            guard !$0.fail else { throw ExternalAIError.credentialUnavailable }
            $0.data = data
        }
    }
    func delete() throws {
        try state.withLock {
            $0.mutations += 1
            guard !$0.fail else { throw ExternalAIError.credentialUnavailable }
            $0.data = nil
        }
    }
    func failMutations(_ fail: Bool) { state.withLock { $0.fail = fail } }
    var mutations: Int { state.withLock { $0.mutations } }
}

private actor AcceptanceAuthenticator: ExternalAIAuthenticating {
    private(set) var count = 0
    func authenticate() async throws { count += 1 }
}

/// One-shot deterministic suspension; release is synchronous so failure cleanup cannot
/// strand a provider that deliberately returns after cancellation.
private final class AcceptanceLatch: Sendable {
    private struct State {
        var armed = false
        var entered = false
        var pending: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    func arm() { state.withLock { $0.armed = true; $0.entered = false } }
    func pauseIfArmed() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock {
                guard $0.armed else { return true }
                $0.armed = false; $0.entered = true; $0.pending = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func waitUntilEntered() async throws {
        for _ in 0..<1_000 {
            if state.withLock({ $0.entered }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw VaultAcceptanceFailure.timedOut
    }
    func release() {
        let pending = state.withLock { value in
            let pending = value.pending; value.pending = nil; value.armed = false
            return pending
        }
        pending?.resume()
    }
}

private actor AcceptanceTransport: OpenAITransporting {
    private(set) var count = 0
    let dispatchPause: AcceptanceLatch
    init(dispatchPause: AcceptanceLatch) { self.dispatchPause = dispatchPause }
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void,
                 didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        await dispatchPause.pauseIfArmed()
        let resumed = Mutex(false)
        try beforeDispatch { resumed.withLock { $0 = true } }
        guard resumed.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        count += 1; didDispatch()
        let output = #"{"title":null,"summary":"Accepted through vault policy","classification":null,"body":null}"#
        let envelope: [String: Any] = ["object": "response", "status": "completed", "output": [
            ["type": "message", "role": "assistant", "status": "completed", "content": [
                ["type": "output_text", "text": output]]]]]
        return OpenAIHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: envelope))
    }
}

@MainActor private struct VaultAcceptanceFixture {
    let root: URL
    let domain: String
    let defaults: UserDefaults
    let model: AppModel
    let repository: FileVaultRepository
    let note: NoteRecord
    let broker: ExternalAICredentialBroker
    let grantsKeychain: AcceptanceKeychain
    let authenticator: AcceptanceAuthenticator
    let preflight: AcceptanceLatch
    let localInference: AcceptanceLatch
    let dispatchPause: AcceptanceLatch
    let transport: AcceptanceTransport
    var service: ExternalAIService { model.externalAIService }
    var lease: VaultSessionLease { get throws { try #require(model.vaultAISettingsContext?.lease) } }

    init() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-vault-acceptance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let note = try await repository.create(title: "Human title", body: "Original vault content")
        let domain = "noema-vault-acceptance-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let manager = VaultSessionManager()
        let broker = ExternalAICredentialBroker(keychain: AcceptanceKeychain())
        try await broker.store("synthetic-vault-acceptance-key")
        let keychain = AcceptanceKeychain(), auth = AcceptanceAuthenticator()
        let preflight = AcceptanceLatch(), localInference = AcceptanceLatch(), dispatchPause = AcceptanceLatch()
        let transport = AcceptanceTransport(dispatchPause: dispatchPause)
        let recorder = AIActivityRecorder(store: nil)
        let grants = ExternalAIVaultGrants(keychain: keychain, credentialBroker: broker,
            accessGate: manager.accessGate, revocationDefaults: defaults, authenticator: auth)
        let sessions = ExternalAISessionManager(accessGate: manager.accessGate, credentialBroker: broker,
            authenticator: auth, observeSystemEvents: false)
        let gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: sessions,
            accessGate: manager.accessGate, transport: transport, activityRecorder: nil)
        let service = ExternalAIService(accessGate: manager.accessGate, defaults: defaults, activityRecorder: recorder,
            credentialBroker: broker, vaultGrants: grants, sessionManager: sessions, gateway: gateway,
            beforeAutomaticProviderAvailability: { await preflight.pauseIfArmed() })
        let model = AppModel(sessionManager: manager, aiDefaults: defaults, activityRecorder: recorder,
            externalAIServiceFactory: { _, _, _ in service })
        model.localStorageRoot = root.appendingPathComponent("local")
        model.persistSecurityScopedBookmark = false
        model.aiClient.unavailabilityReason = { nil }
        model.aiClient.pageTitle = { _ in await localInference.pauseIfArmed(); return "Late generated title" }
        model.aiClient.summarize = { _ in "Late generated summary" }
        model.aiClient.inferLCC = { _ in "QA76" }
        await model.open(root, create: false)
        for _ in 0..<300 {
            if model.vaultAISettingsContext != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(model.vaultAISettingsContext)
        self.root = root; self.domain = domain; self.defaults = defaults; self.model = model
        self.repository = repository; self.note = note; self.broker = broker; grantsKeychain = keychain
        authenticator = auth; self.preflight = preflight; self.localInference = localInference; self.transport = transport
        self.dispatchPause = dispatchPause
    }

    /// Exactly the mutation entry point used by IntelligenceSettings, with its displayed lease.
    func set(_ policy: VaultAIConfiguration) throws { try model.setVaultAIConfiguration(policy, for: lease) }
    func enableCloudAndApprove() async throws {
        try set(.init(enabled: true, provider: .openAI))
        try await service.approveVaultProcessing(for: lease)
    }
    func request() throws -> ExternalAISummaryRequest {
        try .init(authority: .init(lease: lease), target: .page(note.id),
                  contentRevision: UUID(), content: "Original vault content")
    }
    /// The revision UUID identifies this capture; provider text and canonical CAS use
    /// the same snapshot rather than an unrelated fixture string or a later reread.
    func request(for snapshot: PageSummarySnapshot) throws -> ExternalAISummaryRequest {
        try .init(authority: .init(lease: lease), target: .page(snapshot.note.id),
                  contentRevision: UUID(),
                  content: BlockDocumentCodec.readable(BlockDocumentCodec.decode(snapshot.note.body).withoutAISummary))
    }
    func reconstructedService() -> ExternalAIService {
        let gate = model.sessionManager.accessGate
        let grants = ExternalAIVaultGrants(keychain: grantsKeychain, credentialBroker: broker,
            accessGate: gate, revocationDefaults: defaults, authenticator: authenticator)
        let sessions = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: authenticator, observeSystemEvents: false)
        let gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: sessions,
            accessGate: gate, transport: transport, activityRecorder: nil)
        return ExternalAIService(accessGate: gate, defaults: defaults, activityRecorder: AIActivityRecorder(store: nil),
            credentialBroker: broker, vaultGrants: grants, sessionManager: sessions, gateway: gateway)
    }
    func cleanup() {
        preflight.release(); localInference.release(); dispatchPause.release()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

extension VaultUIIntegrationTests {
@Suite("Vault Settings and service acceptance", .serialized) @MainActor
struct VaultAIAcceptanceTests {
    @Test func settingsApprovalAuthorizesTwoExactRequestsAndCanonicalPublicationWithoutAnotherPrompt() async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        #expect(f.model.activeVaultAIConfiguration == .init())
        await #expect(throws: ExternalAIError.consentRequired) { try await f.service.authorizeAutomaticSubmission(f.request()) }
        try f.set(.init(enabled: true, provider: .openAI))
        await #expect(throws: ExternalAIError.consentRequired) { try await f.service.authorizeAutomaticSubmission(f.request()) }
        try await f.service.approveVaultProcessing(for: f.lease)
        var note = f.note
        for _ in 0..<2 {
            let snapshot = try await f.repository.pageSummarySnapshot(note)
            let request = try f.request(for: snapshot)
            let authority = try await f.service.authorizeAutomaticSubmission(request)
            let result = try await f.service.gateway.performAutomatic(request, authorization: authority)
            let permit = try await f.service.gateway.publicationPermit(for: result)
            note = try await f.repository.publishPageSummary(snapshot, summary: result.summary,
                provenance: SummaryProvenance(provider: "OpenAI", model: result.provenance.model, generatedAt: Date()),
                validate: { try permit.validateSynchronously() })
            #expect(note.title == "Human title")
            await #expect(throws: ExternalAIError.consentAlreadyUsed) {
                try await f.service.gateway.performAutomatic(request, authorization: authority)
            }
        }
        let restored = f.reconstructedService()
        _ = try await restored.authorizeAutomaticSubmission(f.request())
        #expect(await f.authenticator.count == 1)
        #expect(await f.transport.count == 2)
        #expect(BlockDocumentCodec.decode(note.body).aiSummary?.text == "Accepted through vault policy")
    }

    @Test func settingsDisableSurvivesKeychainFailureAndRejectsLateLocalPublication() async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        try f.set(.init(enabled: true, provider: .onDevice))
        let source = try await f.repository.importSource(data: Data("Source evidence".utf8),
            filename: "source.txt", title: "Original source", originURL: nil)
        await f.model.refresh()
        f.localInference.arm()
        f.model.enqueueSourceTitle(source)
        let worker = try #require(f.model.automaticSourceNamingTaskForTesting)
        try await f.localInference.waitUntilEntered()
        f.grantsKeychain.failMutations(true)
        let mutations = f.grantsKeychain.mutations
        #expect(throws: VaultAIConfigurationChangeError.cloudGrantCleanupFailed) {
            try f.set(.init(enabled: false, provider: .onDevice))
        }
        #expect(f.model.activeVaultAIConfiguration == .init())
        #expect(f.grantsKeychain.mutations > mutations)
        #expect(worker.isCancelled)
        #expect(VaultAIConfigurationStore(defaults: f.defaults).configuration(for: try f.lease.vaultID) == .init())
        f.localInference.release()
        await worker.value
        let saved = try await f.repository.loadSource(id: source.id)
        #expect(saved.metadata == source.metadata)
        #expect(await f.transport.count == 0)
    }

    @Test func oldServicePreflightCannotSurviveDisableReenableAndFreshApproval() async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        try await f.enableCloudAndApprove()
        let request = try f.request()
        f.preflight.arm()
        let pending = Task { try await f.service.authorizeAutomaticSubmission(request) }
        try await f.preflight.waitUntilEntered()
        try f.set(.init(enabled: false, provider: .openAI))
        try f.set(.init(enabled: true, provider: .openAI))
        try await f.service.approveVaultProcessing(for: f.lease)
        f.preflight.release()
        await #expect(throws: ExternalAIError.authorizationRevoked) { try await pending.value }
        _ = try await f.service.authorizeAutomaticSubmission(f.request())
        #expect(await f.authenticator.count == 2)
        #expect(await f.transport.count == 0)
    }

    @Test(arguments: [true, false]) func missingGlobalOrVaultMarkerCannotRestoreFailedRevocation(global: Bool) async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        try await f.enableCloudAndApprove()
        f.grantsKeychain.failMutations(true)
        if global {
            // Failed credential removal exercises the service's global grant cleanup;
            // the broker must retain the existing credential when that cleanup fails.
            await #expect(throws: ExternalAIError.credentialUnavailable) { try await f.service.removeCredential() }
        } else {
            #expect(throws: VaultAIConfigurationChangeError.cloudGrantCleanupFailed) {
                try f.set(.init(enabled: false, provider: .openAI))
            }
        }
        let displayedLease = try f.lease
        let suffix = global ? "all" : displayedLease.vaultID.uuidString
        f.defaults.removeObject(forKey: "externalAI.vaultGrantRevocation.v1." + suffix)
        _ = f.defaults.synchronize()
        if !global { try f.set(.init(enabled: true, provider: .openAI)) }
        let restored = f.reconstructedService()
        await #expect(throws: ExternalAIError.consentRequired) { try await restored.authorizeAutomaticSubmission(f.request()) }
        f.grantsKeychain.failMutations(false)
        try await f.service.approveVaultProcessing(for: f.lease)
        _ = try await f.service.authorizeAutomaticSubmission(f.request())
        #expect(await f.authenticator.count == 2)
        #expect(await f.transport.count == 0)
    }

    @Test(arguments: [false, true]) func failedGrantCleanupStillRevokesInteractiveAuthority(remove: Bool) async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        try await f.enableCloudAndApprove()
        f.service.setConsentPolicy(.oncePerSession)
        let snapshot = try await f.repository.pageSummarySnapshot(f.note)
        let request = try f.request(for: snapshot)
        let consent = try f.service.approveSubmission(request, userConfirmed: true)
        let result = try await f.service.gateway.summarizePage(request, consent: consent)
        let permit = try await f.service.gateway.publicationPermit(for: result)
        let sessions = f.service.sessionManager
        let capability = try await sessions.authorize(request.authority)
        let cancelled = Mutex(false)
        let cancellation = try sessions.registerCancellation(for: capability) { cancelled.withLock { $0 = true } }
        defer { sessions.unregisterCancellation(cancellation) }
        #expect(try !f.service.requiresSubmissionConfirmation(for: request.authority))
        let version = try await f.broker.credentialVersion()
        f.grantsKeychain.failMutations(true)
        await #expect(throws: ExternalAIError.credentialUnavailable) {
            if remove { try await f.service.removeCredential() }
            else { try await f.service.saveCredential("synthetic-replacement-key", thirtyDayPolicy: false) }
        }
        #expect(f.service.authorizationState == .revoked)
        #expect(await sessions.state == .revoked)
        #expect(cancelled.withLock { $0 })
        #expect(throws: ExternalAIError.self) { try sessions.validateSynchronously(capability) }
        #expect(try f.service.requiresSubmissionConfirmation(for: request.authority))
        #expect(try await f.broker.credentialVersion() == version)
        await #expect(throws: ExternalAIError.self) {
            try await f.repository.publishPageSummary(snapshot, summary: result.summary,
                provenance: SummaryProvenance(provider: "OpenAI", model: result.provenance.model, generatedAt: Date()),
                validate: { try permit.validateSynchronously() })
        }
        let saved = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
        #expect(saved.body == snapshot.note.body && saved.title == snapshot.note.title)
        #expect(await f.transport.count == 1)
    }

    @Test(arguments: [false, true]) func settingsChangeWhileWaitingToDispatchRejectsCloudRequest(changeProvider: Bool) async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        try await f.enableCloudAndApprove()
        let snapshot = try await f.repository.pageSummarySnapshot(f.note)
        let request = try f.request(for: snapshot)
        let authority = try await f.service.authorizeAutomaticSubmission(request)
        f.dispatchPause.arm()
        let pending = Task { try await f.service.gateway.performAutomatic(request, authorization: authority) }
        try await f.dispatchPause.waitUntilEntered()
        try f.set(changeProvider ? .init(enabled: true, provider: .onDevice) : .init(enabled: false, provider: .openAI))
        f.dispatchPause.release()
        await #expect(throws: ExternalAIError.self) { try await pending.value }
        #expect(await f.transport.count == 0)
        let saved = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
        #expect(saved.body == snapshot.note.body && saved.title == snapshot.note.title)
    }

    @Test(arguments: [false, true]) func settingsChangeAfterResponseRejectsCanonicalPublication(changeProvider: Bool) async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        try await f.enableCloudAndApprove()
        let snapshot = try await f.repository.pageSummarySnapshot(f.note)
        let request = try f.request(for: snapshot)
        let authority = try await f.service.authorizeAutomaticSubmission(request)
        let result = try await f.service.gateway.performAutomatic(request, authorization: authority)
        let permit = try await f.service.gateway.publicationPermit(for: result)
        try f.set(changeProvider ? .init(enabled: true, provider: .onDevice) : .init(enabled: false, provider: .openAI))
        await #expect(throws: ExternalAIError.self) { try await f.service.gateway.validatePublication(of: result) }
        await #expect(throws: ExternalAIError.self) {
            try await f.repository.publishPageSummary(snapshot, summary: result.summary,
                provenance: SummaryProvenance(provider: "OpenAI", model: result.provenance.model, generatedAt: Date()),
                validate: { try permit.validateSynchronously() })
        }
        let saved = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
        #expect(saved.body == snapshot.note.body && saved.title == snapshot.note.title)
        #expect(await f.transport.count == 1)
    }

    @Test func capturedContentAndRevisionCannotBeSubstitutedAndStaleSnapshotCannotPublish() async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        try await f.enableCloudAndApprove()
        let snapshot = try await f.repository.pageSummarySnapshot(f.note)
        let request = try f.request(for: snapshot)
        let authority = try await f.service.authorizeAutomaticSubmission(request)
        for altered in [
            try ExternalAISummaryRequest(id: request.id, authority: request.authority, target: request.target,
                contentRevision: request.contentRevision, content: "Substituted content"),
            try ExternalAISummaryRequest(id: request.id, authority: request.authority, target: request.target,
                contentRevision: UUID(), content: request.content)
        ] {
            await #expect(throws: ExternalAIError.consentRequired) {
                try await f.service.gateway.performAutomatic(altered, authorization: authority)
            }
        }
        #expect(await f.transport.count == 0)
        let result = try await f.service.gateway.performAutomatic(request, authorization: authority)
        #expect(result.requestID == request.id && result.contentRevision == request.contentRevision)
        let permit = try await f.service.gateway.publicationPermit(for: result)
        let edited = try await f.repository.save(note: snapshot.note, title: snapshot.note.title,
            body: "New human content after inference", tags: snapshot.note.tags)
        // Authority remains valid: rejection must come from the captured canonical revision.
        try permit.validateSynchronously()
        await #expect(throws: VaultError.self) {
            try await f.repository.publishPageSummary(snapshot, summary: result.summary,
                provenance: SummaryProvenance(provider: "OpenAI", model: result.provenance.model, generatedAt: Date(),
                    sourceRevision: snapshot.sourceRevision),
                validate: { try permit.validateSynchronously() })
        }
        let saved = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
        #expect(saved.body == edited.body && saved.title == edited.title)
        #expect(BlockDocumentCodec.decode(saved.body).aiSummary == nil)
        #expect(await f.transport.count == 1)
    }

    @Test func settingsMutationRejectsDisplayedLeaseFromEarlierSession() async throws {
        let f = try await VaultAcceptanceFixture(); defer { f.cleanup() }
        let displayed = try f.lease
        #expect(await f.model.closeVault())
        await f.model.open(f.root, create: false)
        #expect(try f.lease != displayed)
        #expect(throws: ExternalAIError.staleSession) {
            try f.model.setVaultAIConfiguration(.init(enabled: true, provider: .openAI), for: displayed)
        }
        #expect(f.model.activeVaultAIConfiguration == .init())
        #expect(await f.transport.count == 0)
    }
}
}
