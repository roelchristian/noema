import Foundation
import Testing
import VaultCore
@testable import noema

@Suite("Meaning search presentation")
struct MeaningSearchPresentationTests {
    @Test func returnSubmitsUnsubmittedMeaningInsteadOfOpeningLexicalFallback() {
        for status: SemanticSearchStatus in [.idle, .needsSubmission, .declined, .unavailable("Unavailable"), .failed("Failed")] {
            #expect(ToolbarSearchKeyboardPolicy.submitAction(
                quickOpen: false, retrievalMode: .meaning,
                semanticStatus: status, hasDisclosure: false) == .submitMeaning)
        }
        #expect(ToolbarSearchKeyboardPolicy.submitAction(
            quickOpen: false, retrievalMode: .meaning,
            semanticStatus: .completed, hasDisclosure: false) == .openResult)
    }

    @Test func returnCannotApproveOrRepeatInFlightMeaning() {
        for status: SemanticSearchStatus in [.preparing, .searching] {
            #expect(ToolbarSearchKeyboardPolicy.submitAction(
                quickOpen: false, retrievalMode: .meaning,
                semanticStatus: status, hasDisclosure: false) == .none)
        }
        #expect(ToolbarSearchKeyboardPolicy.submitAction(
            quickOpen: false, retrievalMode: .meaning,
            semanticStatus: .awaitingApproval, hasDisclosure: true) == .none)
    }

    @Test func keywordsAndQuickOpenKeepReturnNavigation() {
        #expect(ToolbarSearchKeyboardPolicy.submitAction(
            quickOpen: false, retrievalMode: .keywords,
            semanticStatus: .needsSubmission, hasDisclosure: false) == .openResult)
        #expect(ToolbarSearchKeyboardPolicy.submitAction(
            quickOpen: true, retrievalMode: .meaning,
            semanticStatus: .needsSubmission, hasDisclosure: false) == .openResult)
    }

    @Test func previewUsesValidatedPageLocatorAndTruthfulProvenance() throws {
        let id = UUID(), block = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString, "title": "Related page", "aliases": [], "tags": [], "inlineTags": [],
            "createdAt": "2026-10-12T00:00:00Z", "updatedAt": "2026-10-12T00:00:00Z",
            "body": "", "relativePath": "Pages/Related.md", "contentHash": "fixture"
        ])
        let note = try JSONDecoder().decode(NoteRecord.self, from: data)
        var results = SidebarSearchResults(query: "concept", pages: [note], pageExcerpts: [id: "Current passage"])
        results.pageBlocks[id] = block
        results.relevance["page:\(id)"] = .meaning
        let row = try #require(ToolbarSearchRow.preview(results).first)
        #expect(row.blockID == block)
        #expect(row.relevance == "Related passage")
        #expect(row.excerpt == "Current passage")
        results.pageBlocks = [:]
        results.relevance = [:]
        let lexical = try #require(ToolbarSearchRow.preview(results).first)
        #expect(lexical.blockID == nil)
        #expect(lexical.relevance == nil)
    }

    @Test func sourcePreviewKeepsDocumentNavigationAndBlockEvidenceUsesFullIdentity() throws {
        let sourceID = UUID(), pageID = UUID(), blockID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": sourceID.uuidString, "title": "Related source", "capturedAt": "2026-10-12T00:00:00Z",
            "originalFilename": "fixture.txt", "sha256": "fixture", "storedFilename": "fixture.txt"
        ])
        let source = SourceRecord(metadata: try JSONDecoder().decode(SourceMetadata.self, from: data), body: "")
        let block = SemanticBlockHit(pageID: pageID, blockID: blockID, pageTitle: "Page",
                                     semantic: "claim", preview: "Current block")
        var results = SidebarSearchResults(sources: [source], blocks: [block])
        results.relevance["source:\(sourceID)"] = .both
        results.relevance["block:\(block.id)"] = .meaning
        let rows = ToolbarSearchRow.preview(results)
        let sourceRow = try #require(rows.first { $0.category == .sources })
        #expect(sourceRow.blockID == nil)
        #expect(sourceRow.relevance == "Text and meaning")
        let blockRow = try #require(rows.first { $0.category == .blocks })
        #expect(blockRow.id == "block:\(pageID):\(blockID)")
        #expect(blockRow.blockID == blockID)
        #expect(blockRow.relevance == "Related passage")
    }

}
