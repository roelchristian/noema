import Foundation
import Testing
import VaultCore
import ExternalAI
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct SemanticIndexCompositionTests {
    @Test @MainActor func semanticFailureDoesNotBlockCanonicalOpenLexicalSearchOrSaving() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSemanticComposition-\(UUID())")
        let vault = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let repo = try await openCanonicalAppFixture(root: vault, create: true)
        let page = try await repo.create(title: "Cosmic stars", body: "Original committed page")
        try await repo.shutdownPageStorage()
        let model = AppModel()
        model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        model.semanticIndexFactory = { _, _, _ in throw EmbeddingIndexError.unavailable }
        await model.open(vault, create: false)
        #expect(model.isVaultAvailable)
        #expect(model.semanticIndex == nil)
        #expect(model.semanticIndexIssue != nil)
        let lexical = try #require(model.index)
        #expect(try await lexical.search("Cosmic", kind: .wiki, tag: nil).contains { $0.id == page.id })
        model.select(page.id)
        for _ in 0..<50 where model.currentNote?.id != page.id { try await Task.sleep(for: .milliseconds(10)) }
        model.body = "Changed canonical content"
        #expect(await model.saveCurrent())
        #expect(await model.closeVault())
        #expect(model.semanticIndex == nil)
        #expect(model.semanticIndexIssue == nil)
    }

    @Test @MainActor func semanticIndexUsesAdmittedLocalRootAndRetiresOnClose() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSemanticLocal-\(UUID())")
        let vault = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let model = AppModel()
        model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(vault, create: true)
        #expect(model.isVaultAvailable)
        #expect(model.semanticIndex != nil)
        #expect(model.semanticIndexIssue == nil)
        #expect(await model.closeVault())
        #expect(model.semanticIndex == nil)
    }
    @Test @MainActor func selectedModelMismatchIsVaultLocalMetadataOnly() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSemanticModel-\(UUID())")
        let vault = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let domain = "noema-embedding-compatibility-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(aiDefaults: defaults)
        model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(vault, create: true)
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let index = try #require(model.semanticIndex)
        let descriptor = model.externalAIService.embeddingConfiguration.embeddingDescriptor
        let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: descriptor,
            chunkingVersion: EmbeddingChunker.version)
        let identity = try EmbeddingEntityIdentity(vaultID: lease.vaultID, entityKind: .page,
            entityID: UUID(), revision: "test-revision")
        try await index.replaceDocument(identity: identity, generation: generation, records: [], validatePublication: {})
        await model.refreshSemanticIndexCompatibility(for: lease)
        #expect(model.semanticIndexCompatibility == .compatible)
        try model.externalAIService.setEmbeddingModel(OpenAIEmbeddingModel.large.rawValue)
        await model.refreshSemanticIndexCompatibility(for: lease)
        #expect(model.semanticIndexCompatibility == .requiresRebuild)
        #expect(try await index.generations() == [generation])
        #expect(model.notes.isEmpty)
        #expect(await model.closeVault())
        #expect(model.semanticIndexCompatibility == .unavailable)
    }

}

}
