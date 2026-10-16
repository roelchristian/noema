import Foundation
import NaturalLanguage
import Testing
@testable import VaultCore

struct EmbeddingInputPreparationTests {
    private func model(native: Bool = false) throws -> EmbeddingModelDescriptor {
        try .init(providerID: native ? "apple-natural-language" : "openai",
                  modelID: native ? "sentence-en-input-v1" : "text-embedding-3-small",
                  revision: "test", dimensions: 3, maximumInputUTF8Bytes: native ? 1024 : 8000,
                  maximumBatchSize: native ? 16 : 1)
    }
    private func identity(_ kind: AIEntityKind = .page, revision: String = "revision") throws -> EmbeddingEntityIdentity {
        try .init(vaultID: UUID(), entityKind: kind, entityID: UUID(), revision: revision)
    }
    private func words(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.english); tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in count += 1; return true }
        return count
    }

    @Test func nativeChunkingHonorsWordsIndependentlyOfBytes() throws {
        let descriptor = try model(native: true)
        let text = String(repeating: "the ", count: 600)
        let inputs = try EmbeddingChunker.page(.init(blocks: [.init(runs: [.init(text)])]), identity: identity(), model: descriptor)
        #expect(inputs.count > 4)
        #expect(inputs.allSatisfy { words($0.text) > 0 && words($0.text) <= 128 && $0.text.utf8.count <= 1024 })
        // Overlap may duplicate words; it must never truncate the final tail.
        #expect(inputs.reduce(0) { $0 + words($1.text) } >= 600)
        #expect(inputs.last?.text.hasSuffix("the ") == true)
        #expect(EmbeddingInputPreparation.requestBatches(inputs, model: descriptor).allSatisfy { $0.count <= 16 })
    }

    @Test func openAIChunksAndBatchesPreserveAllInputWithinRequestBound() throws {
        let text = String(repeating: "The complete source paragraph remains available for embedding. ", count: 400)
        let descriptor = try model()
        let inputs = try EmbeddingInputPreparation.source(extractedOriginalText: text, identity: identity(.source), model: descriptor)
        #expect(inputs.count > 1)
        #expect(inputs.allSatisfy { $0.text.utf8.count <= 8000 })
        #expect(inputs.map(\.text).joined().contains("complete source paragraph"))
        #expect(inputs.reduce(0) { $0 + $1.text.utf8.count } >= text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count)
        #expect(EmbeddingInputPreparation.requestBatches(inputs, model: descriptor).allSatisfy { $0.count == 1 })
    }

    @Test func sourceParagraphIdentityRemainsPositionalAndFrontmatterStaysLocal() throws {
        let inputs = try EmbeddingInputPreparation.source(extractedOriginalText: "---\nprivate: metadata\n---\nFirst paragraph\n\nSecond paragraph", identity: identity(.source), model: model())
        #expect(inputs.map(\.text) == ["First paragraph", "Second paragraph"])
        #expect(inputs.map(\.chunk.chunkID) == ["paragraph/0/0", "paragraph/1/0"])
        let literal = try EmbeddingInputPreparation.source(extractedOriginalText: "---\nAn original sentence.\n---\nMore text", identity: identity(.source), model: model())
        #expect(literal.map(\.text).joined().contains("An original sentence."))
    }

    @Test func generatedParentExcludesItsEntireSubtreeForPagesAndSources() throws {
        var generated = BlockMetadata(); generated.extra["aiGenerated"] = "true"
        let document = BlockDocument(blocks: [
            .init(runs: [.init("Human content")]),
            .init(runs: [.init("Generated parent")], metadata: generated, children: [.init(runs: [.init("Unmarked generated descendant")])])
        ])
        let page = try EmbeddingInputPreparation.page(document, identity: identity(), model: model())
        let source = try EmbeddingInputPreparation.source(extractedOriginalText: BlockDocumentCodec.encode(document), identity: identity(.source), model: model())
        #expect(page.map(\.text) == ["Human content"])
        #expect(source.map(\.text).joined().contains("Human content"))
        #expect(!source.map(\.text).joined().contains("generated descendant"))
        #expect(!source.map(\.text).joined().contains("Generated parent"))
    }

    @Test func oversizedGraphemeAndUnsupportedDocumentFailExplicitly() throws {
        let text = "a" + String(repeating: "\u{0301}", count: 5000)
        #expect(throws: EmbeddingContractError.invalidInput) {
            try EmbeddingInputPreparation.page(.init(blocks: [.init(runs: [.init(text)])]), identity: identity(), model: model())
        }
        var future = BlockDocument(); future.unsupportedVersion = true
        #expect(throws: EmbeddingInputPreparationError.unsupportedDocument) {
            try EmbeddingInputPreparation.page(future, identity: identity(), model: model())
        }
    }

    @Test func nativeUnsupportedLanguageIsExplicitAndNeverFallsBack() throws {
        #expect(throws: EmbeddingInputPreparationError.unsupportedLanguage) {
            try EmbeddingInputPreparation.page(.init(blocks: [.init(runs: [.init("これは日本語の文書です。日本語の文章が書かれています。")])]), identity: identity(), model: model(native: true))
        }
    }

    @Test func unchangedVectorsAdvanceRevisionButChangedChunkRequiresInference() throws {
        let descriptor = try model(), old = try identity()
        let first = EditorBlock(runs: [.init("Retained human paragraph")]), second = EditorBlock(runs: [.init("Before")])
        let oldInputs = try EmbeddingInputPreparation.page(.init(blocks: [first, second]), identity: old, model: descriptor)
        let generation = try EmbeddingIndexGeneration(vaultID: old.vaultID, model: descriptor, chunkingVersion: EmbeddingChunker.version)
        let vector = try EmbeddingVector(values: [1, 0, 0], model: descriptor)
        let existing = try oldInputs.map { try EmbeddingRecord(generation: generation, chunk: $0.chunk, vector: vector) }
        let updated = try EmbeddingEntityIdentity(vaultID: old.vaultID, entityKind: .page, entityID: old.entityID, revision: "next")
        var changed = second; changed.runs = [.init("After")]
        let inputs = try EmbeddingInputPreparation.page(.init(blocks: [first, changed]), identity: updated, model: descriptor)
        let snapshot = EmbeddingPreparedInputSnapshot(identity: updated, canonicalRevision: .init(token: Data("next".utf8)), model: descriptor, inputs: inputs, sourceEvidence: nil)
        let reused = try EmbeddingInputPreparation.reusableRecords(existing, for: snapshot, generation: generation)
        #expect(reused.count == 1)
        #expect(reused.first?.chunk.identity.revision == "next")
        #expect(reused.first?.vector == vector)
    }

    private func fixture() async throws -> (URL, FileVaultRepository) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("noema-embedding-input-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: root, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        return (root, repository)
    }

    @Test func committedPageSnapshotRejectsStaleRevisionAndRetainsEmptyIdentity() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await repository.create(title: "Input", body: "Before")
        let prepared = try await repository.embeddingPageSnapshot(id: note.id, expectedRevision: note.contentHash, model: model())
        let saved = try await repository.save(note: note, title: note.title, body: "", tags: [])
        await #expect(throws: EmbeddingInputPreparationError.staleRevision) { try await repository.validateEmbeddingSnapshot(prepared) }
        await #expect(throws: EmbeddingInputPreparationError.staleRevision) {
            try await repository.embeddingPageSnapshot(id: note.id, expectedRevision: note.contentHash, model: model())
        }
        let empty = try await repository.embeddingPageSnapshot(id: saved.id, expectedRevision: saved.contentHash, model: model())
        #expect(empty.inputs.isEmpty)
        #expect(empty.revision == saved.contentHash)
        #expect(!empty.inputFingerprint.isEmpty)
        try await repository.trash(note: saved)
        await #expect(throws: EmbeddingInputPreparationError.staleRevision) { try await repository.validateEmbeddingSnapshot(empty) }
    }

    @Test func sourceSnapshotUsesOriginalAndDetectsIndependentByteChange() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await repository.importSource(data: Data("Complete original body".utf8), filename: "source.txt", title: "Source", originURL: nil)
        let revision = try #require(try await repository.aiProcessingInventory().first { $0.entityID == source.id }?.revision)
        let prepared = try await repository.embeddingSourceSnapshot(id: source.id, expectedRevision: revision, model: model(), extractOriginal: {
            guard let text = String(data: $0.original, encoding: .utf8) else { throw EmbeddingInputPreparationError.unavailableOriginal }
            return text
        })
        #expect(prepared.inputs.map(\.text).joined().contains("Complete original body"))
        try await repository.validateEmbeddingSnapshot(prepared)
        let externalRevision = revision + ":" + digest(Data("Complete original body".utf8))
        let external = try await repository.embeddingSourceSnapshot(id: source.id, expectedRevision: externalRevision, model: model(), extractOriginal: {
            String(decoding: $0.original, as: UTF8.self)
        })
        #expect(external.revision == externalRevision)
        #expect(external.identity.revision == revision)
        await #expect(throws: EmbeddingInputPreparationError.staleRevision) {
            try await repository.embeddingSourceSnapshot(id: source.id, expectedRevision: revision + ":wrong-fingerprint", model: model(), extractOriginal: { String(decoding: $0.original, as: UTF8.self) })
        }
        let original = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename)
        try Data("Independent replacement".utf8).write(to: original)
        do { try await repository.validateEmbeddingSnapshot(prepared); Issue.record("Changed original remained current") } catch {}
    }
}
