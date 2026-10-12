import Foundation
import LocalAuthentication
import Synchronization

/// macOS device-owner authentication permits Touch ID and the system-password fallback.
/// No context is cached or returned, and a completed attempt is always invalidated.
public struct LocalNativeAuthenticator: NativeAuthenticating {
    private let makeContext: @Sendable () -> any NativeAuthenticationContext
    private let replyQueue: DispatchQueue

    public init() {
        makeContext = { SystemAuthenticationContext() }
        replyQueue = DispatchQueue(label: "Noema.NativeAuthentication.reply")
    }

    init(makeContext: @escaping @Sendable () -> any NativeAuthenticationContext,
         replyQueue: DispatchQueue = DispatchQueue(label: "Noema.NativeAuthentication.reply")) {
        self.makeContext = makeContext
        self.replyQueue = replyQueue
    }

    public func authenticate(for purpose: NativeAuthenticationPurpose) async throws {
        guard !Task.isCancelled else { throw NativeAuthenticationError.cancelled }
        let attempt = AuthenticationAttempt(context: makeContext(), replyQueue: replyQueue)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attempt.start(for: purpose, continuation: continuation)
            }
            guard !Task.isCancelled else { throw NativeAuthenticationError.cancelled }
        } onCancel: {
            attempt.finish(.failure(.cancelled))
        }
    }
}

/// Internal deterministic seam; evaluation starts synchronously and must return promptly.
/// Implementations may call their reply synchronously, repeatedly, late, or never.
protocol NativeAuthenticationContext: Sendable {
    func availabilityFailure() -> NativeAuthenticationError?
    func evaluate(reason: String, reply: @escaping @Sendable (Result<Void, NativeAuthenticationError>) -> Void)
    func invalidate()
}

private final class SystemAuthenticationContext: NativeAuthenticationContext, @unchecked Sendable {
    private let context = LAContext()

    init() {
        // Explicitly prevent biometric reuse from a previous authentication operation.
        context.touchIDAuthenticationAllowableReuseDuration = 0
    }

    func availabilityFailure() -> NativeAuthenticationError? {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return Self.classify(error, unavailable: true)
        }
        return nil
    }

    func evaluate(reason: String, reply: @escaping @Sendable (Result<Void, NativeAuthenticationError>) -> Void) {
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            reply(success ? .success(()) : .failure(Self.classify(error)))
        }
    }

    func invalidate() { context.invalidate() }

    static func classify(_ error: Error?, unavailable: Bool = false) -> NativeAuthenticationError {
        classifyNativeAuthenticationError(error, unavailable: unavailable)
    }
}

func classifyNativeAuthenticationError(_ error: Error?, unavailable: Bool = false) -> NativeAuthenticationError {
    if let error = error as NSError?, error.domain == LAErrorDomain,
       let code = LAError.Code(rawValue: error.code) {
        switch code {
        case .userCancel, .appCancel, .systemCancel: return .cancelled
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout,
             .passcodeNotSet, .notInteractive: return .unavailable
        default: break
        }
    }
    return unavailable ? .unavailable : .failed
}

private final class AuthenticationAttempt: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var outcome: Result<Void, NativeAuthenticationError>?
    }

    private let context: any NativeAuthenticationContext
    private let replyQueue: DispatchQueue
    private let state = Mutex(State())

    init(context: any NativeAuthenticationContext, replyQueue: DispatchQueue) {
        self.context = context
        self.replyQueue = replyQueue
    }

    func start(for purpose: NativeAuthenticationPurpose, continuation: CheckedContinuation<Void, Error>) {
        let prior = state.withLock { state -> Result<Void, NativeAuthenticationError>? in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        if let prior {
            continuation.resume(with: prior.mapError { $0 as Error })
            return
        }
        if let failure = context.availabilityFailure() {
            finish(.failure(failure))
            return
        }
        // Starting the prompt and cancelling are ordered under the same mutex. The reply
        // is deferred even for a synchronous native callback, so it cannot re-enter this
        // mutex or run a continuation while it is held.
        state.withLock { state in
            guard state.outcome == nil else { return }
            context.evaluate(reason: purpose.localizedReason) { [weak self] outcome in
                guard let self else { return }
                self.replyQueue.async { self.finish(outcome) }
            }
        }
    }

    func finish(_ outcome: Result<Void, NativeAuthenticationError>) {
        let completion = state.withLock { state -> (Bool, CheckedContinuation<Void, Error>?) in
            guard state.outcome == nil else { return (false, nil) }
            state.outcome = outcome
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        guard completion.0 else { return }
        context.invalidate()
        completion.1?.resume(with: outcome.mapError { $0 as Error })
    }
}
