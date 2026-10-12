import Foundation
import Synchronization
import Testing
@testable import ExternalAI
import VaultCore

private struct AuditAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws {}
}
private final class AuditKeychain: ExternalAIKeychain, Sendable {
    private let value = Mutex<Data?>(nil)
    func read() throws -> Data? { value.withLock { $0 } }
    func write(_ data: Data) throws { value.withLock { $0 = data } }
    func delete() throws { value.withLock { $0 = nil } }
}
private let auditResponse = Data(#"{"object":"response","status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Approved summary"}]}]}"#.utf8)
private actor AuditTransport: OpenAITransporting {
    private(set) var count = 0
    var beforeResume: (@Sendable () async throws -> Void)?
    var afterResume: (@Sendable () async throws -> Void)?
    let status: Int
    let body: Data
    init(status: Int = 200, body: Data = auditResponse) { self.status = status; self.body = body }
    func setBefore(_ hook: @escaping @Sendable () async throws -> Void) { beforeResume = hook }
    func setAfter(_ hook: @escaping @Sendable () async throws -> Void) { afterResume = hook }
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void, didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        try await beforeResume?()
        let dispatched = Mutex(false)
        try beforeDispatch { dispatched.withLock { $0 = true } }
        guard dispatched.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        didDispatch()
        count += 1
        try await afterResume?()
        return OpenAIHTTPResponse(statusCode: status, body: body)
    }
}
private struct AuditFixture {
    let gate: VaultAccessGate
    let broker: ExternalAICredentialBroker
    let manager: ExternalAISessionManager
    let gateway: ExternalAIGateway
    let request: ExternalAISummaryRequest
    init(transport: AuditTransport, now: @escaping @Sendable () -> Date = { Date() },
         activityRecorder: AIActivityRecorder? = nil, pricingCatalogue: AIUsagePricingCatalogue = .unpriced) async throws {
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-d02a-audit"), generation: 17)
        gate = VaultAccessGate(initialState: .open(session))
        broker = ExternalAICredentialBroker(keychain: AuditKeychain(), now: now)
        try await broker.store("synthetic-audit-credential-only")
        manager = ExternalAISessionManager(accessGate: gate, credentialBroker: broker, authenticator: AuditAuthenticator(), observeSystemEvents: false)
        gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: manager, accessGate: gate,
            transport: transport, activityRecorder: activityRecorder, pricingCatalogue: pricingCatalogue)
        request = try ExternalAISummaryRequest(authority: ExternalAIVaultAuthority(session: session), target: .page(UUID()), contentRevision: UUID(), content: "Private selected text")
    }
}

