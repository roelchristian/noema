import Foundation
import Testing
import VaultCore
@testable import noema

@Suite("Read-only classification presentation")
struct LCCMetadataPresentationTests {
    @Test
    func specificCodeUsesLocalCaptionAndOffersAIProvenance() {
        let provenance = SummaryProvenance(provider: "openAI", model: "configured-model", generatedAt: Date())
        let classification = LCCClassification(code: "QA76", level: .schedule,
            caption: "Untrusted saved caption", provenance: provenance)
        let metadata = LCCMetadataPresentation(classification: classification,
            legacyCode: "Q", legacyProvenance: nil)
        #expect(metadata.code == "QA76")
        #expect(metadata.caption == "Computer science: general works")
        #expect(metadata.detail.contains("OpenAI · configured-model"))
        #expect(!metadata.detail.contains("Untrusted"))
    }

    @Test
    func legacyManualFullCallNumberIsPreservedWithoutClaimingAIOrigin() {
        let metadata = LCCMetadataPresentation(classification: nil,
            legacyCode: "QA76.73.S95", legacyProvenance: nil)
        #expect(metadata.code == "QA76.73.S95")
        #expect(metadata.caption == nil)
        #expect(metadata.detail.contains("Origin unspecified"))
        #expect(!metadata.detail.contains("AI-generated"))
        #expect(LCCMetadataPresentation(classification: nil, legacyCode: nil,
            legacyProvenance: nil).code == "None")
    }
}
