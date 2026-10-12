import Foundation
import Synchronization
import Testing
@testable import ExternalAI

/// Per-request scenarios keep tests independent and intercept every URL, including a malicious
/// redirect destination. No test uses the real network or a Keychain/API credential.
private final class AuditURLProtocol: URLProtocol, @unchecked Sendable {
    static let redirectedLoads = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "evil.example" {
            Self.redirectedLoads.withLock { $0 += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let mode = request.value(forHTTPHeaderField: "X-Noema-Test") ?? "json"
        if mode == "redirect" {
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                          headerFields: ["Location": "https://evil.example/collect"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://evil.example/collect")!), redirectResponse: redirect)
            return
        }
        if mode == "error" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "synthetic-secret-http-error", code: 1))
            return
        }
        if mode == "unexpected" {
            client?.urlProtocol(self, didReceive: URLResponse(url: url, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = ["Content-Type": mode == "html" ? "text/html" : "application/json"]
        if mode == "advertisedOverflow" { headers["Content-Length"] = String(ExternalAILimits.maximumResponseBytes + 1) }
        let status = mode == "redirectStatus" ? 307 : 200
        let responseURL = mode == "wrongURL" ? URL(string: "https://evil.example/forged")! : url
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if mode == "chunkOverflow" || mode == "exactLimit" {
            // No Content-Length: prove limits apply while delegate bytes accumulate.
            let chunk = Data(repeating: 65, count: ExternalAILimits.maximumResponseBytes / 4)
            for _ in 0..<4 { client?.urlProtocol(self, didLoad: chunk) }
            if mode == "chunkOverflow" { client?.urlProtocol(self, didLoad: Data([65])) }
        } else { client?.urlProtocol(self, didLoad: Data("{}".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func auditHTTP(_ mode: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue(mode, forHTTPHeaderField: "X-Noema-Test")
    return request
}
private let auditResume: @Sendable (@Sendable () -> Void) throws -> Void = { $0() }

@Test func transportRejectsActualCrossHostRedirectBeforeDestinationLoads() async throws {
    let before = AuditURLProtocol.redirectedLoads.withLock { $0 }
    await #expect(throws: ExternalAIError.redirectRejected) {
        try await OpenAITransport(protocolClasses: [AuditURLProtocol.self]).perform(auditHTTP("redirect"), beforeDispatch: auditResume)
    }
    #expect(AuditURLProtocol.redirectedLoads.withLock { $0 } == before)
}

@Test func transportBoundsUnknownLengthChunkedResponseDuringReceipt() async throws {
    let transport = OpenAITransport(protocolClasses: [AuditURLProtocol.self])
    let accepted = try await transport.perform(auditHTTP("exactLimit"), beforeDispatch: auditResume)
    #expect(accepted.body.count == ExternalAILimits.maximumResponseBytes)
    await #expect(throws: ExternalAIError.responseTooLarge) {
        try await transport.perform(auditHTTP("chunkOverflow"), beforeDispatch: auditResume)
    }
    await #expect(throws: ExternalAIError.responseTooLarge) {
        try await transport.perform(auditHTTP("advertisedOverflow"), beforeDispatch: auditResume)
    }
}

@Test func transportRejectsUnexpectedTypesURLsStatusesAndSanitizesErrors() async throws {
    let transport = OpenAITransport(protocolClasses: [AuditURLProtocol.self])
    for mode in ["html", "unexpected", "wrongURL"] {
        await #expect(throws: ExternalAIError.invalidResponse) {
            try await transport.perform(auditHTTP(mode), beforeDispatch: auditResume)
        }
    }
    await #expect(throws: ExternalAIError.redirectRejected) {
        try await transport.perform(auditHTTP("redirectStatus"), beforeDispatch: auditResume)
    }
    await #expect(throws: ExternalAIError.networkUnavailable) {
        try await transport.perform(auditHTTP("error"), beforeDispatch: auditResume)
    }
}

@Test func transportAdmissionFailureCannotStartTheSessionTask() async throws {
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await OpenAITransport(protocolClasses: [AuditURLProtocol.self]).perform(auditHTTP("json")) { _ in
            throw ExternalAIError.authorizationRevoked
        }
    }
}

@Test func transportReportsOnlyActualResumesIncludingFailedResponses() async throws {
    let dispatches = Mutex(0)
    let observer: @Sendable () -> Void = { dispatches.withLock { $0 += 1 } }
    let transport = OpenAITransport(protocolClasses: [AuditURLProtocol.self])
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await transport.perform(auditHTTP("json"), beforeDispatch: { _ in
            throw ExternalAIError.authorizationRevoked
        }, didDispatch: observer)
    }
    #expect(dispatches.withLock { $0 } == 0)
    _ = try await transport.perform(auditHTTP("json"), beforeDispatch: auditResume, didDispatch: observer)
    #expect(dispatches.withLock { $0 } == 1)
    await #expect(throws: ExternalAIError.networkUnavailable) {
        try await transport.perform(auditHTTP("error"), beforeDispatch: auditResume, didDispatch: observer)
    }
    #expect(dispatches.withLock { $0 } == 2)
}

@Test func cancelledTransportDoesNotReportDispatch() async throws {
    let dispatches = Mutex(0)
    let worker = Task {
        while !Task.isCancelled { await Task.yield() }
        return try await OpenAITransport(protocolClasses: [AuditURLProtocol.self]).perform(auditHTTP("json"),
            beforeDispatch: auditResume, didDispatch: { dispatches.withLock { $0 += 1 } })
    }
    worker.cancel()
    await #expect(throws: CancellationError.self) { try await worker.value }
    #expect(dispatches.withLock { $0 } == 0)
}

@Test func cancellationAfterAdmissionBeforeResumeDoesNotReportDispatch() async throws {
    let dispatches = Mutex(0)
    let worker = Task {
        try await OpenAITransport(protocolClasses: [AuditURLProtocol.self]).perform(auditHTTP("json"),
            beforeDispatch: { resume in
                withUnsafeCurrentTask { $0?.cancel() }
                resume()
            }, didDispatch: { dispatches.withLock { $0 += 1 } })
    }
    await #expect(throws: ExternalAIError.cancelled) { try await worker.value }
    #expect(dispatches.withLock { $0 } == 0)
}
