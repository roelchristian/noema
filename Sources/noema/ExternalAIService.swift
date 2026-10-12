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

    private let debugDiagnostics = ExternalAIDebugDiagnostics()
    @ObservationIgnored private var debugObservation: UUID?
    private var debugRefresh = 0

    let credentialBroker: ExternalAICredentialBroker
    let sessionManager: ExternalAISessionManager
    private(set) var gateway: ExternalAIGateway
    private(set) var configuration: ExternalAIModelConfiguration
    private(set) var credentialStatus: ExternalAICredentialStatus?
    private(set) var authorizationState: ExternalAISessionState = .unauthorized
    private(set) var consentPolicy: OpenAIConsentPolicy

    @ObservationIgnored private let accessGate: VaultAccessGate
    @ObservationIgnored private let activityRecorder: AIActivityRecorder
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let consentSession = OpenAIConsentSession()
    @ObservationIgnored private var consentObservation: UUID?

    init(accessGate: VaultAccessGate, defaults: UserDefaults = .standard, activityRecorder: AIActivityRecorder = .shared) {
        self.activityRecorder = activityRecorder
        self.accessGate = accessGate
        self.defaults = defaults
        consentPolicy = OpenAIConsentPolicy.load(from: defaults)
        let configuration = Self.loadConfiguration(from: defaults)
        self.configuration = configuration
        let broker = ExternalAICredentialBroker()
        credentialBroker = broker
        let sessions = ExternalAISessionManager(accessGate: accessGate, credentialBroker: broker)
        sessionManager = sessions
        gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: sessions,
                                   accessGate: accessGate, configuration: configuration, activityRecorder: activityRecorder,
                                   debugDiagnostics: debugDiagnostics)
    }

    deinit {
        if let debugObservation { accessGate.removeSessionInvalidator(debugObservation) }
        if let consentObservation { accessGate.removeSessionInvalidator(consentObservation) }
    }

    var canEnableDebugMode: Bool { _ = debugRefresh; return accessGate.currentLease != nil }
    var debugModeEnabled: Bool { _ = debugRefresh; return debugDiagnostics.isEnabled }
    var debugReport: String? { _ = debugRefresh; return debugDiagnostics.report }

    func setDebugMode(_ enabled: Bool) {
        debugDiagnostics.disable()
        if let debugObservation { accessGate.removeSessionInvalidator(debugObservation) }
        debugObservation = nil
        if enabled, let lease = accessGate.currentLease {
            debugDiagnostics.enable(for: lease)
            debugObservation = accessGate.registerSessionInvalidator(lease: lease) { [debugDiagnostics, weak self] in
                debugDiagnostics.disable()
                // Refresh visible Settings promptly without retaining response text in a task.
                Task { @MainActor [weak self] in self?.debugStateChanged() }
            }
        }
        debugRefresh += 1
    }

    private func debugStateChanged() { debugRefresh += 1 }
    func clearDebugReport() { debugDiagnostics.clear(); debugStateChanged() }

    func setConsentPolicy(_ policy: OpenAIConsentPolicy) {
        guard consentPolicy != policy else { return }
        clearConsentSession()
        policy.persist(in: defaults)
        consentPolicy = policy
    }

    /// Only explicit commands can use a policy grant. This inspection cannot mint consent,
    /// authenticate or extend authentication idle time.
    func requiresSubmissionConfirmation(for authority: ExternalAIVaultAuthority,
                                        explicitlyInitiated: Bool = true) throws -> Bool {
        let lease = try consentLease(for: authority, explicitlyInitiated: explicitlyInitiated)
        return try accessGate.withOpenSession(lease: lease, operation: "externalAIConsent") {
            switch consentPolicy {
            case .always: true
            case .oncePerSession: !consentSession.approves(lease)
            case .neverAsk: false
            }
        }
    }

    /// Called after the coordinator's revision/cancellation checks. The gateway independently
    /// authenticates and consumes this exact-request receipt once, even for Never ask.
    func approveSubmission(_ request: ExternalAISummaryRequest, explicitlyInitiated: Bool = true,
                           userConfirmed: Bool) throws -> ExternalAIContentConsent {
        try Task.checkCancellation()
        let lease = try consentLease(for: request.authority, explicitlyInitiated: explicitlyInitiated)
        let requiresConfirmation = try requiresSubmissionConfirmation(for: request.authority,
                                                                       explicitlyInitiated: explicitlyInitiated)
        guard userConfirmed || !requiresConfirmation else { throw ExternalAIError.consentRequired }
        if userConfirmed, consentPolicy == .oncePerSession {
            clearConsentSession()
            consentSession.record(lease)
            consentObservation = accessGate.registerSessionInvalidator(lease: lease) { [consentSession] in
                consentSession.clear()
            }
        }
        return try accessGate.withOpenSession(lease: lease, operation: "externalAIConsent") {
            // Recheck the policy inside the live gate barrier; an intervening lock cannot
            // convert a retired once-per-session grant into approval for another request.
            guard userConfirmed || consentPolicy == .neverAsk
                    || (consentPolicy == .oncePerSession && consentSession.approves(lease)) else {
                throw ExternalAIError.consentRequired
            }
            return ExternalAIContentConsent(approving: request)
        }
    }

    private func consentLease(for authority: ExternalAIVaultAuthority,
                              explicitlyInitiated: Bool) throws -> VaultSessionLease {
        guard explicitlyInitiated else { throw ExternalAIError.consentRequired }
        guard let lease = accessGate.currentLease, authority.matches(lease) else {
            clearConsentSession()
            throw ExternalAIError.vaultUnavailable
        }
        return lease
    }

    private func clearConsentSession() {
        consentSession.clear()
        if let consentObservation { accessGate.removeSessionInvalidator(consentObservation) }
        consentObservation = nil
    }

    static func loadConfiguration(from defaults: UserDefaults) -> ExternalAIModelConfiguration {
        let model = defaults.string(forKey: modelPreferenceKey) ?? ExternalAIModelConfiguration.default.model
        let effort = defaults.string(forKey: reasoningPreferenceKey)
            .flatMap(ExternalAIReasoningEffort.init(rawValue:)) ?? .low
        return (try? ExternalAIModelConfiguration(model: model, reasoningEffort: effort)) ?? .default
    }

    func refreshStatus() async {
        debugRefresh += 1
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
        clearConsentSession()
        configuration = selected
        gateway = ExternalAIGateway(credentialBroker: credentialBroker, sessionManager: sessionManager,
                                   accessGate: accessGate, configuration: selected, activityRecorder: activityRecorder,
                                   debugDiagnostics: debugDiagnostics)
        authorizationState = .revoked
    }

    /// Entry is transient: the view clears its masked field before invoking this operation.
    /// No entered key is retained in application state, preferences or error text.
    func saveCredential(_ enteredKey: String, thirtyDayPolicy: Bool) async throws {
        sessionManager.revoke(reason: .credentialChanged)
        clearConsentSession()
        defer { authorizationState = .revoked }
        try await credentialBroker.store(enteredKey, policy: thirtyDayPolicy ? .thirtyDays : .unlimited)
        await refreshStatus()
    }

    func removeCredential() async throws {
        sessionManager.revoke(reason: .credentialChanged)
        clearConsentSession()
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
        clearConsentSession()
        authorizationState = .revoked
    }

    func validateConnection() async throws {
        try await gateway.validateConnection()
        await refreshStatus()
    }
}
