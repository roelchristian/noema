import Foundation
import Synchronization
import Testing
@testable import ExternalAI
import VaultCore
@testable import noema

@Suite("Cloud consent disclosure policy")
struct CloudConsentPresentationTests {
    @Test
    func onlyAuthorizedExactLiveSessionStartsCompact() {
        let lease = VaultSessionLease(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/consent-policy"), generation: 1)
        let authority = ExternalAIVaultAuthority(lease: lease)
        for state in [ExternalAISessionState.unauthorized, .authorising, .expired, .revoked] {
            #expect(CloudConsentPresentation.resolve(sessionState: state, authority: authority,
                                                     currentLease: lease).previewInitiallyExpanded)
        }
        #expect(CloudConsentPresentation.resolve(sessionState: .authorized, authority: authority,
                                                 currentLease: lease) == .compact)
        let otherSession = VaultSessionLease(vaultID: lease.vaultID, root: lease.root, generation: lease.generation)
        let otherVault = VaultSessionLease(sessionID: lease.sessionID, vaultID: UUID(), root: lease.root,
                                           generation: lease.generation)
        let otherGeneration = VaultSessionLease(sessionID: lease.sessionID, vaultID: lease.vaultID,
                                                root: lease.root, generation: lease.generation + 1)
        for current in [otherSession, otherVault, otherGeneration, nil] {
            #expect(CloudConsentPresentation.resolve(sessionState: .authorized, authority: authority,
                                                     currentLease: current) == .expanded)
        }
    }

    @Test
    func liveIdleExpiryReopensFullDisclosureAndInspectionDoesNotRenewSession() throws {
        let f = try fixture()
        f.clock.advance(29 * 60)
        #expect(f.presentation == .compact)
        f.clock.advance(60)
        #expect(f.registry.currentState() == .expired)
        #expect(f.presentation == .expanded)
    }

    @Test
    func liveMaximumExpiryAndRevocationReopenFullDisclosure() throws {
        let f = try fixture()
        for _ in 0..<8 {
            f.clock.advance(29 * 60)
            try f.registry.validate(f.capability, activity: true)
        }
        #expect(f.presentation == .compact)
        f.clock.advance(8 * 60)
        #expect(f.registry.currentState() == .expired)
        #expect(f.presentation == .expanded)

        let revoked = try fixture()
        revoked.registry.revoke()
        #expect(revoked.presentation == .expanded)
        let replaced = try fixture()
        replaced.gate.updateState(.open(VaultSession(vaultID: replaced.lease.vaultID,
                                                     root: replaced.lease.root,
                                                     generation: replaced.lease.generation + 1)))
        #expect(replaced.presentation == .expanded)
    }

    @Test @MainActor
    func savedProviderConfigurationDoesNotAuthenticateOrCollapseDisclosure() async throws {
        let domain = "noema-consent-preferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("gpt-4.1-mini", forKey: ExternalAIService.modelPreferenceKey)
        let gate = VaultAccessGate()
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/consent-service"), generation: 1)
        gate.updateState(.open(session))
        let service = ExternalAIService(accessGate: gate, defaults: defaults)
        let authority = ExternalAIVaultAuthority(session: session)
        #expect(await service.consentPresentation(for: authority) == .expanded)
        #expect(await service.sessionManager.state == .unauthorized)
        service.revokeAuthorization()
        #expect(await service.consentPresentation(for: authority) == .expanded)
        #expect(await service.sessionManager.state == .revoked)
    }

    private struct Fixture {
        let clock: ConsentTestClock
        let gate: VaultAccessGate
        let lease: VaultSessionLease
        let registry: ExternalAIAuthorizationRegistry
        let capability: ExternalAICapability
        var presentation: CloudConsentPresentation {
            CloudConsentPresentation.resolve(sessionState: registry.currentState(),
                                               authority: ExternalAIVaultAuthority(lease: lease),
                                               currentLease: gate.currentLease)
        }
    }

    private func fixture() throws -> Fixture {
        let clock = ConsentTestClock()
        let gate = VaultAccessGate()
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/consent-expiry"), generation: 1)
        gate.updateState(.open(session))
        let registry = ExternalAIAuthorizationRegistry(gate: gate, policy: .default, now: { clock.now })
        let epoch = registry.begin(lease: session.lease)
        let capability = try registry.commit(epoch: epoch, authority: ExternalAIVaultAuthority(session: session),
                                             version: UUID())
        return Fixture(clock: clock, gate: gate, lease: session.lease, registry: registry, capability: capability)
    }
}

private final class ConsentTestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
