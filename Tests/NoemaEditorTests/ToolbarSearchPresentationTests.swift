import Foundation
import Testing
import VaultCore
@testable import noema

@Suite("Toolbar quick-result navigation")
struct ToolbarSearchPresentationTests {
    private func note(_ title: String) throws -> NoteRecord {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "title": title, "aliases": [], "tags": [], "inlineTags": [],
            "createdAt": "2026-10-12T00:00:00Z", "updatedAt": "2026-10-12T00:00:00Z",
            "body": "", "relativePath": "Pages/\(title).md", "contentHash": "fixture"
        ])
        return try JSONDecoder().decode(NoteRecord.self, from: data)
    }

    private func source(_ title: String) throws -> SourceRecord {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "title": title, "capturedAt": "2026-10-12T00:00:00Z",
            "originalFilename": "fixture.txt", "sha256": "fixture", "storedFilename": "fixture.txt"
        ])
        return SourceRecord(metadata: try JSONDecoder().decode(SourceMetadata.self, from: data), body: "")
    }

    @Test func previewCapsResultsAndRetainsEachMatchingCategory() throws {
        let pages = try (0..<12).map { try note("Page \($0)") }
        let sources = try (0..<12).map { try source("Source \($0)") }
        let blocks = (0..<12).map { index in
            SemanticBlockHit(pageID: pages[index].id, blockID: UUID(), pageTitle: pages[index].title,
                             semantic: "claim", preview: "Block \(index)")
        }
        let results = SidebarSearchResults(query: "fixture", pages: pages, sources: sources, blocks: blocks,
                                           pageExcerpts: [pages[0].id: "Page excerpt"],
                                           sourceExcerpts: [sources[0].id: "Source excerpt"])
        let rows = ToolbarSearchRow.preview(results)
        #expect(rows.count == 8)
        #expect(Set(rows.map(\.category)) == Set(ToolbarSearchRow.Category.allCases))
        #expect(rows.filter { $0.category == .pages }.map(\.entryID) == Array(pages.prefix(3)).map(\.id))
        #expect(rows.first?.excerpt == "Page excerpt")
        #expect(rows.first { $0.category == .sources }?.excerpt == "Source excerpt")
        let block = try #require(rows.first { $0.category == .blocks })
        #expect(block.entryID == blocks[0].pageID)
        #expect(block.blockID == blocks[0].blockID)
        #expect(block.excerpt.contains(blocks[0].preview))
    }

    @Test func sparseCategoriesDoNotLeaveUnusedPreviewCapacity() throws {
        let pages = try (0..<10).map { try note("Page \($0)") }
        let source = try source("One source")
        let rows = ToolbarSearchRow.preview(SidebarSearchResults(pages: pages, sources: [source]))
        #expect(rows.count == 8)
        #expect(rows.filter { $0.category == .pages }.count == 7)
        #expect(rows.filter { $0.category == .sources }.map(\.entryID) == [source.id])
        #expect(ToolbarSearchRow.preview(SidebarSearchResults()).isEmpty)
        #expect(ToolbarSearchRow.preview(SidebarSearchResults(pages: pages), limit: 0).isEmpty)
    }

    @Test func keyboardSelectionStartsAtTheDirectionalEdgeAndClamps() throws {
        let rows = ToolbarSearchRow.preview(SidebarSearchResults(pages: try [note("A"), note("B"), note("C")]))
        #expect(ToolbarSearchRow.nextSelection(current: nil, rows: rows, offset: 1) == rows[0].id)
        #expect(ToolbarSearchRow.nextSelection(current: nil, rows: rows, offset: -1) == rows[2].id)
        #expect(ToolbarSearchRow.nextSelection(current: rows[0].id, rows: rows, offset: 1) == rows[1].id)
        #expect(ToolbarSearchRow.nextSelection(current: rows[0].id, rows: rows, offset: -1) == rows[0].id)
        #expect(ToolbarSearchRow.nextSelection(current: rows[2].id, rows: rows, offset: 1) == rows[2].id)
        #expect(ToolbarSearchRow.nextSelection(current: "superseded", rows: rows, offset: 1) == rows[0].id)
        #expect(ToolbarSearchRow.nextSelection(current: rows[0].id, rows: [], offset: 1) == nil)
    }
}
