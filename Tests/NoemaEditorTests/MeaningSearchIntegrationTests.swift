import Foundation
import Testing
@testable import ExternalAI
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct MeaningSearchIntegrationTests {
    @MainActor func seed(_ model: AppModel, sources: Bool = false) async throws {
        let repository = try #require(model.repository)
        let index = try #require(model.semanticIndex)
        let generation = try #require(model.semanticProcessingGeneration)
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let inventory = try await repository.aiProcessingInventory()
        for value in inventory where value.kind != .removed && (sources || value.entityKind == .page) {
            let snapshot = value.entityKind == .page
                ? try await repository.embeddingPageSnapshot(id: value.entityID, expectedRevision: value.revision, model: generation.model)
                : try await repository.embeddingSourceSnapshot(id: value.entityID, expectedRevision: value.revision,
                    model: generation.model, extractOriginal: AppModel.embeddingOriginalText)
            let vector = try EmbeddingVector(values: Array(repeating: 0.25, count: generation.model.dimensions), model: generation.model)
            let records = try snapshot.inputs.map { try EmbeddingRecord(generation: generation, chunk: $0.chunk, vector: vector) }
            let permit = value.entityKind == .page
                ? try await repository.sqliteBlockStore.embeddingPublicationPermit(pageID: value.entityID, expected: snapshot.canonicalRevision)
                : try await repository.sqliteBlockStore.embeddingPublicationPermit(sourceID: value.entityID, expected: snapshot.canonicalRevision)
            let authority = try EmbeddingPublicationAuthority(accessGate: model.sessionManager.accessGate, lease: lease, generation: generation)
            try await index.replaceDocument(identity: snapshot.identity, generation: generation, records: records,
                permit: permit, authority: authority,
                completion: .init(identity: snapshot.identity, workRevision: snapshot.revision,
                    inputFingerprint: snapshot.inputFingerprint, chunkCount: records.count,
                    originalFingerprint: snapshot.originalFingerprint), validatePublication: {})
        }
    }
    @MainActor func settled(_ model: AppModel) async throws {
        for _ in 0..<600 {
            if !model.semanticSearchStatus.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Meaning search did not settle: \(model.semanticSearchStatus)")
    }
    @MainActor func disclosure(_ model: AppModel) async throws -> SemanticQueryDisclosure {
        for _ in 0..<600 {
            if let disclosure = model.pendingSemanticQueryDisclosure { return disclosure }
            if case .failed(let message) = model.semanticSearchStatus { throw NSError(domain: message, code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(model.pendingSemanticQueryDisclosure)
    }

    @Test @MainActor func meaningSearchDiscoversParaphraseWithoutMutatingCanonicalContentAndRetiresRows() async throws {
        let (model, _, defaults, domain, _, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        try await seed(model)
        let repository = try #require(model.repository)
        let before = try await repository.scan().notes
        model.searchText = "urban settlement"; model.setSearchRetrievalMode(.meaning)
        await model.updateRows()
        #expect(model.visibleSearchResults.isEmpty)
        model.submitMeaningSearch(); try await settled(model)
        #expect(model.semanticSearchStatus == .completed)
        #expect(model.visibleSearchResults.pages.map(\.id) == before.map(\.id))
        #expect(model.visibleSearchResults.relevance.values.contains(.meaning))
        #expect(model.visibleSearchResults.pageBlocks.count == 1)
        #expect(try await repository.scan().notes == before)
        model.cancelMeaningSearch()
        #expect(model.visibleSearchResults.isEmpty && model.meaningEvidence.isEmpty)
        #expect(await model.closeVault())
    }

    @Test @MainActor func meaningSearchEmptyIndexAndProviderFailureRetainLexicalAndQuickOpen() async throws {
        let (model, _, defaults, domain, probe, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        model.searchText = "Historical"; model.setSearchRetrievalMode(.meaning)
        model.submitMeaningSearch(); try await settled(model)
        #expect(model.visibleSearchResults.pages.count == 1)
        #expect(probe.calls.withLock { $0 } == 0)
        try await seed(model)
        model.embeddingProviderFactory = { throw EmbeddingContractError.invalidModel }
        model.submitMeaningSearch(); try await settled(model)
        #expect(model.visibleSearchResults.pages.count == 1)
        #expect(model.visibleSearchResults.hybridOrder.isEmpty)
        model.setSearchMode(.quickOpen); model.submitMeaningSearch(); await model.updateRows()
        #expect(model.visibleSearchResults.pages.count == 1 && probe.calls.withLock { $0 } == 0)
        #expect(await model.closeVault())
    }

    @Test @MainActor func meaningSearchCloudRequiresFreshExactApprovalAndTypingScopeNeverDispatch() async throws {
        let (model, _, defaults, domain, _, auth, transport) = try await EmbeddingBackfillApplicationTests().fixture(pages: 1, cloud: true)
        defer { defaults.removePersistentDomain(forName: domain) }
        try await seed(model)
        model.searchText = "Historical"; model.setSearchRetrievalMode(.meaning)
        await model.updateRows(); model.setSearchScope(.pages); await model.updateRows()
        #expect(await transport.count == 0 && auth.calls.withLock { $0 } == 0)
        model.submitMeaningSearch()
        let first = try await disclosure(model)
        #expect(first.query == "Historical" && first.provider == "OpenAI")
        #expect(await transport.count == 0)
        model.declineSemanticQuery(queryID: first.id); try await settled(model)
        #expect(model.semanticSearchStatus == .declined && model.visibleSearchResults.pages.count == 1)
        model.submitMeaningSearch()
        let second = try await disclosure(model)
        #expect(second.id != first.id)
        model.approveSemanticQuery(queryID: first.id)
        #expect(await transport.count == 0)
        model.approveSemanticQuery(queryID: second.id); try await settled(model)
        #expect(model.semanticSearchStatus == .completed)
        #expect(await transport.count == 1 && auth.calls.withLock { $0 } == 1)
        #expect(model.visibleSearchResults.relevance.values.contains(.both))
        model.searchText = "Other"; model.queryChanged(); model.searchText = "Historical"; model.queryChanged()
        model.approveSemanticQuery(queryID: second.id); await model.updateRows()
        #expect(await transport.count == 1 && model.visibleSearchResults.hybridOrder.isEmpty)
        #expect(await model.closeVault())
    }

    @Test @MainActor func meaningSearchRejectsCanonicalEditAfterHydrationBeforeAssignment() async throws {
        let (model, _, defaults, domain, _, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        try await seed(model)
        let repository = try #require(model.repository), note = try #require(model.notes.first)
        model.beforeMeaningPublication = {
            _ = try await repository.save(note: note, title: note.title, body: "Replacement committed during query", tags: note.tags)
        }
        model.searchText = "urban settlement"; model.setSearchRetrievalMode(.meaning)
        model.submitMeaningSearch(); try await settled(model)
        #expect(model.visibleSearchResults.hybridOrder.isEmpty)
        #expect(!model.visibleSearchResults.relevance.values.contains(.meaning))
        model.beforeMeaningPublication = nil
        #expect(await model.closeVault())
    }

    @Test @MainActor func meaningSearchSourcesUseCurrentOriginalEvidenceAndDocumentNavigation() async throws {
        let (model, _, defaults, domain, _, _, _) = try await EmbeddingBackfillApplicationTests().fixture(pages: 0, sources: 1)
        defer { defaults.removePersistentDomain(forName: domain) }
        try await seed(model, sources: true)
        model.searchText = "island geography"; model.setSearchRetrievalMode(.meaning); model.setSearchScope(.sources)
        model.submitMeaningSearch(); try await settled(model)
        #expect(model.semanticSearchStatus == .completed)
        #expect(model.visibleSearchResults.sources.count == 1 && model.visibleSearchResults.pages.isEmpty)
        #expect(model.visibleSearchResults.sourceExcerpts.values.first?.contains("island") == true)
        #expect(await model.closeVault())
    }
}
}
