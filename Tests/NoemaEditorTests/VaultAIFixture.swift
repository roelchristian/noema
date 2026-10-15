import Testing
import VaultCore
@testable import noema

/// Establishes persisted vault intent without touching the production Keychain.
/// Lifecycle/revocation behavior is exercised with injected security stores separately.
@MainActor func configureVaultAI(_ model: AppModel, provider: AIProvider = .onDevice, enabled: Bool = true) throws {
    let lease = try #require(model.sessionManager.accessGate.currentLease)
    try model.vaultAIConfigurationStore.set(.init(enabled: enabled, provider: provider),
        lease: lease, gate: model.sessionManager.accessGate)
    #expect(model.activeVaultAIConfiguration == .init(enabled: enabled, provider: provider))
}
