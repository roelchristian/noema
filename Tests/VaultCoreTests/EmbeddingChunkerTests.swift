import Foundation
import Testing
@testable import VaultCore

private func chunkModel(bytes: Int = 32) throws -> EmbeddingModelDescriptor {
    try EmbeddingModelDescriptor(providerID: "mock", modelID: "chunks", revision: "1", dimensions: 3,
                                 maximumInputUTF8Bytes: bytes, maximumBatchSize: 10)
}
private func chunkIdentity(_ kind: AIEntityKind = .page, revision: String = "revision") throws -> EmbeddingEntityIdentity {
    try EmbeddingEntityIdentity(vaultID: UUID(), entityKind: kind, entityID: UUID(), revision: revision)
}

@Test func chunkerExcludesGeneratedSubtreesAndRetainsOriginalBlocks() throws {
    var generated = EditorBlock(runs: [RichRun("generated")], children: [EditorBlock(runs: [RichRun("generated child")])])
    generated.metadata.extra["aiGenerated"] = "true"
    // Marker alone excludes generated non-summary content too.
    generated.metadata.semantic = "definition"
    let child = EditorBlock(runs: [RichRun("original child")])
    let parent = EditorBlock(kind: .heading1, runs: [RichRun("heading")], children: [child])
    let chunks = try EmbeddingChunker.page(BlockDocument(blocks: [generated, parent]), identity: chunkIdentity(), model: chunkModel())
    #expect(chunks.map(\.text) == ["heading", "original child"])
    #expect(chunks.map(\.chunk.ordinal) == [0, 1])
    #expect(chunks.allSatisfy { $0.chunk.chunkingVersion == EmbeddingChunker.version })
}

@Test func chunkerPreservesUnchangedBlockIdentityAcrossInsertionAndRevision() throws {
    let block = EditorBlock(runs: [RichRun("original text")])
    let identity = try chunkIdentity()
    let revised = try EmbeddingEntityIdentity(vaultID: identity.vaultID, entityKind: .page, entityID: identity.entityID, revision: "new")
    let before = try EmbeddingChunker.page(BlockDocument(blocks: [block]), identity: identity, model: chunkModel())
    let after = try EmbeddingChunker.page(BlockDocument(blocks: [EditorBlock(runs: [RichRun("inserted")]), block]), identity: revised, model: chunkModel())
    #expect(before[0].chunk.chunkID == after[1].chunk.chunkID)
    #expect(before[0].chunk.contentFingerprint == after[1].chunk.contentFingerprint)
    #expect(after[1].chunk.identity.revision == "new")
}

@Test func chunkerBoundsUnicodeAndCoversLongOriginalWithOverlap() throws {
    let original = String(repeating: "alpha 👩🏽‍💻 café 日本語 ", count: 15)
    let chunks = try EmbeddingChunker.page(BlockDocument(blocks: [EditorBlock(runs: [RichRun(original)])]),
                                           identity: chunkIdentity(), model: chunkModel(bytes: 64))
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.text.utf8.count <= 64 && !$0.text.isEmpty })
    // Reassemble with maximal suffix/prefix overlap and confirm no original characters were lost.
    var rebuilt = chunks[0].text
    for chunk in chunks.dropFirst() {
        let previous = Array(rebuilt), next = Array(chunk.text)
        let overlap = (0...min(previous.count, next.count)).filter {
            String(next.prefix($0)).utf8.count <= 8 && Array(previous.suffix($0)) == Array(next.prefix($0))
        }.max() ?? 0
        rebuilt += String(next.dropFirst(overlap))
    }
    #expect(rebuilt == original)
}

@Test func chunkerSourcesUseNaturalParagraphsAndDeterministicFingerprints() throws {
    let identity = try chunkIdentity(.source)
    let first = try EmbeddingChunker.source(originalText: "first paragraph\n\nsecond paragraph", identity: identity, model: chunkModel())
    let second = try EmbeddingChunker.source(originalText: "first paragraph\n\nsecond paragraph", identity: identity, model: chunkModel())
    #expect(first == second)
    #expect(first.map(\.text) == ["first paragraph", "second paragraph"])
    #expect(first.map(\.chunk.chunkID) == ["paragraph/0/0", "paragraph/1/0"])
    #expect(first[0].chunk.contentFingerprint == digest(Data(first[0].text.utf8)))
}

@Test func chunkerRejectsWrongKindsAndUnrepresentableGrapheme() throws {
    #expect(throws: EmbeddingContractError.invalidInput) {
        try EmbeddingChunker.page(BlockDocument(), identity: chunkIdentity(.source), model: chunkModel())
    }
    #expect(throws: EmbeddingContractError.invalidInput) {
        try EmbeddingChunker.source(originalText: "original", identity: chunkIdentity(), model: chunkModel())
    }
    #expect(throws: EmbeddingContractError.invalidInput) {
        try EmbeddingChunker.source(originalText: "👩🏽‍💻", identity: chunkIdentity(.source), model: chunkModel(bytes: 4))
    }
}

@Test func chunkerEmptyContentAndTinyLimitsTerminateWithoutEmptyInputs() throws {
    #expect(try EmbeddingChunker.source(originalText: " \n\n\t", identity: chunkIdentity(.source), model: chunkModel()).isEmpty)
    let chunks = try EmbeddingChunker.source(originalText: "abc", identity: chunkIdentity(.source), model: chunkModel(bytes: 1))
    #expect(chunks.map(\.text) == ["a", "b", "c"])
}

@Test func chunkerWindowsNewlinesPreserveParagraphStructure() throws {
    let identity = try chunkIdentity(.source)
    let windows = try EmbeddingChunker.source(originalText: "first line\r\nsecond line\r\n\r\nnext paragraph",
        identity: identity, model: chunkModel(bytes: 64))
    let unix = try EmbeddingChunker.source(originalText: "first line\nsecond line\n\nnext paragraph",
        identity: identity, model: chunkModel(bytes: 64))
    #expect(windows == unix)
    #expect(windows.map(\.text) == ["first line\nsecond line", "next paragraph"])
}
