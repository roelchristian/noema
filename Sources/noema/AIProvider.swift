import Foundation
import Observation

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case onDevice
    case openAI

    var id: Self { self }
    var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .openAI: "OpenAI"
        }
    }
}

enum AIAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case summarizePage
    case summarizeSource
    case suggestTitle
    case classifyLCC
    case processSource

    var id: Self { self }
    var isSummary: Bool { self == .summarizePage || self == .summarizeSource }
    /// Page and source requests retain separate destinations but share one preference.
    var preferenceAction: AIAction { self == .summarizeSource ? .summarizePage : self }
    static let configurableActions: [AIAction] = [.summarizePage, .suggestTitle, .classifyLCC]
    var displayName: String {
        switch self {
        case .summarizePage: "Summarisation"
        case .summarizeSource: "Source summaries"
        case .suggestTitle: "Title suggestions"
        case .classifyLCC: "LCC classification"
        case .processSource: "Source processing"
        }
    }
}

enum AIProviderExecution: String, Codable, Sendable {
    case userInvoked
    case automatic
}

enum AIProviderPreference: Codable, Hashable, Sendable {
    case inheritDefault
    case specific(AIProvider)
}

struct AIProviderSettings: Codable, Equatable, Sendable {
    var defaultProvider: AIProvider = .onDevice
    var overrides: [AIAction: AIProviderPreference] = [:]

    func preferredProvider(for action: AIAction) -> AIProvider {
        if action == .processSource { return .onDevice }
        if case let .specific(provider) = overrides[action.preferenceAction] { return provider }
        return defaultProvider
    }
}

/// Stores processing intent only. Legacy local opt-in and credential/consent authority
/// remain independent; configuring a model or key cannot migrate a user to cloud AI.
@MainActor @Observable final class AIProviderPreferences {
    static let preferenceKey = "aiProviderSettings.v1"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var settings: AIProviderSettings

    /// The former page choice wins if both legacy summary choices exist. Otherwise
    /// preserve the source choice. This migration touches intent only, never artifacts.
    private static func consolidated(_ original: AIProviderSettings) -> AIProviderSettings {
        var updated = original
        let summary = original.overrides[.summarizePage] ?? original.overrides[.summarizeSource]
        updated.overrides.removeValue(forKey: .summarizeSource)
        updated.overrides.removeValue(forKey: .processSource)
        if let summary, summary != .inheritDefault { updated.overrides[.summarizePage] = summary }
        else { updated.overrides.removeValue(forKey: .summarizePage) }
        return updated
    }

    private struct StoredSettings: Codable {
        let version: Int
        let settings: AIProviderSettings
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.preferenceKey),
           let stored = try? JSONDecoder().decode(StoredSettings.self, from: data),
           (1...2).contains(stored.version) {
            settings = Self.consolidated(stored.settings)
            if stored.version == 1,
               let migrated = try? JSONEncoder().encode(StoredSettings(version: 2, settings: settings)) {
                defaults.set(migrated, forKey: Self.preferenceKey)
            }
        } else {
            // Absence, corruption and a future schema all fail closed to local intent.
            // Do not rewrite the saved blob merely by opening Settings.
            settings = AIProviderSettings()
        }
    }

    func setDefaultProvider(_ provider: AIProvider) {
        var updated = settings
        updated.defaultProvider = provider
        persist(updated)
    }

    func setOverride(_ preference: AIProviderPreference, for action: AIAction) {
        guard AIAction.configurableActions.contains(action.preferenceAction) else { return }
        let action = action.preferenceAction
        var updated = settings
        if preference == .inheritDefault {
            updated.overrides.removeValue(forKey: action)
        } else {
            updated.overrides[action] = preference
        }
        persist(updated)
    }

    func resetOverrides() {
        var updated = settings
        updated.overrides.removeAll()
        persist(updated)
    }

    private func persist(_ updated: AIProviderSettings) {
        guard updated != settings,
              let data = try? JSONEncoder().encode(StoredSettings(version: 2, settings: updated)) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
        settings = updated
    }
}

enum AIProviderCapabilitySupport: Equatable, Sendable {
    case supported
    case unsupported
    case unauthorized
    case future
}

enum AIActionInput: Equatable, Sendable {
    case selectedPageText
    case selectedSourceText
    case pageOrSourceText
}

enum AIActionDestination: Equatable, Sendable {
    case pageSummary
    case sourceSummary
    case pageOrSourceTitle
    case pageOrSourceClassification
    case sourceMetadataOrNewPage
}

struct AIProviderCapability: Sendable {
    let support: AIProviderCapabilitySupport
    let input: AIActionInput
    let destination: AIActionDestination
    let executions: Set<AIProviderExecution>
    let requiresSubmissionConsent: Bool
}

