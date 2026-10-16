import Foundation
import Testing
@testable import ExternalAI
@testable import VaultCore
@testable import noema

@MainActor private final class MeaningNavigationSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async throws {
        for _ in 0..<600 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(entered, "Semantic navigation never reached its controlled suspension")
    }
    func resume() { continuation?.resume(); continuation = nil }
}

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct MeaningSearchAdversarialTests {
    @Test @MainActor func semanticNavigationDelayedACannotReplaceLaterBAndCurrentBlockRemainsPrecise() async throws {
        let (model, _, defaults, domain, _, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 2)
        defer { defaults.removePersistentDomain(forName: domain) }
        let helper = MeaningSearchIntegrationTests()
        try await helper.seed(model)
        model.searchText = "urban settlement"; model.setSearchRetrievalMode(.meaning)
        model.submitMeaningSearch(); try await helper.settled(model)
        let pages = model.visibleSearchResults.pages
        #expect(pages.count == 2)
        let first = try #require(pages.first), second = try #require(pages.last)
        let block = try #require(model.visibleSearchResults.pageBlocks[second.id])
        let suspension = MeaningNavigationSuspension()
        defer { suspension.resume() }
        model.beforeMeaningNavigation = { id in if id == first.id { await suspension.suspend() } }
        let delayed = try #require(model.openSearchResult(entryID: first.id,
            blockID: model.visibleSearchResults.pageBlocks[first.id], isSource: false))
        try await suspension.waitUntilEntered()
        let later = try #require(model.openSearchResult(entryID: second.id, blockID: block, isSource: false))
        await later.value
        #expect(model.currentNote?.id == second.id)
        #expect(model.selectedSemanticID == "\(second.id):\(block)")
        suspension.resume(); await delayed.value
        #expect(model.currentNote?.id == second.id)
        #expect(model.selectedSemanticID == "\(second.id):\(block)")
        model.beforeMeaningNavigation = nil
        #expect(await model.closeVault())
    }

    @Test(arguments: ["query", "model", "lease"]) @MainActor
    func semanticNavigationCannotPublishAfterAuthorityReplacement(change: String) async throws {
        let (model, _, defaults, domain, _, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 2)
        defer { defaults.removePersistentDomain(forName: domain) }
        let initial = try #require(model.notes.first), target = try #require(model.notes.last)
        model.select(initial.id)
        let helper = MeaningSearchIntegrationTests()
        try await helper.seed(model)
        model.searchText = "urban settlement"; model.setSearchRetrievalMode(.meaning)
        model.submitMeaningSearch(); try await helper.settled(model)
        let suspension = MeaningNavigationSuspension()
        defer { suspension.resume() }
        model.beforeMeaningNavigation = { _ in await suspension.suspend() }
        let navigation = try #require(model.openSearchResult(entryID: target.id,
            blockID: model.visibleSearchResults.pageBlocks[target.id], isSource: false))
        try await suspension.waitUntilEntered()
        switch change {
        case "query": model.searchText = "new query"; model.queryChanged()
        case "model": model.semanticProcessingGeneration = nil
        default: #expect(await model.lockVault())
        }
        suspension.resume(); await navigation.value
        if change == "lease" { #expect(model.currentNote == nil && !model.isVaultAvailable) }
        else { #expect(model.currentNote?.id == initial.id) }
        #expect(model.selectedSemanticID == nil)
        model.beforeMeaningNavigation = nil
        #expect(await model.closeVault())
    }

    @Test @MainActor func semanticNavigationDoesNotFocusAnUnsavedChangedPassage() async throws {
        let (model, _, defaults, domain, _, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        let helper = MeaningSearchIntegrationTests()
        try await helper.seed(model)
        let page = try #require(model.notes.first)
        model.select(page.id)
        // Query committed canonical evidence while a different draft remains in the editor.
        // No autosave timer is armed: this isolates the unsaved editor navigation boundary.
        model.editorDocument = BlockDocumentCodec.decode("An unsaved paragraph now describes gardening.")
        model.searchText = "urban settlement"; model.setSearchRetrievalMode(.meaning)
        model.submitMeaningSearch(); try await helper.settled(model)
        let block = try #require(model.visibleSearchResults.pageBlocks[page.id])
        #expect(!model.meaningEvidence.isEmpty)
        let navigation = try #require(model.openSearchResult(entryID: page.id, blockID: block, isSource: false))
        await navigation.value
        #expect(model.currentNote?.id == page.id)
        #expect(model.body.contains("unsaved paragraph"))
        #expect(model.selectedSemanticID == nil)
        #expect(await model.closeVault())
    }

    @Test @MainActor func semanticSourceOriginalReplacementCannotPublishIndexedPassage() async throws {
        let (model, root, defaults, domain, _, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 0, sources: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        let helper = MeaningSearchIntegrationTests()
        try await helper.seed(model, sources: true)
        let source = try #require(model.sources.first)
        let original = root.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)")
        try Data("An independently replaced imported original with unrelated content.".utf8).write(to: original)
        model.searchText = "island geography"; model.setSearchRetrievalMode(.meaning); model.setSearchScope(.sources)
        model.submitMeaningSearch(); try await helper.settled(model)
        #expect(model.visibleSearchResults.hybridOrder.isEmpty)
        #expect(model.meaningEvidence.isEmpty)
        #expect(!model.visibleSearchResults.relevance.values.contains(.meaning))
        #expect(await model.closeVault())
    }
    @Test @MainActor func meaningAllPreservesTagOnlyLexicalPageOnceAndBlocksScopeKeepsItsLocator() async throws {
        let (model, _, defaults, domain, probe, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 2)
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = try #require(model.repository), page = try #require(model.notes.first)
        var block = EditorBlock(runs: [RichRun("A paragraph about coastal cities and urban planning.")])
        block.metadata.semantic = "idea"
        _ = try await repository.save(note: page, title: page.title,
            body: BlockDocumentCodec.encode(BlockDocument(blocks: [block])), tags: page.tags)
        await model.refresh()
        let helper = MeaningSearchIntegrationTests()
        try await helper.seed(model)
        model.searchText = "idea"; model.setSearchRetrievalMode(.meaning); model.setSearchScope(.all)
        await model.updateRows()
        #expect(!model.visibleSearchResults.pages.contains(where: { $0.id == page.id }))
        #expect(model.visibleSearchResults.blocks.contains(where: { $0.pageID == page.id }))
        model.submitMeaningSearch(); try await helper.settled(model)
        #expect(model.visibleSearchResults.pages.filter { $0.id == page.id }.count == 1)
        #expect(!model.visibleSearchResults.blocks.contains(where: { $0.pageID == page.id }))
        #expect(model.visibleSearchResults.pageBlocks[page.id] == block.id)
        #expect(model.visibleSearchResults.relevance[AppModel.meaningKey(.page, page.id)] == .both)
        let calls = probe.calls.withLock { $0 }
        model.setSearchScope(.blocks); await model.updateRows()
        #expect(probe.calls.withLock { $0 } == calls) // Scope alone never embeds the query.
        model.submitMeaningSearch(); try await helper.settled(model)
        #expect(model.visibleSearchResults.pages.isEmpty)
        #expect(model.visibleSearchResults.blocks.map(\.blockID) == [block.id])
        #expect(await model.closeVault())
    }
}
}

