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
    let vaultGrants: ExternalAIVaultGrants
    private(set) var vaultGrantApproved = false
    private var vaultGrantLease: VaultSessionLease?
    private var vaultGrantCredentialVersion: UUID?
    private var grantStatusRevision = UUID()
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
    @ObservationIgnored private var beforeAutomaticProviderAvailability: (@MainActor () async -> Void)?

    init(accessGate: VaultAccessGate, defaults: UserDefaults = .standard, activityRecorder: AIActivityRecorder = .shared) {
        self.activityRecorder = activityRecorder
        self.accessGate = accessGate
        self.defaults = defaults
        consentPolicy = OpenAIConsentPolicy.load(from: defaults)
        let configuration = Self.loadConfiguration(from: defaults)
        self.configuration = configuration
        let broker = ExternalAICredentialBroker()
        credentialBroker = broker
        vaultGrants = ExternalAIVaultGrants(credentialBroker: broker, accessGate: accessGate)
        let sessions = ExternalAISessionManager(accessGate: accessGate, credentialBroker: broker)
        sessionManager = sessions
        gateway = ExternalAIGateway(credentialBroker: broker, sessionManager: sessions,
                                   accessGate: accessGate, configuration: configuration, activityRecorder: activityRecorder,
                                   debugDiagnostics: debugDiagnostics)
    }

    /// Internal composition seam: tests keep real policy, Settings mutation and gateway
    /// logic while supplying isolated security stores and a deterministic suspension.
    init(accessGate: VaultAccessGate, defaults: UserDefaults, activityRecorder: AIActivityRecorder,
         credentialBroker: ExternalAICredentialBroker, vaultGrants: ExternalAIVaultGrants,
         sessionManager: ExternalAISessionManager, gateway: ExternalAIGateway,
         beforeAutomaticProviderAvailability: (@MainActor () async -> Void)? = nil) {
        self.accessGate = accessGate
        self.defaults = defaults
        self.activityRecorder = activityRecorder
        self.credentialBroker = credentialBroker
        self.vaultGrants = vaultGrants
        self.sessionManager = sessionManager
        self.gateway = gateway
        self.beforeAutomaticProviderAvailability = beforeAutomaticProviderAvailability
        configuration = Self.loadConfiguration(from: defaults)
        consentPolicy = OpenAIConsentPolicy.load(from: defaults)
    }

    deinit {
        if let debugObservation { accessGate.removeSessionInvalidator(debugObservation) }
        if let consentObservation { accessGate.removeSessionInvalidator(consentObservation) }
    }

    var canEnableDebugMode: Bool { _ = debugRefresh; return accessGate.currentState.phase == .open }
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

    private func invalidateVaultGrantStatus() {
        grantStatusRevision = UUID()
        vaultGrantApproved = false
        vaultGrantLease = nil
        vaultGrantCredentialVersion = nil
    }

    func isVaultProcessingApproved(for lease: VaultSessionLease) -> Bool {
        vaultGrantApproved && vaultGrantLease == lease && accessGate.currentLease == lease
            && credentialStatus?.isAvailable == true && credentialStatus?.version == vaultGrantCredentialVersion
    }

    private static func providerStatus(_ status: ExternalAICredentialStatus?) -> AIProviderStatus {
        guard let status else { return .unavailable(.providerUnavailable) }
        switch status.presence {
        case .available: return .available
        case .missing: return .unavailable(.missingCredentials)
        case .expired, .malformed, .inaccessible: return .unavailable(.providerUnavailable)
        }
    }

    var openAIProviderStatus: AIProviderStatus { Self.providerStatus(credentialStatus) }

    var openAIReadinessDescription: String? {
        guard let status = credentialStatus else { return "Checking OpenAI connection…" }
        switch status.presence {
        case .available: return nil
        case .missing: return "Configure a key in OpenAI settings"
        case .expired: return "The saved OpenAI credential has expired"
        case .malformed: return "The saved OpenAI credential is invalid"
        case .inaccessible: return "The OpenAI credential is unavailable in Keychain"
        }
    }

    func refreshVaultGrant(for expectedLease: VaultSessionLease? = nil) async {
        guard !Task.isCancelled else { return }
        guard let lease = expectedLease ?? accessGate.currentLease, accessGate.currentLease == lease else { return }
        invalidateVaultGrantStatus()
        let revision = grantStatusRevision
        let status = await credentialBroker.status()
        let approved = (try? await vaultGrants.hasGrant(for: lease)) == true
        let currentStatus = await credentialBroker.status()
        guard !Task.isCancelled, revision == grantStatusRevision, accessGate.currentLease == lease,
              status == currentStatus else { return }
        credentialStatus = currentStatus
        vaultGrantApproved = approved
        vaultGrantLease = lease
        vaultGrantCredentialVersion = currentStatus.version
    }

    func approveVaultProcessing(for lease: VaultSessionLease) async throws {
        let policy = VaultAIConfigurationStore(defaults: defaults).configuration(for: lease.vaultID)
        guard policy.enabled, policy.provider == .openAI, accessGate.currentLease == lease else {
            throw ExternalAIError.consentRequired
        }
        try await vaultGrants.approve(for: lease)
        guard accessGate.currentLease == lease else { throw ExternalAIError.staleSession }
        await refreshVaultGrant(for: lease)
    }

    func revokeVaultProcessing(for lease: VaultSessionLease) throws {
        guard accessGate.currentLease == lease else { throw ExternalAIError.staleSession }
        invalidateVaultGrantStatus()
        try vaultGrants.revoke(for: lease)
    }

    /// Future AI.LIFE caller only: prepares exact-request authority without dispatching.
    func authorizeAutomaticSubmission(_ request: ExternalAISummaryRequest) async throws -> ExternalAIBackgroundAuthorization {
        guard let lease = accessGate.currentLease, request.authority.matches(lease) else { throw ExternalAIError.staleSession }
        let generation = vaultGrants.captureGeneration()
        let policy = VaultAIConfigurationStore(defaults: defaults).configuration(for: lease.vaultID)
        let action: AIAction
        switch request.action {
        case .summarizePage: action = .summarizePage
        case .summarizeSource: action = .summarizeSource
        case .suggestTitle: action = .suggestTitle
        case .lccClassification: action = .classifyLCC
        case .composePage: action = .composePage
        }
        let availability = await automaticProviderAvailability()
        try vaultGrants.validateGeneration(generation)
        guard accessGate.currentLease == lease else { throw ExternalAIError.staleSession }
        let preflight = VaultAIPolicyResolver.resolve(configuration: policy, action: action,
            execution: .automatic, availability: availability)
        switch preflight {
        case .cloudApprovalRequired: break // The security layer must validate the actual grant next.
        case .unavailable(.missingCredentials): throw ExternalAIError.credentialMissing
        case .unavailable: throw ExternalAIError.providerUnavailable
        case .disallowedOperation: throw ExternalAIError.unsupportedAction
        default: throw ExternalAIError.consentRequired
        }
        let authorization = try await vaultGrants.authorize(request, generation: generation)
        try vaultGrants.validateGeneration(generation)
        let currentAvailability = await automaticProviderAvailability()
        try vaultGrants.validateGeneration(generation)
        guard accessGate.currentLease == lease else { throw ExternalAIError.staleSession }
        let current = VaultAIConfigurationStore(defaults: defaults).configuration(for: lease.vaultID)
        guard current == policy else { throw ExternalAIError.authorizationRevoked }
        guard VaultAIPolicyResolver.resolveAutomatic(configuration: current, request: request,
            authorization: authorization, availability: currentAvailability) == .permitted(.openAI)
            else { throw ExternalAIError.authorizationRevoked }
        return authorization
    }

    private func automaticProviderAvailability() async -> AIProviderAvailability {
        await beforeAutomaticProviderAvailability?()
        let status = await credentialBroker.status()
        return .init(onDevice: OnDeviceSummary.unavailabilityReason == nil ? .available : .unavailable(.localModelUnavailable),
                     openAI: Self.providerStatus(status))
    }

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
        let status = await credentialBroker.status()
        if status != credentialStatus { invalidateVaultGrantStatus() }
        credentialStatus = status
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
        vaultGrants.invalidateRuntime()
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
        invalidateVaultGrantStatus()
        sessionManager.revoke(reason: .credentialChanged)
        clearConsentSession()
        defer { authorizationState = .revoked }
        // Interactive authority must be retired even when durable grant cleanup fails.
        try vaultGrants.revoke()
        try await credentialBroker.store(enteredKey, policy: thirtyDayPolicy ? .thirtyDays : .unlimited)
        await refreshStatus()
    }

    func removeCredential() async throws {
        invalidateVaultGrantStatus()
        sessionManager.revoke(reason: .credentialChanged)
        clearConsentSession()
        defer { authorizationState = .revoked }
        try vaultGrants.revoke()
        do {
            try await credentialBroker.remove()
        } catch {
            await refreshStatus()
            throw error
        }
        await refreshStatus()
    }

    func revokeAuthorization() {
        vaultGrants.invalidateRuntime()
        sessionManager.revoke()
        clearConsentSession()
        authorizationState = .revoked
    }

    func validateConnection() async throws {
        try await gateway.validateConnection()
        await refreshStatus()
    }
}
