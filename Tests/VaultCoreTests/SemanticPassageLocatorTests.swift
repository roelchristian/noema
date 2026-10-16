import Foundation
import Testing
@testable import VaultCore

@Test func semanticLocatorParsesOnlyTypedNonnegativeStructuralLocators() {
    let block = UUID()
    #expect(SemanticPassageLocator(chunkID: "block/\(block)/0", entityKind: .page) == .block(block, segment: 0))
    #expect(SemanticPassageLocator(chunkID: "paragraph/7/2", entityKind: .source) == .paragraph(7, segment: 2))
    for invalid in ["paragraph/-1/0", "paragraph/0/-1", "paragraph/00/0", "paragraph/+1/0", "paragraph/0/0/", "paragraph/0/", "paragraph/999999999999999999999/0", "block/no-uuid/0"] {
        #expect(SemanticPassageLocator(chunkID: invalid, entityKind: .source) == nil)
        #expect(SemanticPassageLocator(chunkID: invalid, entityKind: .page) == nil)
    }
    #expect(SemanticPassageLocator(chunkID: "block/\(block)/0", entityKind: .source) == nil)
    #expect(SemanticPassageLocator(chunkID: "paragraph/0/0", entityKind: .page) == nil)
}

@Test func semanticLocatorHydratesOnlyExactCurrentModelGenerationAndChunk() throws {
    let model = try EmbeddingModelDescriptor(providerID: "test", modelID: "locator", revision: "1", dimensions: 3,
        maximumInputUTF8Bytes: 128, maximumBatchSize: 2)
    let identity = try EmbeddingEntityIdentity(vaultID: UUID(), entityKind: .page, entityID: UUID(), revision: "r1")
    let generation = try EmbeddingIndexGeneration(vaultID: identity.vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("Current passage")])])
    let inputs = try EmbeddingChunker.page(document, identity: identity, model: model)
    let current = EmbeddingPreparedInputSnapshot(identity: identity, canonicalRevision: .init(token: Data("r1".utf8)),
        model: model, inputs: inputs, sourceEvidence: nil)
    let passage = try SemanticSearchPassage(chunk: inputs[0].chunk, cosineSimilarity: 0.7)
    #expect(SemanticPassageLocator.resolve(passage: passage, generation: generation, selectedGeneration: generation, current: current) == inputs[0])
    let replacement = try EmbeddingIndexGeneration(vaultID: identity.vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
    #expect(SemanticPassageLocator.resolve(passage: passage, generation: generation, selectedGeneration: replacement, current: current) == nil)
    let stale = try EmbeddingEntityIdentity(vaultID: identity.vaultID, entityKind: .page, entityID: identity.entityID, revision: "old")
    let old = EmbeddingPreparedInputSnapshot(identity: stale, canonicalRevision: .init(token: Data()), model: model,
        inputs: inputs, sourceEvidence: nil)
    #expect(SemanticPassageLocator.resolve(passage: passage, generation: generation, selectedGeneration: generation, current: old) == nil)
    let edited = try EmbeddingChunk(identity: identity, chunkID: inputs[0].chunk.chunkID, ordinal: 0,
        contentFingerprint: "changed", chunkingVersion: EmbeddingChunker.version)
    let changed = EmbeddingPreparedInputSnapshot(identity: identity, canonicalRevision: .init(token: Data()), model: model,
        inputs: [.init(chunk: edited, text: "Changed text")], sourceEvidence: nil)
    #expect(SemanticPassageLocator.resolve(passage: passage, generation: generation, selectedGeneration: generation, current: changed) == nil)
}

@Test func semanticLocatorRejectsMovedSourceParagraphRatherThanGuessing() throws {
    let model = try EmbeddingModelDescriptor(providerID: "test", modelID: "source", revision: "1", dimensions: 3,
        maximumInputUTF8Bytes: 128, maximumBatchSize: 2)
    let identity = try EmbeddingEntityIdentity(vaultID: UUID(), entityKind: .source, entityID: UUID(), revision: "r1")
    let generation = try EmbeddingIndexGeneration(vaultID: identity.vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
    let before = try EmbeddingChunker.source(originalText: "Original", identity: identity, model: model)
    let after = try EmbeddingChunker.source(originalText: "Inserted\n\nOriginal", identity: identity, model: model)
    let current = EmbeddingPreparedInputSnapshot(identity: identity, canonicalRevision: .init(token: Data()), model: model,
        inputs: after, sourceEvidence: nil)
    let passage = try SemanticSearchPassage(chunk: before[0].chunk, cosineSimilarity: 0.9)
    #expect(SemanticPassageLocator.resolve(passage: passage, generation: generation, selectedGeneration: generation, current: current) == nil)
}
