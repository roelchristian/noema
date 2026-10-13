import Foundation
import AppKit
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

@Test @MainActor func knowledgeTypeIconsAreAvailableAndEventIsAnAnnotationChoice() throws {
    let types = KnowledgeEntityType.initial.map(\.key)
    #expect(types == ["person", "place", "concept", "event"])
    let symbols = types.map { KnowledgeTypePresentation.symbol(for: $0) }
    #expect(Set(symbols).count == types.count)
    for symbol in symbols + [KnowledgeTypePresentation.knowledgeSymbol] {
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    }
    let choice = try #require(EditorAnnotationChoice.newEntityChoices.last)
    #expect(choice.title == "Create new event…")
    #expect(choice.symbol == KnowledgeTypePresentation.symbol(for: "event"))
}
