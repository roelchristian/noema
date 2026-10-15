import Foundation
import Synchronization
import Testing
@testable import ExternalAI
import VaultCore

private final class GrantKeychain: ExternalAIKeychain, Sendable {
    private struct State { var data: Data?; var fail = false }
    private let state = Mutex(State())
    func read() throws -> Data? { state.withLock { $0.data } }
    func write(_ data: Data) throws {
        try state.withLock { guard !$0.fail else { throw ExternalAIError.credentialUnavailable }; $0.data = data }
    }
    func delete() throws {
        try state.withLock { guard !$0.fail else { throw ExternalAIError.credentialUnavailable }; $0.data = nil }
    }
    func failMutations(_ fail: Bool) { state.withLock { $0.fail = fail } }
}

private actor GrantAuthenticator: ExternalAIAuthenticating {
    private(set) var count = 0
    let held: Bool
    let cancelled: Bool
    private var pending: CheckedContinuation<Void, Never>?
    init(held: Bool = false, cancelled: Bool = false) { self.held = held; self.cancelled = cancelled }
    func authenticate() async throws {
        count += 1
        if held { await withCheckedContinuation { pending = $0 } }
        if cancelled { throw ExternalAIError.authenticationCancelled }
    }
    func waitUntilStarted() async { while count == 0 { await Task.yield() } }
    func release() { pending?.resume(); pending = nil }
}

private final class GrantClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { date.withLock { $0 } }
    func advance() { date.withLock { $0 += 61 } }
}

private actor GrantTransport: OpenAITransporting {
    private(set) var count = 0
    var before: (@Sendable () async throws -> Void)?
    var after: (@Sendable () async throws -> Void)?
    func setBefore(_ hook: @escaping @Sendable () async throws -> Void) { before = hook }
    func setAfter(_ hook: @escaping @Sendable () async throws -> Void) { after = hook }
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void,
                 didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        try await before?()
        let resumed = Mutex(false)
        try beforeDispatch { resumed.withLock { $0 = true } }
        guard resumed.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        count += 1; didDispatch()
        try await after?()
        let output = #"{"title":null,"summary":"Approved vault summary","classification":null,"body":null}"#
        let envelope: [String: Any] = ["object": "response", "status": "completed", "output": [
            ["type": "message", "role": "assistant", "status": "completed", "content": [
                ["type": "output_text", "text": output]]]]]
        return OpenAIHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: envelope))
    }
}

@MainActor private struct GrantFixture {
    let root: URL
    let domain: String
    let defaults: UserDefaults
    let session: VaultSession
    let gate: VaultAccessGate
    let repository: FileVaultRepository
    let broker: ExternalAICredentialBroker
    let keychain: GrantKeychain
    let authenticator: GrantAuthenticator
    let clock: GrantClock
    let grants: ExternalAIVaultGrants
    let transport: GrantTransport
    let gateway: ExternalAIGateway

    init(authenticator: GrantAuthenticator = GrantAuthenticator()) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-grants-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await FileVaultRepository.initializeCanonicalStaging(root: root)
        let manifest = try FileVaultRepository.inspectManifest(at: root)
        let session = VaultSession(vaultID: manifest.id, root: root, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let repository = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
        let domain = "noema-grants-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let broker = ExternalAICredentialBroker(keychain: GrantKeychain())
        try await broker.store("synthetic-vault-grant-key")
        let keychain = GrantKeychain(), clock = GrantClock(), transport = GrantTransport()
        let grants = ExternalAIVaultGrants(keychain: keychain, credentialBroker: broker, accessGate: gate,
            revocationDefaults: defaults, authenticator: authenticator, now: { clock.now })
        let interactive = ExternalAISessionManager(accessGate: gate, credentialBroker: broker,
            authenticator: authenticator, observeSystemEvents: false)
        self.root = root; self.session = session; self.gate = gate; self.repository = repository
        self.domain = domain; self.defaults = defaults; self.broker = broker; self.keychain = keychain
        self.authenticator = authenticator; self.clock = clock; self.grants = grants; self.transport = transport
        gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: interactive,
            accessGate: gate, transport: transport, activityRecorder: nil)
    }
    func rebuilt() -> ExternalAIVaultGrants {
        ExternalAIVaultGrants(keychain: keychain, credentialBroker: broker, accessGate: gate,
            revocationDefaults: defaults, authenticator: authenticator, now: { clock.now })
    }
    func request(action: ExternalAIAction = .summarizePage) throws -> ExternalAISummaryRequest {
        try ExternalAISummaryRequest(authority: .init(session: session), target: .page(UUID()),
            contentRevision: UUID(), content: "Selected vault content", action: action)
    }
    func cleanup() { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
}

