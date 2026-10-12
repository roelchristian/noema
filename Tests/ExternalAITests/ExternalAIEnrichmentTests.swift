import Foundation
import Testing
import VaultCore
@testable import ExternalAI

private let enrichmentJSON = #"{"title":"Computer Science","summary":"A concise summary.","classification":{"code":"QA76.889","level":"schedule","rationale":"Quantum computing subject"},"body":null}"#

@Test func enrichmentValidatesEveryArtifactAndPreservesRegenerationTitle() throws {
    let initial = try ExternalAIEnrichment.parse(enrichmentJSON, mode: .initial)
    #expect(initial.title == "Computer Science")
    #expect(initial.classification?.code == "QA76.889")
    #expect(initial.classification?.level == .schedule)
    #expect(initial.classification?.caption == "Quantum computers")
    let regenerated = try ExternalAIEnrichment.parse(enrichmentJSON, mode: .regenerate)
    #expect(regenerated.title == nil)
    #expect(regenerated.body == nil)
    #expect(regenerated.summary == initial.summary)
    #expect(!String(reflecting: initial).contains(initial.summary))
}

@Test func enrichmentRejectsMalformedUnverifiedOrMismatchedClassification() throws {
    for output in [
        enrichmentJSON.replacingOccurrences(of: "QA76.889", with: "QA76.123456"),
        enrichmentJSON.replacingOccurrences(of: "schedule", with: "subclass"),
        enrichmentJSON.replacingOccurrences(of: "\"body\":null", with: "\"body\":\"Unrequested body\""),
        enrichmentJSON.replacingOccurrences(of: "\"body\":null", with: "\"body\":null,\"tool\":\"send email\""),
        enrichmentJSON.replacingOccurrences(of: "\"summary\":\"A concise summary.\"", with: "\"summary\":42"),
        enrichmentJSON.replacingOccurrences(of: "\"title\":\"Computer Science\",", with: ""),
        enrichmentJSON.replacingOccurrences(of: "\"rationale\":\"Quantum computing subject\"", with: "\"rationale\":\"Quantum computing subject\",\"caption\":\"Forged caption\"")
    ] {
        #expect(throws: ExternalAIError.invalidResponse) { try ExternalAIEnrichment.parse(output, mode: .initial) }
    }
    let unavailable = try ExternalAIEnrichment.parse(#"{"title":null,"summary":"Valid summary","classification":null,"body":null}"#, mode: .regenerate)
    #expect(unavailable.classification == nil)
    #expect(throws: ExternalAIError.invalidResponse) {
        try ExternalAIEnrichment(title: nil, summary: "Summary", classification: nil, body: "Article", mode: .compose)
    }
    #expect(throws: ExternalAIError.invalidResponse) {
        try ExternalAIEnrichment(title: "Title", summary: "Summary", classification: nil,
                                 body: String(repeating: "🙂", count: ExternalAILimits.maximumBodyBytes / 4 + 1), mode: .compose)
    }
}

@Test func enrichmentSchemaIsStrictWithRequiredNullableFieldsAndClosedVocabulary() throws {
    let schema = try #require(JSONSerialization.jsonObject(with: Data(ExternalAIEnrichment.schemaJSON.utf8)) as? [String: Any])
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(Set(schema["required"] as? [String] ?? []) == ["title", "summary", "classification", "body"])
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    #expect(properties["title"]?["type"] as? [String] == ["string", "null"])
    #expect(properties["body"]?["type"] as? [String] == ["string", "null"])
    for mode in ExternalAIEnrichmentMode.allCases {
        #expect(ExternalAIEnrichment.instructions(mode: mode).contains("untrusted data"))
    }
    #expect(LCCClassificationVocabulary.suggestionCode(fromCallNumber: "QA76.889") == "QA76.889")
    #expect(LCCClassificationVocabulary.suggestionCode(fromCallNumber: "QA76.889.A1") == "QA")
    #expect(!LCCClassificationVocabulary.isAuthorized("QA999.123"))
}

@Test func enrichmentConsentBindsModeAndResultsBindClassificationAndBody() throws {
    let authority = ExternalAIVaultAuthority(lease: VaultSessionLease(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/enrichment-contract"), generation: 1))
    let request = try ExternalAISummaryRequest(authority: authority, target: .page(UUID()), contentRevision: UUID(), content: "Selected source", mode: .initial)
    let regeneration = try ExternalAISummaryRequest(id: request.id, authority: authority, target: request.target,
        contentRevision: request.contentRevision, content: request.content, mode: .regenerate)
    #expect(!ExternalAIContentConsent(approving: request).approves(regeneration))
    let provenance = try ExternalAIProvenance(model: "gpt-4.1-mini")
    let original = try ExternalAISummaryResult(request: request,
        enrichment: ExternalAIEnrichment.parse(enrichmentJSON, mode: .initial), provenance: provenance)
    let forged = try ExternalAISummaryResult(request: request,
        enrichment: ExternalAIEnrichment(title: original.title, summary: original.summary, classification: nil, mode: .initial), provenance: provenance)
    #expect(original.publicationDigest != forged.publicationDigest)
    #expect(throws: ExternalAIError.unsupportedAction) {
        try ExternalAISummaryRequest(authority: authority, target: .source(UUID()), contentRevision: UUID(), content: "Text", action: .composePage)
    }
}
