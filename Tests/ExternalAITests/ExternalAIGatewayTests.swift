import Foundation
import Synchronization
import Testing
@testable import ExternalAI
import VaultCore

private struct GatewayAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws {}
}
private final class GatewayKeychain: ExternalAIKeychain, @unchecked Sendable {
    private let data = Mutex<Data?>(nil)
    func read() throws -> Data? { data.withLock { $0 } }
    func write(_ value: Data) throws { data.withLock { $0 = value } }
    func delete() throws { data.withLock { $0 = nil } }
}
private let validResponse = Data(#"{"object":"response","status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"A concise summary."}]}]}"#.utf8)

private actor GatewayMockTransport: OpenAITransporting {
    var requests: [URLRequest] = []
    var responses: [OpenAIHTTPResponse]
    let onDispatch: (@Sendable () -> Void)?
    init(statuses: [Int] = [200], body: Data = validResponse, onDispatch: (@Sendable () -> Void)? = nil) {
        responses = statuses.map { OpenAIHTTPResponse(statusCode: $0, body: body) }
        self.onDispatch = onDispatch
    }
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void) async throws -> OpenAIHTTPResponse {
        onDispatch?()
        let resumed = Mutex(false)
        try beforeDispatch { resumed.withLock { $0 = true } }
        guard resumed.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        requests.append(request)
        return responses.count > 1 ? responses.removeFirst() : responses[0]
    }
}
private struct GatewayFixture {
    let session: VaultSession
    let gate: VaultAccessGate
    let broker: ExternalAICredentialBroker
    let manager: ExternalAISessionManager
    let gateway: ExternalAIGateway
    init(transport: GatewayMockTransport, gate: VaultAccessGate? = nil, session: VaultSession? = nil) async throws {
        self.session = session ?? VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/gateway-test"), generation: 4)
        self.gate = gate ?? VaultAccessGate(initialState: .open(self.session))
        broker = ExternalAICredentialBroker(keychain: GatewayKeychain())
        try await broker.store("synthetic-gateway-key-for-tests")
        manager = ExternalAISessionManager(accessGate: self.gate, credentialBroker: broker,
                                         authenticator: GatewayAuthenticator(), observeSystemEvents: false)
        gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: manager,
                                  accessGate: self.gate, transport: transport)
    }
    func request(content: String = "selected document text", target: ExternalAISummaryTarget = .page(UUID())) throws -> ExternalAISummaryRequest {
        try ExternalAISummaryRequest(authority: ExternalAIVaultAuthority(session: session), target: target,
                                     contentRevision: UUID(), content: content)
    }
}

@Test func gatewaySendsOnlyExactTextFixedInstructionAndNoStore() async throws {
    let mock = GatewayMockTransport()
    let f = try await GatewayFixture(transport: mock)
    let request = try f.request()
    let result = try await f.gateway.summarizePage(request, consent: ExternalAIContentConsent(approving: request))
    #expect(result.summary == "A concise summary.")
    #expect(result.authority == request.authority && result.contentRevision == request.contentRevision)
    let requests = await mock.requests
    #expect(requests.count == 1)
    let sent = try #require(requests.first)
    #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(sent.httpMethod == "POST")
    let body = try #require(sent.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(object.keys) == ["model", "instructions", "input", "store", "max_output_tokens"])
    #expect(object["store"] as? Bool == false)
    #expect(object["input"] as? String == request.content)
    #expect(!String(decoding: body, as: UTF8.self).contains(request.authority.vaultID.uuidString))
    #expect(f.gate.registrySnapshot().activeCount == 0)
    try await f.gateway.validatePublication(of: result)
    f.manager.revoke()
    await #expect(throws: ExternalAIError.authorizationRevoked) { try await f.gateway.validatePublication(of: result) }
}

@Test func gatewayConsentMismatchAndReplayNeverDispatch() async throws {
    let mock = GatewayMockTransport()
    let f = try await GatewayFixture(transport: mock)
    let request = try f.request()
    let original = ExternalAIContentConsent(approving: request)
    let altered = try ExternalAISummaryRequest(id: request.id, authority: request.authority, target: request.target,
                                              contentRevision: request.contentRevision, content: "substituted text")
    await #expect(throws: ExternalAIError.consentRequired) { try await f.gateway.summarizePage(altered, consent: original) }
    #expect(await mock.requests.isEmpty)
    _ = try await f.gateway.summarizePage(request, consent: original)
    await #expect(throws: ExternalAIError.consentAlreadyUsed) { try await f.gateway.summarizePage(request, consent: original) }
    await #expect(throws: ExternalAIError.consentAlreadyUsed) {
        try await f.gateway.summarizePage(request, consent: ExternalAIContentConsent(approving: request))
    }
    #expect(await mock.requests.count == 1)
}