@Test func auditCredentialReplacementBeforeConnectionResumePreventsDispatch() async throws {
    let transport = AuditTransport(body: Data(#"{"object":"model","id":"gpt-4.1-mini"}"#.utf8))
    let f = try await AuditFixture(transport: transport)
    await transport.setBefore { try await f.broker.replace("synthetic-replacement-credential") }
    do { try await f.gateway.validateConnection(); Issue.record("Old credential dispatched after replacement") }
    catch { #expect([ExternalAIError.cancelled, .authorizationRevoked].contains(where: { $0 == error as? ExternalAIError })) }
    #expect(await transport.count == 0)
}

@Test func auditCredentialRemovalCancelsActiveConnectionExchange() async throws {
    let transport = AuditTransport(body: Data(#"{"object":"model","id":"gpt-4.1-mini"}"#.utf8))
    let f = try await AuditFixture(transport: transport)
    await transport.setAfter {
        try await f.broker.remove()
        #expect(Task.isCancelled)
    }
    await #expect(throws: ExternalAIError.cancelled) { try await f.gateway.validateConnection() }
    #expect(await transport.count == 1)
}

@Test(arguments: [false, true])
func auditCredentialRevocationAfterResponsePreservesUsageWithoutPublication(remove: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noema-revoked-activity-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteAIActivityStore(url: directory.appendingPathComponent("activity.sqlite"))
    let recorder = AIActivityRecorder(store: store)
    let price = try #require(AIUsagePrice(model: ExternalAIModelConfiguration.default.model,
        effectiveFrom: .distantPast, inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.5,
        outputUSDPerMillion: 8))
    let body = Data(#"{"object":"response","status":"completed","usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":30}},"output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Approved summary"}]}]}"#.utf8)
    let transport = AuditTransport(body: body)
    let f = try await AuditFixture(transport: transport, activityRecorder: recorder,
        pricingCatalogue: .init(version: "synthetic-test-v1", rates: [price]))
    await recorder.begin(id: f.request.id, vaultID: f.request.authority.vaultID,
        action: .summarizePage, executionMode: .userInvoked, provider: .openAI,
        modelID: f.gateway.configuration.model)
    await transport.setAfter {
        if remove { try await f.broker.remove() }
        else { try await f.broker.replace("synthetic-replacement-credential") }
        #expect(Task.isCancelled)
    }
    await #expect(throws: ExternalAIError.cancelled) {
        _ = try await f.gateway.summarizePage(f.request, consent: ExternalAIContentConsent(approving: f.request))
    }
    let record = try #require(try await store.query(AIActivityQuery()).first)
    #expect(record.requestCount == 1 && record.usage?.inputTokens == 100)
    #expect(record.usage?.outputTokens == 20 && record.usage?.cachedInputTokens == 30)
    #expect(record.estimatedCostUSD == 0.000315)
    // The caller owns finalization, and revocation must issue no publication capability.
    #expect(record.status == .running && record.outcome == .notApplicable)
    let model = await f.gateway.configuration.model
    let forged = try ExternalAISummaryResult(request: f.request, summary: "Approved summary",
        provenance: ExternalAIProvenance(model: model))
    await #expect(throws: ExternalAIError.authorizationRevoked) { try await f.gateway.publicationPermit(for: forged) }
    #expect(f.gate.registrySnapshot().activeCount == 0)
}

@Test func auditRevocationAfterTransientFailurePreventsRetry() async throws {
    let transport = AuditTransport(status: 503)
    let f = try await AuditFixture(transport: transport)
    await transport.setAfter { f.manager.revoke(reason: .screenLocked) }
    do {
        _ = try await f.gateway.summarizePage(f.request, consent: ExternalAIContentConsent(approving: f.request))
        Issue.record("Revoked transient failure retried")
    } catch { #expect(error as? ExternalAIError != nil) }
    #expect(await transport.count == 1)
    #expect(f.gate.registrySnapshot().activeCount == 0)
}

@Test func auditCallerCancellationBeforeDispatchAndLateResponseRejectsPublication() async throws {
    let transport = AuditTransport()
    let f = try await AuditFixture(transport: transport)
    await transport.setBefore { withUnsafeCurrentTask { $0?.cancel() } }
    await #expect(throws: ExternalAIError.cancelled) {
        _ = try await f.gateway.summarizePage(f.request, consent: ExternalAIContentConsent(approving: f.request))
    }
    #expect(await transport.count == 0)
    #expect(f.gate.registrySnapshot().activeCount == 0)
    let late = AuditTransport()
    let second = try await AuditFixture(transport: late)
    await late.setAfter { second.gate.updateState(.closed) }
    do {
        _ = try await second.gateway.summarizePage(second.request, consent: ExternalAIContentConsent(approving: second.request))
        Issue.record("Closed session returned a publishable result")
    } catch { #expect(error as? ExternalAIError != nil) }
    #expect(await late.count == 1)
}

@Test func auditForgedOrAlteredResultsNeverGetPublicationAuthority() async throws {
    let f = try await AuditFixture(transport: AuditTransport())
    let provenance = try ExternalAIProvenance(model: "gpt-4.1-mini")
    let unissued = try ExternalAISummaryResult(request: f.request, summary: "Forged summary", provenance: provenance)
    await #expect(throws: ExternalAIError.authorizationRevoked) { try await f.gateway.publicationPermit(for: unissued) }
    let issued = try await f.gateway.summarizePage(f.request, consent: ExternalAIContentConsent(approving: f.request))
    let altered = try ExternalAISummaryResult(request: f.request, summary: "Substituted summary", provenance: issued.provenance)
    await #expect(throws: ExternalAIError.authorizationRevoked) { try await f.gateway.validatePublication(of: altered) }
    let permit = try await f.gateway.publicationPermit(for: issued)
    try permit.validateSynchronously()
    try await f.broker.replace("synthetic-replacement-credential")
    #expect(throws: ExternalAIError.authorizationRevoked) { try permit.validateSynchronously() }
}

@Test func auditProviderDiagnosticsAreFiniteAndRedacted() throws {
    let marker = "synthetic-secret-vault-text-and-authorization"
    let errors: [any Error] = [NSError(domain: marker, code: 1, userInfo: [NSLocalizedDescriptionKey: marker]),
                  URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: marker]),
                  URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: marker])]
    for error in errors {
        let sanitizedError = sanitized(error)
        #expect(!sanitizedError.localizedDescription.contains(marker))
        #expect(!String(reflecting: sanitizedError).contains(marker))
    }
    for body in [Data(marker.utf8), Data(#"{"error":{"message":"synthetic-secret-vault-text-and-authorization"}}"#.utf8)] {
        #expect(throws: ExternalAIError.invalidResponse) { try ExternalAIGateway.summary(from: body) }
    }
}


private final class AuditCredentialClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    var now: Date { value.withLock { $0 } }
    func expire() { value.withLock { $0 = $0.addingTimeInterval(30 * 24 * 60 * 60) } }
}
@Test func auditCredentialExpiryAtDispatchRejectsWithoutTimerDelivery() async throws {
    for metadata in [false, true] {
        let clock = AuditCredentialClock()
        let transport = AuditTransport(body: metadata ? Data(#"{"object":"model","id":"gpt-4.1-mini"}"#.utf8) : auditResponse)
        let f = try await AuditFixture(transport: transport, now: { clock.now })
        try await f.broker.store("synthetic-locally-expiring-credential", policy: .thirtyDays)
        await transport.setBefore { clock.expire() }
        await #expect(throws: ExternalAIError.credentialExpired) {
            if metadata { try await f.gateway.validateConnection() }
            else { _ = try await f.gateway.summarizePage(f.request, consent: ExternalAIContentConsent(approving: f.request)) }
        }
        #expect(await transport.count == 0)
    }
}


@Test func auditCredentialExpiryAfterPermitIssuanceRejectsSynchronousPublication() async throws {
    let clock = AuditCredentialClock()
    let f = try await AuditFixture(transport: AuditTransport(), now: { clock.now })
    try await f.broker.store("synthetic-locally-expiring-credential", policy: .thirtyDays)
    let result = try await f.gateway.summarizePage(f.request, consent: ExternalAIContentConsent(approving: f.request))
    let permit = try await f.gateway.publicationPermit(for: result)
    clock.expire()
    #expect(throws: ExternalAIError.credentialExpired) { try permit.validateSynchronously() }
}
