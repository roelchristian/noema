import Foundation
import Observation
import ExternalAI
import VaultCore

/// One application composition shared by Settings and explicit summary actions. This object
/// exposes status and restricted operations, never a stored credential or credential header.
@MainActor @Observable
final class ExternalAIService {
    static let modelPreferenceKey = "externalAIModel"
    static let reasoningPreferenceKey = "externalAIReasoningEffort"

    let credentialBroker: ExternalAICredentialBroker
    let sessionManager: ExternalAISessionManager
    private(set) var gateway: ExternalAIGateway
    private(set) var configuration: ExternalAIModelConfiguration
    private(set) var credentialStatus: ExternalAICredentialStatus?
    private(set) var authorizationState: ExternalAISessionState = .unauthorized

    @ObservationIgnored private let accessGate: VaultAccessGate
    @ObservationIgnored private let defaults: UserDefaults

    init(accessGate: VaultAccessGate, defaults: UserDefaults = .standard) {
        self.accessGate = accessGate
        self.defaults = defaults
        let configuration = Self.loadConfiguration(from: defaults)
        self.configuration = configuration
        let broker = ExternalAICredentialBroker()
        credentialBroker = broker
        let sessions = ExternalAISessionManager(accessGate: accessGate, credentialBroker: broker)
        sessionManager = sessions
        gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: sessions,
                                   accessGate: accessGate, configuration: configuration)
    }

    static func loadConfiguration(from defaults: UserDefaults) -> ExternalAIModelConfiguration {
        let model = defaults.string(forKey: modelPreferenceKey) ?? ExternalAIModelConfiguration.default.model
        let effort = defaults.string(forKey: reasoningPreferenceKey)
            .flatMap(ExternalAIReasoningEffort.init(rawValue:)) ?? .low
        return (try? ExternalAIModelConfiguration(model: model, reasoningEffort: effort)) ?? .default
    }

    func refreshStatus() async {
        credentialStatus = await credentialBroker.status()
        authorizationState = await sessionManager.state
    }

    /// Inspect live expiry-aware authority without authenticating, renewing idle time,
    /// minting consent or submitting content. Cached Settings status is insufficient.
    func consentPresentation(for authority: ExternalAIVaultAuthority) async -> CloudConsentPresentation {
        let liveState = await sessionManager.state
        return CloudConsentPresentation.resolve(sessionState: liveState, authority: authority,
                                                currentLease: accessGate.currentLease)
    }

    func setModel(_ model: String) throws {
        let selected = try ExternalAIModelConfiguration(model: model, reasoningEffort: configuration.reasoningEffort)
        applyConfiguration(selected)
        defaults.set(selected.model, forKey: Self.modelPreferenceKey)
    }

    func setReasoningEffort(_ effort: ExternalAIReasoningEffort) {
        // The existing model was validated on construction; effort is a finite enum.
        guard let selected = try? ExternalAIModelConfiguration(model: configuration.model, reasoningEffort: effort) else { return }
        applyConfiguration(selected)
        defaults.set(effort.rawValue, forKey: Self.reasoningPreferenceKey)
    }

    private func applyConfiguration(_ selected: ExternalAIModelConfiguration) {
        guard selected != configuration else { return }
        // Revoke first so requests using the old gateway cannot dispatch or publish results.
        sessionManager.revoke()
        configuration = selected
        gateway = ExternalAIGateway(credentialBroker: credentialBroker, sessionManager: sessionManager,
                                   accessGate: accessGate, configuration: selected)
        authorizationState = .revoked
    }

    /// Entry is transient: the view clears its masked field before invoking this operation.
    /// No entered key is retained in application state, preferences or error text.
    func saveCredential(_ enteredKey: String, thirtyDayPolicy: Bool) async throws {
        sessionManager.revoke(reason: .credentialChanged)
        defer { authorizationState = .revoked }
        try await credentialBroker.store(enteredKey, policy: thirtyDayPolicy ? .thirtyDays : .unlimited)
        await refreshStatus()
    }

    func removeCredential() async throws {
        sessionManager.revoke(reason: .credentialChanged)
        defer { authorizationState = .revoked }
        do {
            try await credentialBroker.remove()
        } catch {
            await refreshStatus()
            throw error
        }
        await refreshStatus()
    }

    func revokeAuthorization() {
        sessionManager.revoke()
        authorizationState = .revoked
    }

    func validateConnection() async throws {
        try await gateway.validateConnection()
        await refreshStatus()
    }
}
