import ExternalAI
import VaultCore

/// Disclosure size is presentation only. Neither mode authorizes content submission;
/// each immutable request still needs explicit approval and a single-use consent receipt.
enum CloudConsentPresentation: Sendable, Equatable {
    case expanded
    case compact

    var previewInitiallyExpanded: Bool { self == .expanded }

    static func resolve(sessionState: ExternalAISessionState,
                        authority: ExternalAIVaultAuthority,
                        currentLease: VaultSessionLease?) -> Self {
        guard sessionState == .authorized, authority.matches(currentLease) else { return .expanded }
        return .compact
    }
}
