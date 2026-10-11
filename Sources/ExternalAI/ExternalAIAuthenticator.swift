import Foundation
import LocalAuthentication

/// Authentication authorizes the external-AI session, independently of Keychain reads.
public protocol ExternalAIAuthenticating: Sendable {
    func authenticate() async throws
}

public struct LocalExternalAIAuthenticator: ExternalAIAuthenticating {
    public init() {}

    public func authenticate() async throws {
        let context = AuthenticationContext()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await context.authenticate()
            try Task.checkCancellation()
        } onCancel: {
            context.context.invalidate()
        }
    }
}

private final class AuthenticationContext: @unchecked Sendable {
    let context = LAContext()

    func authenticate() async throws {
        var availabilityError: NSError?
        // deviceOwnerAuthentication permits the ordinary macOS password fallback when biometrics
        // are unavailable or the user chooses it. No biometric-only policy or per-key prompt.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            throw ExternalAIError.authenticationFailed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "Authorize summaries of selected content with OpenAI") { success, error in
                if success {
                    continuation.resume()
                } else if let error = error as? LAError,
                          [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                    continuation.resume(throwing: ExternalAIError.authenticationCancelled)
                } else {
                    continuation.resume(throwing: ExternalAIError.authenticationFailed)
                }
            }
        }
    }
}
