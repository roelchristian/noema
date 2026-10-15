import Foundation
import ExternalAI
import Observation
import Synchronization
import VaultCore

/// Nonsecret processing intent. This value never constitutes cloud consent.
struct VaultAIConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var enabled = false
    var provider: AIProvider = .onDevice
    var configurationVersion = VaultAIConfiguration.currentVersion

    var isSupported: Bool { configurationVersion == Self.currentVersion }
}

enum VaultAIPolicyDecision: Equatable, Sendable {
    case permitted(AIProvider)
    case disabled
    case unsupportedPolicy
    case disallowedOperation
    case unavailable(AIProviderUnavailableReason)
    case cloudApprovalRequired
}

/// Resolves intent only. A permitted decision is not a gateway capability or receipt.
/// Automatic cloud requests additionally require an opaque grant-issued request authority.
enum VaultAIPolicyResolver {
    static func resolveAutomatic(configuration: VaultAIConfiguration, request: ExternalAISummaryRequest,
                                 authorization: ExternalAIBackgroundAuthorization,
                                 availability: AIProviderAvailability) -> VaultAIPolicyDecision {
        let action: AIAction
        switch request.action {
        case .summarizePage: action = .summarizePage
        case .summarizeSource: action = .summarizeSource
        case .suggestTitle: action = .suggestTitle
        case .lccClassification: action = .classifyLCC
        case .composePage: action = .composePage
        }
        return resolve(configuration: configuration, action: action, execution: .automatic,
            availability: availability, request: request, authorization: authorization)
    }

    static func resolve(configuration: VaultAIConfiguration, action: AIAction,
                        execution: AIProviderExecution, availability: AIProviderAvailability,
                        titleIsHumanAuthored: Bool = false,
                        request: ExternalAISummaryRequest? = nil,
                        authorization: ExternalAIBackgroundAuthorization? = nil) -> VaultAIPolicyDecision {
        guard configuration.isSupported else { return .unsupportedPolicy }
        if execution == .automatic {
            guard configuration.enabled else { return .disabled }
            guard action != .composePage,
                  !(action == .suggestTitle && titleIsHumanAuthored) else { return .disallowedOperation }
        }
        let provider = configuration.provider
        let capability = AIProviderCapabilities.capability(for: action, provider: provider)
        guard capability.support == .supported else { return .disallowedOperation }
        if case let .unavailable(reason) = availability.status(for: provider) {
            return .unavailable(reason)
        }
        if execution == .automatic && provider == .openAI {
            guard let request, let authorization,
                  request.action.rawValue == (action == .classifyLCC ? "lccClassification" : action.rawValue),
                  (try? authorization.validate(for: request)) != nil else { return .cloudApprovalRequired }
        }
        return .permitted(provider)
    }
}

extension VaultAIPolicyDecision {
    func providerResolution(for provider: AIProvider) -> AIProviderResolution {
        let reason: AIProviderUnavailableReason?
        switch self {
        case .permitted: reason = nil
        case .disabled: reason = .localDisabled
        case .unsupportedPolicy, .disallowedOperation, .cloudApprovalRequired: reason = .unauthorizedAction
        case .unavailable(let unavailable): reason = unavailable
        }
        return .init(provider: provider, eligibility: reason.map { .ineligible($0) } ?? .eligible)
    }
}

struct VaultAISettingsContext {
    let lease: VaultSessionLease
    let vaultName: String
    let configuration: VaultAIConfiguration
}

enum VaultAILocalAuthorityError: Error { case revoked }

/// The requested policy is already saved and runtime authority is revoked.
enum VaultAIConfigurationChangeError: Error { case cloudGrantCleanupFailed }

/// Synchronous epoch checks protect publication after an actor hop, including disable/enable ABA.
final class VaultAIPolicyEpochs: Sendable {
    private let epochs = Mutex<[UUID: UUID]>([:])
    func current(for vaultID: UUID) -> UUID {
        epochs.withLock { values in
            if let epoch = values[vaultID] { return epoch }
            let epoch = UUID(); values[vaultID] = epoch; return epoch
        }
    }
    func invalidate(_ vaultID: UUID) { epochs.withLock { $0[vaultID] = UUID() } }
    func validate(_ epoch: UUID, vaultID: UUID) throws {
        guard epochs.withLock({ $0[vaultID] == epoch }) else { throw VaultAILocalAuthorityError.revoked }
    }
}

/// App-local fallback: no manifest or schema changes, no content, credentials or cloud grants.
/// Preferences deliberately do not travel with the vault to another Mac.
@MainActor @Observable final class VaultAIConfigurationStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let epochs = VaultAIPolicyEpochs()
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func key(for vaultID: UUID) -> String { "vaultAIConfiguration.v1.\(vaultID.uuidString)" }

    func configuration(for vaultID: UUID) -> VaultAIConfiguration {
        _ = revision
        guard let data = defaults.data(forKey: Self.key(for: vaultID)),
              let policy = try? JSONDecoder().decode(VaultAIConfiguration.self, from: data),
              policy.isSupported else { return VaultAIConfiguration() }
        return policy
    }

    func set(_ configuration: VaultAIConfiguration, lease: VaultSessionLease, gate: VaultAccessGate) throws {
        guard configuration.isSupported else { throw VaultAILocalAuthorityError.revoked }
        let data = try JSONEncoder().encode(configuration)
        try gate.withOpenSession(lease: lease, operation: "vaultAIConfiguration") {
            // Revoke before publishing new preferences; re-enabling never restores an old epoch.
            epochs.invalidate(lease.vaultID)
        }
        defaults.set(data, forKey: Self.key(for: lease.vaultID))
        revision += 1
    }

    /// Captures policy epoch only; cloud request authority is minted separately for
    /// each exact snapshot by ExternalAIService and enforced again at its gateway.
    func processingPolicyValidation(lease: VaultSessionLease, gate: VaultAccessGate) throws -> @Sendable () throws -> Void {
        guard configuration(for: lease.vaultID).enabled else { throw VaultAILocalAuthorityError.revoked }
        let epochs = epochs
        let epoch = try gate.withOpenSession(lease: lease, operation: "aiProcessingPolicy") { epochs.current(for: lease.vaultID) }
        return {
            try Task.checkCancellation()
            try gate.withOpenSession(lease: lease, operation: "aiProcessingPolicy.validate") {
                try epochs.validate(epoch, vaultID: lease.vaultID)
            }
        }
    }

    /// Local-only request admission. No public preference can mint cloud authority.
    func localPublicationValidation(lease: VaultSessionLease, gate: VaultAccessGate) throws -> @Sendable () throws -> Void {
        let policy = configuration(for: lease.vaultID)
        guard policy.enabled, policy.provider == .onDevice else { throw VaultAILocalAuthorityError.revoked }
        let epochs = epochs
        let epoch = try gate.withOpenSession(lease: lease, operation: "vaultAILocalAdmission") {
            epochs.current(for: lease.vaultID)
        }
        return {
            try Task.checkCancellation()
            try gate.withOpenSession(lease: lease, operation: "vaultAILocalPublication") {
                try epochs.validate(epoch, vaultID: lease.vaultID)
            }
        }
    }
}