enum AIProposedAction: String, CaseIterable, Sendable {
    case suggestTags
    case writingAssistance
    case extractInformation
}

/// The allowlist mirrors existing implementations, rather than granting authority.
/// In particular, OpenAI eligibility still requires ExternalAIGateway's exact-text
/// consent, live authorization and conditional-publication checks for each request.
enum AIProviderCapabilities {
    static func capability(for action: AIAction, provider: AIProvider) -> AIProviderCapability {
        let input: AIActionInput
        let destination: AIActionDestination
        switch action {
        case .summarizePage: (input, destination) = (.selectedPageText, .pageSummary)
        case .summarizeSource: (input, destination) = (.selectedSourceText, .sourceSummary)
        case .suggestTitle: (input, destination) = (.pageOrSourceText, .pageOrSourceTitle)
        case .classifyLCC: (input, destination) = (.pageOrSourceText, .pageOrSourceClassification)
        case .processSource: (input, destination) = (.selectedSourceText, .sourceMetadataOrNewPage)
        }
        let supportsCloud = action.isSummary || action == .suggestTitle || action == .classifyLCC
        return AIProviderCapability(
            support: provider == .onDevice || supportsCloud ? .supported : .unauthorized,
            input: input, destination: destination,
            executions: provider == .onDevice ? [.userInvoked, .automatic] : [.userInvoked],
            requiresSubmissionConsent: provider == .openAI && supportsCloud
        )
    }

    // These proposed features have no existing transaction and are not AIAction cases.
    // Topic web research is also outside processSource: its existing explicit local
    // workflow includes external web fetching but no external model submission.
    static let proposedActions: [AIProposedAction: AIProviderCapabilitySupport] = [
        .suggestTags: .future, .writingAssistance: .future, .extractInformation: .future
    ]
}

enum AIProviderUnavailableReason: Equatable, Sendable {
    case localDisabled
    case localModelUnavailable
    case missingCredentials
    case vaultLocked
    case authorizationExpired
    case providerUnavailable
    case unsupportedAction
    case unauthorizedAction
    case futureAction

    var errorMessage: String {
        switch self {
        case .localDisabled: "Enable on-device AI in Intelligence settings to use this provider."
        case .localModelUnavailable: "The on-device model is unavailable. Check Apple Intelligence in System Settings or choose another supported provider."
        case .missingCredentials: "Configure an OpenAI API key in Intelligence settings, then try again."
        case .vaultLocked: "Unlock the vault before using AI."
        case .authorizationExpired: "OpenAI authorization expired. Authenticate and approve a new request."
        case .providerUnavailable: "The selected provider is unavailable. Try again or choose another provider."
        case .unsupportedAction: "The selected provider does not support this action. Choose a supported provider in Intelligence settings."
        case .unauthorizedAction: "This action is not authorized for OpenAI. Choose On-device in Intelligence settings."
        case .futureAction: "This AI action is not available yet."
        }
    }
}

enum AIProviderStatus: Equatable, Sendable {
    case available
    case unavailable(AIProviderUnavailableReason)
}

struct AIProviderAvailability: Equatable, Sendable {
    var onDevice: AIProviderStatus
    var openAI: AIProviderStatus

    func status(for provider: AIProvider) -> AIProviderStatus {
        provider == .onDevice ? onDevice : openAI
    }
}

enum AIProviderEligibility: Equatable, Sendable {
    case eligible
    case ineligible(AIProviderUnavailableReason)
}

struct AIProviderResolution: Equatable, Sendable {
    let provider: AIProvider
    let eligibility: AIProviderEligibility

    var isEligible: Bool { eligibility == .eligible }
    var errorMessage: String? {
        if case let .ineligible(reason) = eligibility { return reason.errorMessage }
        return nil
    }
}

enum AIProviderResolver {
    static func resolve(
        action: AIAction, settings: AIProviderSettings,
        temporaryOverride: AIProvider? = nil,
        execution: AIProviderExecution = .userInvoked,
        availability: AIProviderAvailability
    ) -> AIProviderResolution {
        // No preference, override or configured key may authorize cloud automation.
        let provider: AIProvider = execution == .automatic ? .onDevice
            : temporaryOverride ?? settings.preferredProvider(for: action)
        let capability = AIProviderCapabilities.capability(for: action, provider: provider)
        let reason: AIProviderUnavailableReason?
        switch capability.support {
        case .unsupported: reason = .unsupportedAction
        case .unauthorized: reason = .unauthorizedAction
        case .future: reason = .futureAction
        case .supported:
            if !capability.executions.contains(execution) {
                reason = .unsupportedAction
            } else if case let .unavailable(unavailable) = availability.status(for: provider) {
                reason = unavailable
            } else {
                reason = nil
            }
        }
        return AIProviderResolution(provider: provider, eligibility: reason.map { .ineligible($0) } ?? .eligible)
    }
}