@Test func gatewayRejectsWrongActionAndLockedAuthority() async throws {
    let mock = GatewayMockTransport()
    let f = try await GatewayFixture(transport: mock)
    let source = try f.request(target: .source(UUID()))
    await #expect(throws: ExternalAIError.unsupportedAction) {
        try await f.gateway.summarizePage(source, consent: ExternalAIContentConsent(approving: source))
    }
    f.gate.updateState(.locking(f.session))
    await #expect(throws: ExternalAIError.vaultUnavailable) {
        try await f.gateway.summarizeSource(source, consent: ExternalAIContentConsent(approving: source))
    }
    #expect(await mock.requests.isEmpty)
}

@Test func gatewayLockImmediatelyBeforeResumeRejectsDispatch() async throws {
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/gateway-race"), generation: 8)
    let gate = VaultAccessGate(initialState: .open(session))
    let mock = GatewayMockTransport(onDispatch: { gate.updateState(.locking(session)) })
    let f = try await GatewayFixture(transport: mock, gate: gate, session: session)
    let request = try f.request()
    do {
        _ = try await f.gateway.summarizePage(request, consent: ExternalAIContentConsent(approving: request))
        Issue.record("Lock race must reject the request")
    } catch { #expect(error as? ExternalAIError != nil) }
    #expect(await mock.requests.isEmpty)
    #expect(gate.registrySnapshot().activeCount == 0)
}

@Test func gatewayRetryIsBoundedAndPermanentFailuresDoNotRetry() async throws {
    let mock = GatewayMockTransport(statuses: [503, 200])
    let f = try await GatewayFixture(transport: mock)
    let request = try f.request()
    _ = try await f.gateway.summarizePage(request, consent: ExternalAIContentConsent(approving: request))
    #expect(await mock.requests.count == 2)
    for status in [401, 403, 400, 302, 503] {
        let failing = GatewayMockTransport(statuses: [status])
        let denied = try await GatewayFixture(transport: failing)
        let request = try denied.request()
        do {
            _ = try await denied.gateway.summarizePage(request, consent: ExternalAIContentConsent(approving: request))
            Issue.record("Failure status must be rejected")
        } catch { #expect(error as? ExternalAIError != nil) }
        #expect(await failing.requests.count == (status == 503 ? 2 : 1))
    }
}

@Test func gatewayRejectsMalformedOversizedRefusedAndIncompleteOutput() throws {
    for body in [Data("not-json".utf8),
                 Data(#"{"object":"response","status":"incomplete","output":[]}"#.utf8),
                 Data(#"{"object":"response","status":"completed","output":[{"type":"function_call"}]}"#.utf8),
                 Data(#"{"object":"response","status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"refusal"}]}]}"#.utf8)] {
        #expect(throws: ExternalAIError.invalidResponse) { try ExternalAIGateway.summary(from: body) }
    }
    #expect(throws: ExternalAIError.responseTooLarge) {
        try ExternalAIGateway.summary(from: Data(repeating: 65, count: ExternalAILimits.maximumResponseBytes + 1))
    }
    let object: [String: Any] = ["object": "response", "status": "completed", "output": [
        ["type": "message", "role": "assistant", "status": "completed", "content": [
            ["type": "output_text", "text": String(repeating: "a", count: ExternalAILimits.maximumSummaryBytes + 1)]]]]]
    let body = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ExternalAIError.responseTooLarge) { try ExternalAIGateway.summary(from: body) }
}

@Test func gatewayConnectionValidationUsesNoVaultContent() async throws {
    let mock = GatewayMockTransport(body: Data(#"{"object":"model","id":"gpt-4.1-mini"}"#.utf8))
    let f = try await GatewayFixture(transport: mock)
    f.gate.updateState(.closed)
    try await f.gateway.validateConnection()
    let requests = await mock.requests
    let request = try #require(requests.first)
    #expect(request.httpMethod == "GET" && request.httpBody == nil)
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/models/gpt-4.1-mini")
    #expect(await f.manager.state == .unauthorized)
}

@Test func gatewayModelRejectsURLsUnicodeAndExcessiveIdentifiers() throws {
    for model in ["", ".", "..", "sk-synthetic-key-for-tests", "../responses", "https://evil.example", "model?key=secret", "😀", String(repeating: "a", count: 101)] {
        #expect(throws: ExternalAIError.invalidConfiguration) { try ExternalAIModelConfiguration(model: model) }
    }
    #expect(try ExternalAIModelConfiguration(model: "gpt-4.1-mini").model == "gpt-4.1-mini")
}
