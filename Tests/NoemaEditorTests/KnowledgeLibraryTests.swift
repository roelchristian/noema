import Foundation
import Testing
@testable import VaultCore
@testable import noema

@Test @MainActor func knowledgeLibraryKeepsFamiliesDistinctAndPreservesDesignationAndStatus() throws {
    #expect(KnowledgeLibraryFamily.allCases.map(\.rawValue) == ["Semantic Blocks", "Knowledge Entities", "Semantic Objects", "Annotations"])
    var block = EditorBlock(runs: [RichRun("A meaningful block")])
    block.metadata.semantic = "question"; block.metadata.status = "answered"
    let record = NoteRecord(id: UUID(), title: "Page", aliases: [], tags: [], inlineTags: [], createdAt: "", updatedAt: "", body: BlockDocumentCodec.encode(.init(blocks: [block])), relativePath: "", contentHash: "", originalHeader: nil)
    let rows = SemanticBlockHit.search([record], query: "")
    #expect(rows.count == 1 && rows[0].status == "answered")
    #expect(SemanticCollectionPresentation.filteredRows(rows, selectedSemantic: "question", selectedStatus: "answered").count == 1)
    #expect(SemanticCollectionPresentation.filteredRows(rows, selectedSemantic: "question", selectedStatus: "unanswered").isEmpty)
    #expect(SemanticCollectionPresentation.filteredRows(rows, selectedSemantic: "idea", selectedStatus: "answered").isEmpty)
    let model = AppModel(); model.scope = .semantic
    #expect(model.scopeTitle == "Knowledge")
    #expect(model.knowledgeCatalogue == nil)
}
