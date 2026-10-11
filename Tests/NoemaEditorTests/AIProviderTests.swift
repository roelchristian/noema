import Foundation
import Testing
@testable import noema

@Suite("AI provider policy and preferences")
struct AIProviderTests {
    private let available = AIProviderAvailability(onDevice: .available, openAI: .available)

    @Test(arguments: AIAction.allCases)
    func capabilityInventoryRestrictsCloudToConsentBoundSummaries(action: AIAction) {
        let local = AIProviderCapabilities.capability(for: action, provider: .onDevice)
        #expect(local.support == .supported)
        #expect(local.executions == [.automatic, .userInvoked])
        #expect(!local.requiresSubmissionConsent)
        let cloud = AIProviderCapabilities.capability(for: action, provider: .openAI)
        #expect(cloud.support == (action.isSummary ? .supported : .unauthorized))
        #expect(cloud.executions == [.userInvoked])
        #expect(cloud.requiresSubmissionConsent == action.isSummary)
        for proposed in AIProposedAction.allCases {
            #expect(AIProviderCapabilities.proposedActions[proposed] == .future)
        }
    }

    @Test
    func preferencesResolveGlobalOverrideAndTemporaryIntentWithoutMutation() {
        let settings = AIProviderSettings(defaultProvider: .openAI, overrides: [.summarizeSource: .specific(.onDevice)])
        #expect(resolve(.summarizePage, settings).provider == .openAI)
        #expect(resolve(.summarizeSource, settings).provider == .onDevice)
        #expect(resolve(.summarizeSource, settings, temporary: .openAI).provider == .openAI)
        #expect(settings.overrides == [.summarizeSource: .specific(.onDevice)])
        #expect(resolve(.suggestTitle, settings).eligibility == .ineligible(.unauthorizedAction))
        #expect(resolve(.suggestTitle, settings, temporary: .onDevice).isEligible)
    }

    @Test(arguments: AIAction.allCases)
    func automaticWorkflowIgnoresEveryCloudPreference(action: AIAction) {
        let settings = AIProviderSettings(defaultProvider: .openAI, overrides: [action: .specific(.openAI)])
        let result = AIProviderResolver.resolve(action: action, settings: settings, temporaryOverride: .openAI,
            execution: .automatic, availability: available)
        #expect(result.provider == .onDevice)
        #expect(result.isEligible)
        let unavailable = AIProviderResolver.resolve(action: action, settings: settings, temporaryOverride: .openAI,
            execution: .automatic,
            availability: .init(onDevice: .unavailable(.localDisabled), openAI: .available))
        #expect(unavailable.provider == .onDevice)
        #expect(unavailable.eligibility == .ineligible(.localDisabled))
    }

    @Test(arguments: [AIProviderUnavailableReason.localDisabled, .localModelUnavailable, .missingCredentials,
                      .vaultLocked, .authorizationExpired, .providerUnavailable])
    func unavailableProvidersRejectWithoutFallback(reason: AIProviderUnavailableReason) {
        for provider in AIProvider.allCases {
            let availability = AIProviderAvailability(
                onDevice: provider == .onDevice ? .unavailable(reason) : .available,
                openAI: provider == .openAI ? .unavailable(reason) : .available)
            let result = AIProviderResolver.resolve(action: .summarizePage,
                settings: .init(defaultProvider: provider), availability: availability)
            #expect(result.provider == provider)
            #expect(result.eligibility == .ineligible(reason))
            #expect(result.errorMessage == reason.errorMessage)
            #expect(!result.isEligible)
        }
    }

    @Test
    func unauthorizedOperationPrecedesInstalledProviderStatus() {
        let result = AIProviderResolver.resolve(action: .processSource,
            settings: .init(defaultProvider: .openAI),
            availability: .init(onDevice: .available, openAI: .unavailable(.missingCredentials)))
        #expect(result.provider == .openAI)
        #expect(result.eligibility == .ineligible(.unauthorizedAction))
    }

    @Test @MainActor
    func versionedPreferencesPersistIndependentlyAndResetOnlyOverrides() throws {
        let domain = "noema-ai-provider-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AIProviderPreferences(defaults: defaults)
        preferences.setDefaultProvider(.openAI)
        preferences.setOverride(.specific(.onDevice), for: .summarizeSource)
        preferences.setOverride(.specific(.onDevice), for: .suggestTitle)
        var reopened = AIProviderPreferences(defaults: defaults)
        #expect(reopened.settings == preferences.settings)
        #expect(reopened.settings.preferredProvider(for: .summarizeSource) == .onDevice)
        #expect(reopened.settings.preferredProvider(for: .summarizePage) == .openAI)
        preferences.setOverride(.inheritDefault, for: .summarizeSource)
        #expect(preferences.settings.overrides[.summarizeSource] == nil)
        #expect(preferences.settings.overrides[.suggestTitle] == .specific(.onDevice))
        preferences.resetOverrides()
        reopened = AIProviderPreferences(defaults: defaults)
        #expect(reopened.settings == .init(defaultProvider: .openAI))
        #expect(Set((defaults.persistentDomain(forName: domain) ?? [:]).keys) == [AIProviderPreferences.preferenceKey])
    }

    @Test @MainActor
    func migrationNeverChangesLegacyOptInOrInfersCloudIntent() throws {
        let domain = "noema-ai-provider-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for legacyEnabled in [false, true] {
            defaults.set(legacyEnabled, forKey: EditorPreferences.aiSummariesKey)
            defaults.set("gpt-4.1", forKey: ExternalAIService.modelPreferenceKey)
            let preferences = AIProviderPreferences(defaults: defaults)
            #expect(preferences.settings == AIProviderSettings())
            #expect(defaults.bool(forKey: EditorPreferences.aiSummariesKey) == legacyEnabled)
            #expect(defaults.object(forKey: AIProviderPreferences.preferenceKey) == nil)
            preferences.setDefaultProvider(.openAI)
            #expect(defaults.bool(forKey: EditorPreferences.aiSummariesKey) == legacyEnabled)
            defaults.removeObject(forKey: AIProviderPreferences.preferenceKey)
        }
    }

    @Test @MainActor
    func malformedAndFutureBlobsFailClosedWithoutRewritingEvidence() throws {
        let domain = "noema-ai-provider-corrupt-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for json in [
            "not JSON",
            #"{"version":2,"settings":{"defaultProvider":"openAI","overrides":[]}}"#,
            #"{"version":1,"settings":{"defaultProvider":"unknown","overrides":[]}}"#,
            #"{"version":1,"settings":{"defaultProvider":"openAI","overrides":["unknown",{"inheritDefault":{}}]}}"#,
            #"{"version":1}"#
        ] {
            let data = Data(json.utf8)
            defaults.set(data, forKey: AIProviderPreferences.preferenceKey)
            #expect(AIProviderPreferences(defaults: defaults).settings == AIProviderSettings())
            #expect(defaults.data(forKey: AIProviderPreferences.preferenceKey) == data)
        }
        defaults.set("wrong stored type", forKey: AIProviderPreferences.preferenceKey)
        #expect(AIProviderPreferences(defaults: defaults).settings == AIProviderSettings())
    }

    private func resolve(_ action: AIAction, _ settings: AIProviderSettings, temporary: AIProvider? = nil) -> AIProviderResolution {
        AIProviderResolver.resolve(action: action, settings: settings, temporaryOverride: temporary, availability: available)
    }
}
