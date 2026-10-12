import Foundation
import Testing
import ExternalAI
import VaultCore
@testable import noema

@Suite("External AI settings configuration")
struct ExternalAISettingsTests {
    @Test @MainActor
    func preferencesStoreOnlyValidatedModelAndChangesRevokeAuthorization() async throws {
        let domain = "noema-external-ai-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = ExternalAIService(accessGate: VaultAccessGate(), defaults: defaults)
        let originalGateway = service.gateway
        #expect(service.configuration == .default)

        try service.setModel("gpt-4.1")

        #expect(service.configuration.model == "gpt-4.1")
        #expect(service.gateway !== originalGateway)
        #expect(service.authorizationState == .revoked)
        #expect(await service.sessionManager.state == .revoked)
        let stored = defaults.persistentDomain(forName: domain) ?? [:]
        #expect(Set(stored.keys) == [ExternalAIService.modelPreferenceKey])
        #expect(stored[ExternalAIService.modelPreferenceKey] as? String == "gpt-4.1")
        #expect(ExternalAIService.loadConfiguration(from: defaults).model == "gpt-4.1")
    }

    @Test @MainActor
    func malformedModelCannotReplaceGatewayOrPersistConfiguration() throws {
        let domain = "noema-external-ai-invalid-model-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = ExternalAIService(accessGate: VaultAccessGate(), defaults: defaults)
        let originalGateway = service.gateway
        for value in ["", "gpt-4.1/../../responses", "https://example.com", "model\nheader", String(repeating: "a", count: 101)] {
            #expect(throws: ExternalAIError.invalidConfiguration) { try service.setModel(value) }
            #expect(service.gateway === originalGateway)
            #expect(service.configuration == .default)
            #expect(defaults.object(forKey: ExternalAIService.modelPreferenceKey) == nil)
        }
    }

    @Test @MainActor
    func corruptedStoredModelFallsBackToFixedDefault() throws {
        let domain = "noema-external-ai-corrupt-model-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("other-host/model", forKey: ExternalAIService.modelPreferenceKey)
        let service = ExternalAIService(accessGate: VaultAccessGate(), defaults: defaults)
        #expect(service.configuration == .default)
        #expect(ExternalAIService.loadConfiguration(from: defaults) == .default)
    }

    @Test @MainActor
    func reasoningPreferencesPersistAcrossModelChangesAndRevokeOldGateway() async throws {
        let domain = "noema-external-ai-reasoning-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        // Existing installations with only a model preference keep their effective low effort.
        defaults.set("gpt-6-luna", forKey: ExternalAIService.modelPreferenceKey)
        let service = ExternalAIService(accessGate: VaultAccessGate(), defaults: defaults)
        #expect(service.configuration.reasoningEffort == .low)
        #expect(service.configuration.supportsReasoningEffort)
        for effort in [ExternalAIReasoningEffort.none, .medium, .low] {
            let oldGateway = service.gateway
            service.setReasoningEffort(effort)
            #expect(service.gateway !== oldGateway)
            #expect(await service.gateway.configuration.reasoningEffort == effort)
            #expect(service.authorizationState == .revoked)
            #expect(await service.sessionManager.state == .revoked)
            #expect(ExternalAIService.loadConfiguration(from: defaults).reasoningEffort == effort)
            let sameGateway = service.gateway
            service.setReasoningEffort(effort)
            #expect(service.gateway === sameGateway)
        }
        service.setReasoningEffort(.medium)
        try service.setModel("gpt-4.1-mini")
        #expect(!service.configuration.supportsReasoningEffort)
        #expect(service.configuration.reasoningEffort == .medium)
        try service.setModel("gpt-6-luna")
        #expect(ExternalAIService.loadConfiguration(from: defaults) == service.configuration)
        #expect(Set((defaults.persistentDomain(forName: domain) ?? [:]).keys)
                == [ExternalAIService.modelPreferenceKey, ExternalAIService.reasoningPreferenceKey])
    }

    @Test @MainActor
    func corruptedStoredReasoningFallsBackToLowWithoutDiscardingModel() throws {
        let domain = "noema-external-ai-corrupt-reasoning-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("gpt-6-luna", forKey: ExternalAIService.modelPreferenceKey)
        defaults.set("synthetic-unsupported-effort", forKey: ExternalAIService.reasoningPreferenceKey)
        let loaded = ExternalAIService.loadConfiguration(from: defaults)
        #expect(loaded.model == "gpt-6-luna")
        #expect(loaded.reasoningEffort == .low)
    }

    @Test(arguments: ["locking", "close", "switch", "reopen"]) @MainActor
    func debugModeIsTransientAndEndsWithTheVaultSession(transition: String) throws {
        let domain = "noema-external-ai-debug-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let gate = VaultAccessGate()
        let service = ExternalAIService(accessGate: gate, defaults: defaults)
        #expect(!service.debugModeEnabled)
        #expect(!service.canEnableDebugMode)
        service.setDebugMode(true)
        #expect(!service.debugModeEnabled)
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/debug-settings"), generation: 1)
        gate.updateState(.open(session))
        #expect(service.canEnableDebugMode)
        service.setDebugMode(true)
        #expect(service.debugModeEnabled)
        #expect(service.debugReport == nil)
        #expect((defaults.persistentDomain(forName: domain) ?? [:]).isEmpty)
        let relaunched = ExternalAIService(accessGate: gate, defaults: defaults)
        #expect(!relaunched.debugModeEnabled)
        service.setDebugMode(false)
        #expect(!service.debugModeEnabled)
        service.setDebugMode(true)
        switch transition {
        case "locking": gate.updateState(.locking(session))
        case "close": gate.updateState(.closed)
        case "switch": gate.updateState(.open(VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/debug-settings-other"), generation: 2)))
        default: gate.updateState(.open(VaultSession(vaultID: session.vaultID, root: session.root, generation: 2)))
        }
        #expect(service.canEnableDebugMode == (transition == "switch" || transition == "reopen"))
        #expect(!service.debugModeEnabled)
        #expect(service.debugReport == nil)
    }
}
