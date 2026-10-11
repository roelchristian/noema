import Foundation
import NativeAuthentication

/// Authentication authorizes the external-AI session, independently of Keychain reads.
protocol ExternalAIAuthenticating: Sendable {
    func authenticate() async throws
}

struct LocalExternalAIAuthenticator: ExternalAIAuthenticating {
    private let native: any NativeAuthenticating

    init(native: any NativeAuthenticating = LocalNativeAuthenticator()) {
        self.native = native
    }

    func authenticate() async throws {
        do {
            try Task.checkCancellation()
            try await native.authenticate(for: .externalAISummary)
            try Task.checkCancellation()
        } catch NativeAuthenticationError.cancelled {
            throw ExternalAIError.authenticationCancelled
        } catch is CancellationError {
            throw ExternalAIError.authenticationCancelled
        } catch {
            throw ExternalAIError.authenticationFailed
        }
    }
}
