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

@Test func actionConsentCannotBeReusedForDifferentOperationOnSameSnapshot() throws {
    let summary = try ExternalAISummaryRequest(authority: ExternalAIVaultAuthority(lease: VaultSessionLease(
        vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/action-contract"), generation: 1)),
        target: .page(UUID()), contentRevision: UUID(), content: "Selected text")
    let consent = ExternalAIContentConsent(approving: summary)
    for action in [ExternalAIAction.suggestTitle, .lccClassification] {
        let changed = try ExternalAISummaryRequest(id: summary.id, authority: summary.authority,
            target: summary.target, contentRevision: summary.contentRevision, content: summary.content, action: action)
        #expect(!consent.approves(changed))
        #expect(ExternalAIContentConsent(approving: changed).approves(changed))
    }
    #expect(throws: ExternalAIError.unsupportedAction) {
        try ExternalAISummaryRequest(authority: summary.authority, target: .page(UUID()),
            contentRevision: UUID(), content: "Selected text", action: .summarizeSource)
    }
}

@Test func titleAndClassificationOutputsAreBoundedValidatedAndRedacted() throws {
    for title in ["\nInjected title", "Title: Topic", "Two\nLines", "# Heading", "<b>Topic</b>",
                  "**Topic**", "[Topic](https://example.com)", "A\u{0}Topic", "\"Topic\"",
                  String(repeating: "a", count: 121), "one two three four five six seven eight nine"] {
        #expect(throws: ExternalAIError.invalidResponse) { try ExternalAIOutputValidation.validateTitle(title) }
    }
    try ExternalAIOutputValidation.validateTitle("Sourdough Starter Maintenance")
    #expect(LCCClassificationVocabulary.suggestionCode(fromCallNumber: "QA76.9") == "QA")
    #expect(LCCClassificationVocabulary.suggestionCode(fromCallNumber: "ZZ999") == nil)
    let valid = try ExternalAIOutputValidation.lccSuggestion(from: #"{"code":"QA","rationale":"Mathematical subject."}"#)
    #expect(valid.code == "QA")
    #expect(!String(reflecting: valid).contains("Mathematical subject."))
    for output in [#"{"code":"ZZ","rationale":"Unknown"}"#, #"{"code":"QA76","rationale":"Full number"}"#,
                   #"{"code":"QA","rationale":""}"#, #"{"code":"QA","rationale":"<b>Topic</b>"}"#,
                   #"{"code":"QA","rationale":"Topic","extra":"secret"}"#, #"{"code":42,"rationale":"Topic"}"#,
                   #"{"code":"QA"}"#, #"```json {"code":"QA","rationale":"Topic"} ```"#] {
        #expect(throws: ExternalAIError.invalidResponse) { try ExternalAIOutputValidation.lccSuggestion(from: output) }
    }
    #expect(throws: ExternalAIError.invalidResponse) {
        try ExternalAILCCSuggestion(code: "QA", rationale: String(repeating: "🙂", count: 513))
    }
}