@Suite("Meaning preview global selection")
struct MeaningPreviewGlobalSelectionTests {
    @Test func fusedTopEightPrecedeCategoryBalancingWhileKeywordPreviewKeepsCategories() throws {
        let pages = try (0..<9).map { number -> NoteRecord in
            let data = try JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString, "title": "Rank \(number)", "aliases": [], "tags": [], "inlineTags": [],
                "createdAt": "2026-10-16", "updatedAt": "2026-10-16", "body": "",
                "relativePath": "Pages/fixture-\(number).md", "contentHash": "fixture"
            ])
            return try JSONDecoder().decode(NoteRecord.self, from: data)
        }
        let sourceID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": sourceID.uuidString, "title": "Lower ranked source", "capturedAt": "2026-10-16",
            "originalFilename": "fixture.txt", "sha256": "fixture", "storedFilename": "fixture.txt"
        ])
        let source = SourceRecord(metadata: try JSONDecoder().decode(SourceMetadata.self, from: data), body: "")
        var results = SidebarSearchResults(pages: pages, sources: [source])
        results.hybridOrder = pages.map { "page:\($0.id)" } + ["source:\(sourceID)"]
        let meaning = ToolbarSearchRow.preview(results)
        #expect(meaning.map(\.entryID) == Array(pages.prefix(8).map(\.id)))
        #expect(meaning.allSatisfy { $0.category == .pages })
        results.hybridOrder = []
        let keyword = ToolbarSearchRow.preview(results)
        #expect(keyword.count == 8)
        #expect(keyword.contains { $0.entryID == sourceID })
        #expect(ToolbarSearchRow.preview(results, limit: 0).isEmpty)
    }
}
