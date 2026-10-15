import Foundation
import Testing
import VaultCore
@testable import noema

@Suite("Vault AI configuration")
struct VaultAIConfigurationTests {
    private let available = AIProviderAvailability(onDevice: .available, openAI: .available)

    @Test func automaticPolicyFailsClosedAndNeverFallsBack() {
        #expect(VaultAIPolicyResolver.resolve(configuration: .init(), action: .summarizePage,
            execution: .automatic, availability: available) == .disabled)
        let cloud = VaultAIConfiguration(enabled: true, provider: .openAI)
        #expect(VaultAIPolicyResolver.resolve(configuration: cloud, action: .summarizeSource,
            execution: .automatic, availability: available) == .cloudApprovalRequired)
        #expect(VaultAIPolicyResolver.resolve(configuration: cloud, action: .summarizePage,
            execution: .automatic, availability: .init(onDevice: .available, openAI: .unavailable(.missingCredentials)))
                == .unavailable(.missingCredentials))
        #expect(VaultAIPolicyResolver.resolve(configuration: cloud, action: .composePage,
            execution: .automatic, availability: available) == .disallowedOperation)
        #expect(VaultAIPolicyResolver.resolve(configuration: cloud, action: .suggestTitle,
            execution: .automatic, availability: available, titleIsHumanAuthored: true) == .disallowedOperation)
        #expect(VaultAIPolicyResolver.resolve(configuration: .init(configurationVersion: 999), action: .summarizePage,
            execution: .automatic, availability: available) == .unsupportedPolicy)
        #expect(VaultAIPolicyResolver.resolve(configuration: .init(), action: .summarizePage,
            execution: .userInvoked, availability: available) == .permitted(.onDevice))
    }

    @Test @MainActor func persistenceIsolationCorruptionAndLocalRevocation() throws {
        let domain = "noema-vault-ai-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = VaultAIConfigurationStore(defaults: defaults)
        let vault = UUID(), otherVault = UUID()
        let session = VaultSession(vaultID: vault, root: URL(fileURLWithPath: "/tmp/vault-ai-fixture"), generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        #expect(store.configuration(for: vault) == .init())
        #expect(defaults.data(forKey: VaultAIConfigurationStore.key(for: vault)) == nil)
        let enabled = VaultAIConfiguration(enabled: true)
        try store.set(enabled, lease: session.lease, gate: gate)
        #expect(VaultAIConfigurationStore(defaults: defaults).configuration(for: vault) == enabled)
        #expect(store.configuration(for: otherVault) == .init())
        let validate = try store.localPublicationValidation(lease: session.lease, gate: gate)
        try validate()
        try store.set(.init(), lease: session.lease, gate: gate)
        try store.set(enabled, lease: session.lease, gate: gate)
        #expect(throws: VaultAILocalAuthorityError.self) { try validate() }
        let current = try store.localPublicationValidation(lease: session.lease, gate: gate)
        gate.updateState(.closed)
        #expect(throws: VaultAccessError.self) { try current() }
        let key = VaultAIConfigurationStore.key(for: vault)
        for data in [Data("broken".utf8), Data(#"{"enabled":true,"provider":"openAI","configurationVersion":999}"#.utf8)] {
            defaults.set(data, forKey: key)
            #expect(store.configuration(for: vault) == .init())
            #expect(defaults.data(forKey: key) == data)
        }
    }
}
