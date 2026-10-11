import Foundation
import Testing
import VaultCore
@testable import ExternalAI

struct ExternalAIContractsTests {
    private func request(id: UUID = UUID(), content: String = "Selected content") throws -> ExternalAISummaryRequest {
        try ExternalAISummaryRequest(
            id: id,
            authority: ExternalAIVaultAuthority(lease: VaultSessionLease(
                vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/contracts"), generation: 1)),
            target: .page(UUID()), contentRevision: UUID(), content: content)
    }

    @Test func consentRequiresExactSnapshotEvenWhenIdentifiersAreReused() throws {
        let original = try request()
        let consent = ExternalAIContentConsent(approving: original)
        #expect(consent.approves(original))
        let edited = try ExternalAISummaryRequest(id: original.id, authority: original.authority,
            target: original.target, contentRevision: original.contentRevision, content: "Secret replacement")
        #expect(!consent.approves(edited))
        let replay = try ExternalAISummaryRequest(authority: original.authority,
            target: original.target, contentRevision: original.contentRevision, content: original.content)
        #expect(!consent.approves(replay))
    }

    @Test func authorityRequiresSessionUUIDVaultUUIDAndGeneration() {
        let lease = VaultSessionLease(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/contracts"), generation: 5)
        let authority = ExternalAIVaultAuthority(lease: lease)
        #expect(authority.matches(lease))
        #expect(!authority.matches(nil))
        #expect(!authority.matches(VaultSessionLease(sessionID: lease.sessionID, vaultID: lease.vaultID, root: lease.root, generation: 6)))
        #expect(!authority.matches(VaultSessionLease(vaultID: lease.vaultID, root: lease.root, generation: 5)))
        #expect(!authority.matches(VaultSessionLease(sessionID: lease.sessionID, vaultID: UUID(), root: lease.root, generation: 5)))
    }

    @Test func payloadLimitsMeasureUTF8BytesAndRejectWhitespace() throws {
        #expect(throws: ExternalAIError.emptyContent) { try request(content: " \n\t") }
        #expect(throws: ExternalAIError.payloadTooLarge) {
            try request(content: String(repeating: "é", count: ExternalAILimits.maximumContentBytes / 2 + 1))
        }
        #expect(try request(content: String(repeating: "a", count: ExternalAILimits.maximumContentBytes)).contentByteCount == ExternalAILimits.maximumContentBytes)
    }

    @Test func diagnosticRepresentationsRedactContentAndSummary() throws {
        let secret = "sensitive selected text"
        let input = try request(content: secret)
        let result = try ExternalAISummaryResult(request: input, summary: secret,
            provenance: ExternalAIProvenance(model: "gpt-4.1-mini"))
        #expect(!String(describing: input).contains(secret))
        #expect(!String(reflecting: input).contains(secret))
        #expect(!String(reflecting: result).contains(secret))
    }

    @Test func rejectsOversizedOrEmptySummaryAndUnsafeModel() throws {
        let input = try request()
        let provenance = try ExternalAIProvenance(model: "gpt-4.1-mini")
        #expect(throws: ExternalAIError.invalidResponse) {
            try ExternalAISummaryResult(request: input, summary: "\n", provenance: provenance)
        }
        #expect(throws: ExternalAIError.invalidResponse) {
            try ExternalAISummaryResult(request: input, summary: String(repeating: "a", count: ExternalAILimits.maximumSummaryBytes + 1), provenance: provenance)
        }
        #expect(throws: ExternalAIError.invalidConfiguration) { try ExternalAIProvenance(model: "model\nsecret") }
        #expect(throws: ExternalAIError.invalidConfiguration) { try ExternalAISessionPolicy(idleTimeout: .infinity) }
        #expect(throws: ExternalAIError.invalidConfiguration) { try ExternalAISessionPolicy(maximumLifetime: 24 * 60 * 60) }
        #expect(ExternalAISessionPolicy.default.idleTimeout == 1_800)
        #expect(ExternalAISessionPolicy.default.maximumLifetime == 14_400)
    }
}
