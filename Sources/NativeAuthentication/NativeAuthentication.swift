import Foundation

/// A single operation's prompt. Success has no reusable authorization or expiry semantics.
public enum NativeAuthenticationPurpose: Sendable, Equatable {
    case externalAISummary
    case openVault
    case unlockVault
    case changeVaultAccessPolicy

    var localizedReason: String {
        switch self {
        case .externalAISummary: "Authorize summaries of selected content with OpenAI"
        case .openVault: "Open this vault in Noema"
        case .unlockVault: "Unlock this vault in Noema"
        case .changeVaultAccessPolicy: "Change this vault's access authentication preference"
        }
    }
}

/// Bounded outcomes never expose native diagnostic text, credentials or an authentication context.
public enum NativeAuthenticationError: Error, Sendable, Equatable, LocalizedError {
    case cancelled
    case unavailable
    case failed

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Authentication was cancelled."
        case .unavailable: "Authentication is unavailable on this Mac."
        case .failed: "Authentication failed."
        }
    }
}

public protocol NativeAuthenticating: Sendable {
    /// Each invocation owns a fresh attempt; callers must bind its result to their own operation.
    func authenticate(for purpose: NativeAuthenticationPurpose) async throws
}
