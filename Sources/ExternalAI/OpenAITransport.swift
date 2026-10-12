import Foundation
import Synchronization
import VaultCore

/// Internal dependency injection boundary. No feature code can submit arbitrary requests.
protocol OpenAITransporting: Sendable {
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void, didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse
}

extension OpenAITransporting {
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void) async throws -> OpenAIHTTPResponse {
        try await perform(request, beforeDispatch: beforeDispatch, didDispatch: {})
    }
}

struct OpenAIHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

struct OpenAITransport: OpenAITransporting {
    // Internal URLProtocol seam exercises the actual session delegate without live network.
    private let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }
    func perform(_ request: URLRequest, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void, didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        let exchange = OpenAIHTTPExchange()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await exchange.execute(request, protocolClasses: protocolClasses, beforeDispatch: beforeDispatch, didDispatch: didDispatch)
        } onCancel: { exchange.cancel() }
    }
}

/// Each exchange has an ephemeral session: no cookie storage, URL cache, credential storage,
/// redirect following, or body diagnostics. Bytes are bounded as delegate chunks arrive.
private final class OpenAIHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<OpenAIHTTPResponse, Error>?
        var session: URLSession?
        var task: URLSessionDataTask?
        var response: HTTPURLResponse?
        var body = Data()
        var ended = false
        var cancelled = false
    }
    private let state = Mutex(State())

    func execute(_ request: URLRequest, protocolClasses: [AnyClass]?, beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void, didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = protocolClasses ?? configuration.protocolClasses
            configuration.timeoutIntervalForRequest = ExternalAILimits.requestTimeout
            configuration.timeoutIntervalForResource = ExternalAILimits.requestTimeout
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            let cancelled = state.withLock {
                $0.continuation = continuation
                $0.session = session
                $0.task = task
                return $0.cancelled
            }
            if cancelled { finish(.failure(ExternalAIError.cancelled)); return }
            do {
                try beforeDispatch { [self, task] in
                    // Synchronizes cancellation with resume. Lifecycle dispatch admission is
                    // held by the gateway around this closure, so locking cannot race resume.
                    state.withLock {
                        if !$0.ended && !$0.cancelled {
                            task.resume()
                            // This callback only updates bounded in-memory counters. It must not
                            // perform storage, async work, or acquire authorization locks.
                            didDispatch()
                        }
                    }
                }
            } catch { finish(.failure(sanitized(error))) }
        }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
        finish(.failure(ExternalAIError.cancelled))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(ExternalAIError.redirectRejected))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == dataTask.originalRequest?.url else {
            completionHandler(.cancel); finish(.failure(ExternalAIError.invalidResponse)); return
        }
        guard !(300..<400).contains(http.statusCode) else {
            completionHandler(.cancel); finish(.failure(ExternalAIError.redirectRejected)); return
        }
        guard response.expectedContentLength <= Int64(ExternalAILimits.maximumResponseBytes) else {
            completionHandler(.cancel); finish(.failure(ExternalAIError.responseTooLarge)); return
        }
        guard response.mimeType?.lowercased() == "application/json" else {
            completionHandler(.cancel); finish(.failure(ExternalAIError.invalidResponse)); return
        }
        state.withLock { $0.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = state.withLock {
            guard !$0.ended else { return false }
            guard data.count <= ExternalAILimits.maximumResponseBytes - $0.body.count else { return true }
            $0.body.append(data)
            return false
        }
        if overflow { finish(.failure(ExternalAIError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(sanitized(error))); return }
        let response: OpenAIHTTPResponse? = state.withLock {
            guard let response = $0.response else { return nil }
            return OpenAIHTTPResponse(statusCode: response.statusCode, body: $0.body)
        }
        if let response { finish(.success(response)) }
        else { finish(.failure(ExternalAIError.invalidResponse)) }
    }

    private func finish(_ result: Result<OpenAIHTTPResponse, Error>) {
        let completion = state.withLock {
            guard !$0.ended else { return (nil as CheckedContinuation<OpenAIHTTPResponse, Error>?, nil as URLSession?) }
            // Cancel may happen before execute installs a continuation.
            guard let continuation = $0.continuation else { return (nil, nil) }
            $0.ended = true
            $0.continuation = nil
            $0.task?.cancel()
            $0.task = nil
            let session = $0.session
            $0.session = nil
            $0.body.removeAll(keepingCapacity: false)
            return (continuation, session)
        }
        completion.1?.invalidateAndCancel()
        completion.0?.resume(with: result)
    }
}

/// Never return provider, URL, authentication header, or underlying platform error details.
func sanitized(_ error: any Error) -> ExternalAIError {
    if let error = error as? ExternalAIError { return error }
    if error is CancellationError || Task.isCancelled { return .cancelled }
    if error is VaultAccessError || error is VaultOperationAdmissionError { return .vaultUnavailable }
    if let error = error as? URLError {
        if error.code == .cancelled { return .cancelled }
        if error.code == .timedOut { return .timedOut }
    }
    return .networkUnavailable
}