@Suite("Durable vault grants and automatic gateway") @MainActor
struct ExternalAIVaultGrantTests {
    @Test func approvalPersistsAndTwoRequestsPublishWithOneApproval() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        #expect(try await !f.grants.hasGrant(for: f.session.lease))
        try await f.grants.approve(for: f.session.lease)
        let restored = f.rebuilt()
        #expect(try await restored.hasGrant(for: f.session.lease))
        var note = try await f.repository.create(title: "Human title", body: "Original content")
        var receiptIDs = Set<UUID>()
        for _ in 0..<2 {
            let snapshot = try await f.repository.pageSummarySnapshot(note)
            let request = try ExternalAISummaryRequest(authority: .init(session: f.session), target: .page(note.id),
                contentRevision: UUID(), content: "Original content")
            let authorization = try await restored.authorize(request)
            receiptIDs.insert(authorization.consent.id)
            let result = try await f.gateway.performAutomatic(request, authorization: authorization)
            let permit = try await f.gateway.publicationPermit(for: result)
            note = try await f.repository.publishPageSummary(snapshot, summary: result.summary,
                provenance: SummaryProvenance(provider: "OpenAI", model: result.provenance.model, generatedAt: Date()),
                validate: { try permit.validateSynchronously() })
            #expect(note.title == "Human title")
            await #expect(throws: ExternalAIError.consentAlreadyUsed) {
                try await f.gateway.performAutomatic(request, authorization: authorization)
            }
        }
        #expect(receiptIDs.count == 2)
        #expect(await f.authenticator.count == 1)
        #expect(await f.transport.count == 2)
        #expect(BlockDocumentCodec.decode(note.body).aiSummary?.text == "Approved vault summary")
    }

    @Test func savedPreferencesAndUnsupportedActionsCannotAuthorize() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        f.defaults.set(Data(#"{"version":1,"policy":"neverAsk"}"#.utf8), forKey: "openAIConsentPolicy.v1")
        await #expect(throws: ExternalAIError.consentRequired) { try await f.grants.authorize(f.request()) }
        try await f.grants.approve(for: f.session.lease)
        for action in [ExternalAIAction.composePage, .suggestTitle] {
            await #expect(throws: ExternalAIError.unsupportedAction) { try await f.grants.authorize(f.request(action: action)) }
        }
        #expect(await f.transport.count == 0)
    }

    @Test(arguments: [false, true]) func failedVaultOrGlobalRemovalStaysDeniedAfterReconstruction(global: Bool) async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let authority = try await f.grants.authorize(f.request())
        f.keychain.failMutations(true)
        #expect(throws: ExternalAIError.credentialUnavailable) { try f.grants.revoke(for: global ? nil : f.session.lease) }
        #expect(throws: ExternalAIError.self) { try authority.sessions.validateSynchronously(authority.capability) }
        let restored = f.rebuilt()
        #expect(try await !restored.hasGrant(for: f.session.lease))
        await #expect(throws: ExternalAIError.consentRequired) { try await restored.authorize(f.request()) }
        f.keychain.failMutations(false)
        try await restored.approve(for: f.session.lease)
        #expect(try await restored.hasGrant(for: f.session.lease))
    }

    @Test func copiedRootAndUnrelatedVaultCannotInheritApproval() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let copy = f.root.appendingPathComponent("copied-root")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for replacement in [VaultSession(vaultID: f.session.vaultID, root: copy, generation: 2),
                            VaultSession(vaultID: UUID(), root: f.root, generation: 3)] {
            f.gate.updateState(.open(replacement))
            #expect(try await !f.grants.hasGrant(for: replacement.lease))
        }
        let anotherDevice = ExternalAIVaultGrants(keychain: GrantKeychain(), credentialBroker: f.broker,
            accessGate: f.gate, revocationDefaults: f.defaults, authenticator: f.authenticator)
        #expect(try await !anotherDevice.hasGrant(for: try #require(f.gate.currentLease)))
    }

    @Test func credentialReplacementAndRemovalInvalidateApproval() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let authority = try await f.grants.authorize(f.request())
        try await f.broker.store("synthetic-replacement-key")
        #expect(try await !f.grants.hasGrant(for: f.session.lease))
        #expect(throws: ExternalAIError.self) { try authority.sessions.validateSynchronously(authority.capability) }
        try await f.grants.approve(for: f.session.lease)
        try await f.broker.remove()
        await #expect(throws: ExternalAIError.credentialMissing) { try await f.grants.hasGrant(for: f.session.lease) }
    }

    @Test func contentRevisionAndAuthorityStayBoundToOneRequest() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let request = try f.request(), authority = try await f.grants.authorize(request)
        for altered in [
            try ExternalAISummaryRequest(id: request.id, authority: request.authority, target: request.target,
                contentRevision: request.contentRevision, content: "Different content"),
            try ExternalAISummaryRequest(id: request.id, authority: request.authority, target: request.target,
                contentRevision: UUID(), content: request.content)] {
            await #expect(throws: ExternalAIError.consentRequired) { try await f.gateway.performAutomatic(altered, authorization: authority) }
        }
        #expect(await f.transport.count == 0)
        _ = try await f.gateway.performAutomatic(request, authorization: authority)
    }

    @Test func lockAndExpiryCancelRuntimeAuthority() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let authority = try await f.grants.authorize(f.request())
        let cancelled = Mutex(false)
        _ = try authority.sessions.registerCancellation(for: authority.capability) { cancelled.withLock { $0 = true } }
        f.clock.advance()
        #expect(throws: ExternalAIError.authorizationExpired) { try authority.sessions.validateSynchronously(authority.capability) }
        #expect(cancelled.withLock { $0 })
        let next = try await f.grants.authorize(f.request())
        f.gate.updateState(.locking(f.session))
        #expect(throws: ExternalAIError.self) { try next.sessions.validateSynchronously(next.capability) }
    }

    @Test func revocationBeforeDispatchAndAfterResponseRejectsPublication() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let grants = f.grants, lease = f.session.lease
        let request = try f.request(), authority = try await grants.authorize(request)
        await f.transport.setBefore { try await grants.revoke(for: lease) }
        await #expect(throws: ExternalAIError.self) { try await f.gateway.performAutomatic(request, authorization: authority) }
        #expect(await f.transport.count == 0)
        try await grants.approve(for: lease)
        let next = try f.request(), nextAuthority = try await grants.authorize(next)
        let clean = GrantTransport()
        let interactive = ExternalAISessionManager(accessGate: f.gate, credentialBroker: f.broker,
            authenticator: f.authenticator, observeSystemEvents: false)
        let gateway = ExternalAIGateway(credentialBroker: f.broker, sessionManager: interactive,
            accessGate: f.gate, transport: clean, activityRecorder: nil)
        let result = try await gateway.performAutomatic(next, authorization: nextAuthority)
        let permit = try await gateway.publicationPermit(for: result)
        try grants.revoke(for: lease)
        #expect(throws: ExternalAIError.self) { try permit.validateSynchronously() }
        await #expect(throws: ExternalAIError.self) { try await gateway.validatePublication(of: result) }
    }

    @Test(arguments: [false, true]) func pendingApprovalCannotSurviveRevokeOrVaultSwitch(switchVault: Bool) async throws {
        let auth = GrantAuthenticator(held: true)
        let f = try await GrantFixture(authenticator: auth); defer { f.cleanup() }
        let pending = Task { try await f.grants.approve(for: f.session.lease) }
        await auth.waitUntilStarted()
        if switchVault { f.gate.updateState(.open(VaultSession(vaultID: UUID(), root: f.root, generation: 2))) }
        else { try f.grants.revoke(for: f.session.lease) }
        await auth.release()
        await #expect(throws: ExternalAIError.self) { try await pending.value }
        #expect(await auth.count == 1)
    }

    @Test func lateProviderResponseCannotPublishAfterRevocation() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let grants = f.grants, lease = f.session.lease
        let request = try f.request(), authority = try await grants.authorize(request)
        await f.transport.setAfter { try await grants.revoke(for: lease) }
        await #expect(throws: ExternalAIError.self) {
            try await f.gateway.performAutomatic(request, authorization: authority)
        }
        #expect(await f.transport.count == 1)
    }

    @Test func revokedPermitRejectsCanonicalWriteAndPreservesPriorContent() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let note = try await f.repository.create(title: "Human title", body: "Preserved original")
        let snapshot = try await f.repository.pageSummarySnapshot(note)
        let request = try ExternalAISummaryRequest(authority: .init(session: f.session), target: .page(note.id),
            contentRevision: UUID(), content: "Preserved original")
        let authority = try await f.grants.authorize(request)
        let result = try await f.gateway.performAutomatic(request, authorization: authority)
        let permit = try await f.gateway.publicationPermit(for: result)
        try f.grants.revoke(for: f.session.lease)
        await #expect(throws: ExternalAIError.self) {
            try await f.repository.publishPageSummary(snapshot, summary: result.summary,
                provenance: SummaryProvenance(provider: "OpenAI", model: result.provenance.model, generatedAt: Date()),
                validate: { try permit.validateSynchronously() })
        }
        let saved = try #require(try await f.repository.scan().notes.first { $0.id == note.id })
        #expect(saved.body == note.body && saved.title == note.title)
    }

    @Test func materialScopeOrPolicyChangeAndMalformedGrantFailClosed() async throws {
        let f = try await GrantFixture(); defer { f.cleanup() }
        try await f.grants.approve(for: f.session.lease)
        let original = try #require(try f.keychain.read())
        for field in ["operations", "policyVersion"] {
            var record = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            var grants = try #require(record["grants"] as? [String: [String: Any]])
            let key = try #require(grants.keys.first)
            if field == "operations" { grants[key]?[field] = [String]() }
            else { grants[key]?[field] = 999 }
            record["grants"] = grants
            try f.keychain.write(JSONSerialization.data(withJSONObject: record))
            #expect(try await !f.grants.hasGrant(for: f.session.lease))
        }
        try f.keychain.write(Data("malformed".utf8))
        await #expect(throws: ExternalAIError.consentRequired) { try await f.grants.hasGrant(for: f.session.lease) }
    }

    @Test func cancelledApprovalCreatesNoGrant() async throws {
        let f = try await GrantFixture(authenticator: GrantAuthenticator(cancelled: true)); defer { f.cleanup() }
        await #expect(throws: ExternalAIError.authenticationCancelled) { try await f.grants.approve(for: f.session.lease) }
        #expect(try await !f.grants.hasGrant(for: f.session.lease))
    }
}
