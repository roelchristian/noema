import Foundation
import Testing
import ExternalAI
import VaultCore
@testable import noema

@Suite("OpenAI submission consent policy")
struct OpenAIConsentPolicyTests {
    @Test @MainActor
    func malformedPreferencesFailClosedAndValidPreferencesPersist() throws {
        let domain = "noema-consent-malformed-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(OpenAIConsentPolicy.load(from: defaults) == .always)
        for value in ["not JSON", #"{"version":2,"policy":"neverAsk"}"#,
                      #"{"version":1,"policy":"unknown"}"#, #"{"policy":"neverAsk"}"#] {
            let data = Data(value.utf8)
            defaults.set(data, forKey: OpenAIConsentPolicy.preferenceKey)
            #expect(OpenAIConsentPolicy.load(from: defaults) == .always)
            #expect(defaults.data(forKey: OpenAIConsentPolicy.preferenceKey) == data)
        }
        for policy in OpenAIConsentPolicy.allCases {
            policy.persist(in: defaults)
            #expect(OpenAIConsentPolicy.load(from: defaults) == policy)
        }
    }

    @Test @MainActor
    func allPoliciesRequireExplicitActionsAndNeverAuthorizeAuthentication() async throws {
        let domain = "noema-consent-explicit-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/consent-explicit"), generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let service = ExternalAIService(accessGate: gate, defaults: defaults)
        let request = try request(for: session)
        for policy in OpenAIConsentPolicy.allCases {
            service.setConsentPolicy(policy)
            #expect(throws: ExternalAIError.consentRequired) {
                try service.requiresSubmissionConfirmation(for: request.authority, explicitlyInitiated: false)
            }
            #expect(throws: ExternalAIError.consentRequired) {
                try service.approveSubmission(request, explicitlyInitiated: false, userConfirmed: true)
            }
            #expect(try service.requiresSubmissionConfirmation(for: request.authority) == (policy != .neverAsk))
            if policy == .neverAsk {
                #expect(try service.approveSubmission(request, userConfirmed: false).approves(request))
            } else {
                #expect(throws: ExternalAIError.consentRequired) {
                    try service.approveSubmission(request, userConfirmed: false)
                }
            }
            #expect(await service.sessionManager.state == .unauthorized)
        }
    }

    @Test @MainActor
    func onceApprovalExpiresAcrossLockSwitchRelaunchAndPolicyChanges() throws {
        let domain = "noema-consent-session-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/consent-session"), generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let service = ExternalAIService(accessGate: gate, defaults: defaults)
        service.setConsentPolicy(.oncePerSession)
        let first = try request(for: session)
        #expect(try service.approveSubmission(first, userConfirmed: true).approves(first))
        let next = try request(for: session)
        let receipt = try service.approveSubmission(next, userConfirmed: false)
        #expect(receipt.approves(next))
        #expect(!receipt.approves(first))
        #expect(try !service.requiresSubmissionConfirmation(for: next.authority))
        #expect(try ExternalAIService(accessGate: gate, defaults: defaults)
            .requiresSubmissionConfirmation(for: next.authority))
        gate.updateState(.closed)
        gate.updateState(.open(session)) // Even identical lease ABA cannot restore session approval.
        #expect(try service.requiresSubmissionConfirmation(for: next.authority))
        _ = try service.approveSubmission(next, userConfirmed: true)
        let switched = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/other-vault"), generation: 2)
        gate.updateState(.open(switched))
        #expect(throws: ExternalAIError.vaultUnavailable) {
            try service.approveSubmission(next, userConfirmed: false)
        }
        let other = try request(for: switched)
        #expect(try service.requiresSubmissionConfirmation(for: other.authority))
        _ = try service.approveSubmission(other, userConfirmed: true)
        service.setConsentPolicy(.always)
        service.setConsentPolicy(.oncePerSession)
        #expect(try service.requiresSubmissionConfirmation(for: other.authority))
        service.setConsentPolicy(.neverAsk)
        gate.updateState(.closed)
        #expect(throws: ExternalAIError.vaultUnavailable) {
            try service.approveSubmission(other, userConfirmed: false)
        }
    }

    @Test
    func sessionGrantBindsEveryLeaseField() {
        let lease = VaultSessionLease(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/lease"), generation: 1)
        let consent = OpenAIConsentSession()
        consent.record(lease)
        #expect(consent.approves(lease))
        for other in [
            VaultSessionLease(vaultID: lease.vaultID, root: lease.root, generation: lease.generation),
            VaultSessionLease(sessionID: lease.sessionID, vaultID: UUID(), root: lease.root, generation: lease.generation),
            VaultSessionLease(sessionID: lease.sessionID, vaultID: lease.vaultID, root: URL(fileURLWithPath: "/tmp/other"), generation: lease.generation),
            VaultSessionLease(sessionID: lease.sessionID, vaultID: lease.vaultID, root: lease.root, generation: 2)
        ] { #expect(!consent.approves(other)) }
        consent.clear()
        #expect(!consent.approves(lease))
    }

    private func request(for session: VaultSession) throws -> ExternalAISummaryRequest {
        try ExternalAISummaryRequest(authority: ExternalAIVaultAuthority(session: session),
            target: .page(UUID()), contentRevision: UUID(), content: "Explicitly selected content.")
    }
}
