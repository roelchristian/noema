import Foundation
import Testing
@testable import VaultCore

private struct HybridFixture {
    let vault = UUID()
    let model: EmbeddingModelDescriptor
    let generation: EmbeddingIndexGeneration
    init() throws {
        model = try EmbeddingModelDescriptor(providerID: "test", modelID: "ranking", revision: "1",
            dimensions: 3, maximumInputUTF8Bytes: 128, maximumBatchSize: 2)
        generation = try EmbeddingIndexGeneration(vaultID: vault, model: model, chunkingVersion: EmbeddingChunker.version)
    }
    func identity(_ kind: AIEntityKind = .page, id: UUID = UUID(), revision: String = "r1") throws -> EmbeddingEntityIdentity {
        try .init(vaultID: vault, entityKind: kind, entityID: id, revision: revision)
    }
    func semantic(_ identity: EmbeddingEntityIdentity, title: String, aliases: [String] = [],
                  scores: [Double] = [0.9], block: UUID = UUID(), tagged: Bool = false) throws -> HybridSemanticCandidate {
        let passages = try scores.enumerated().map { offset, score in
            let locator = identity.entityKind == .page ? "block/\(block.uuidString)/\(offset)" : "paragraph/0/\(offset)"
            return try SemanticSearchPassage(chunk: .init(identity: identity, chunkID: locator, ordinal: offset,
                contentFingerprint: "hash-\(offset)", chunkingVersion: EmbeddingChunker.version), cosineSimilarity: score)
        }
        let completion = EmbeddingDocumentCompletion(identity: identity, workRevision: identity.revision,
            inputFingerprint: "input", chunkCount: scores.count)
        return try .init(candidate: .init(generation: generation, completion: completion, passages: passages),
            title: title, aliases: aliases, currentSemanticBlockIDs: tagged ? [block] : [])
    }
}

@Test func hybridRankingRRFRewardsBothChannelsAndDeduplicatesDocuments() throws {
    let f = try HybridFixture(), first = try f.identity(), second = try f.identity(), third = try f.identity(.source)
    let lexical = try [HybridLexicalCandidate(identity: first, title: "First", rank: 1),
                       HybridLexicalCandidate(identity: second, title: "Second", rank: 2),
                       HybridLexicalCandidate(identity: second, title: "Second", rank: 3)]
    let semantic = try [f.semantic(third, title: "Third", scores: [0.99]),
                        f.semantic(second, title: "Second", scores: [0.9, 0.8, 0.7])]
    let results = try HybridSearchRanking.fuse(query: "topic", lexical: lexical, semantic: semantic, generation: f.generation)
    #expect(results.map(\.identity.entityID) == [second.entityID, first.entityID, third.entityID])
    #expect(results[0].provenance == .both)
    #expect(results[0].passages.count == 3)
    #expect(results[0].completion == semantic[1].candidate.completion)
    #expect(abs(results[0].score - 2.0 / 62) < 0.0000001)
    #expect(results[1].provenance == .text)
    #expect(results[2].provenance == .meaning)
}

@Test func hybridRankingExactTitleAndAliasProtectionDoesNotChangeLexicalFallback() throws {
    let f = try HybridFixture(), first = try f.identity(), exact = try f.identity()
    let lexical = try [HybridLexicalCandidate(identity: first, title: "Related", rank: 1),
                       HybridLexicalCandidate(identity: exact, title: "Another title", aliases: ["Café"], rank: 9)]
    let semantic = try [f.semantic(first, title: "Related")]
    let fallback = try HybridSearchRanking.fuse(query: " CAFÉ ", lexical: lexical, semantic: [], generation: f.generation)
    #expect(fallback.map(\.identity.entityID) == [first.entityID, exact.entityID])
    let fused = try HybridSearchRanking.fuse(query: " cafe\u{301} ", lexical: lexical, semantic: semantic, generation: f.generation)
    #expect(fused.first?.identity == exact)
    let title = try [HybridLexicalCandidate(identity: exact, title: "Café", rank: 9)]
    #expect(try HybridSearchRanking.fuse(query: "café", lexical: lexical.prefix(1).map { $0 } + title,
        semantic: semantic, generation: f.generation).first?.identity == exact)
}

@Test func hybridRankingScopesRequireCurrentTaggedBlockEvidence() throws {
    let f = try HybridFixture(), page = try f.identity(), source = try f.identity(.source), taggedPage = try f.identity()
    let semantic = try [f.semantic(page, title: "Page"), f.semantic(source, title: "Source"),
                        f.semantic(taggedPage, title: "Tagged", tagged: true)]
    let blocks = try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: semantic, generation: f.generation, scope: .blocks)
    #expect(blocks.map(\.identity) == [taggedPage])
    let pages = try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: semantic, generation: f.generation, scope: .pages)
    #expect(pages.count == 2)
    let sources = try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: semantic, generation: f.generation, scope: .sources)
    #expect(sources.map(\.identity) == [source])
}

@Test func hybridRankingRejectsGenerationMixingInvalidRanksScoresAndLimits() throws {
    let f = try HybridFixture(), identity = try f.identity()
    #expect(throws: EmbeddingContractError.invalidInput) { try HybridLexicalCandidate(identity: identity, title: "T", rank: 0) }
    #expect(throws: EmbeddingContractError.invalidInput) { try HybridSearchRanking.fuse(query: "", lexical: [], semantic: [], generation: f.generation, limit: -1) }
    let other = try HybridFixture()
    #expect(throws: EmbeddingContractError.incompatibleGeneration) {
        try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: [other.semantic(other.identity(), title: "Other")], generation: f.generation)
    }
    let chunk = try EmbeddingChunk(identity: identity, chunkID: "paragraph/0/0", ordinal: 0,
        contentFingerprint: "hash", chunkingVersion: EmbeddingChunker.version)
    for score in [Double.nan, .infinity, 1.01, -1.01] {
        #expect(throws: EmbeddingContractError.invalidVector) { try SemanticSearchPassage(chunk: chunk, cosineSimilarity: score) }
    }
}

@Test func hybridRankingStableTiesLimitsDuplicateAndStaleEvidence() throws {
    let f = try HybridFixture(), a = try f.identity(), b = try f.identity(), c = try f.identity()
    let semantic = try [f.semantic(c, title: "Zulu"), f.semantic(b, title: "Alpha"), f.semantic(a, title: "Alpha")]
    let one = try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: semantic, generation: f.generation)
    let two = try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: semantic.reversed(), generation: f.generation)
    #expect(one.map(\.identity) == two.map(\.identity))
    #expect(one.last?.identity == c)
    let limited = try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: semantic, generation: f.generation, limit: 2)
    #expect(limited.map(\.identity) == one.prefix(2).map(\.identity))
    let duplicate = try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: [semantic[0], semantic[0]], generation: f.generation)
    #expect(duplicate.count == 1)
    let newer = try f.identity(id: c.entityID, revision: "r2")
    let stale = try HybridSearchRanking.fuse(query: "q", lexical: [.init(identity: newer, title: "Current", rank: 1)],
        semantic: [semantic[0]], generation: f.generation)
    #expect(stale.first?.provenance == .text)
    #expect(stale.first?.passages.isEmpty == true)
}

@Test func hybridRankingFusedScoreTiesUseTitleThenIdentityAndKeepKindsDistinct() throws {
    let f = try HybridFixture(), sharedID = UUID()
    let page = try f.identity(id: sharedID), source = try f.identity(.source, id: sharedID)
    let lexical = try [HybridLexicalCandidate(identity: source, title: "Zulu", rank: 1),
                       HybridLexicalCandidate(identity: page, title: "Alpha", rank: 2)]
    let semantic = try [f.semantic(page, title: "Alpha", scores: [0.99]), f.semantic(source, title: "Zulu", scores: [0.8])]
    let results = try HybridSearchRanking.fuse(query: "topic", lexical: lexical, semantic: semantic, generation: f.generation)
    #expect(results.count == 2)
    #expect(results[0].score == results[1].score)
    #expect(results[0].identity == page)
    let sameTitle = try [HybridLexicalCandidate(identity: source, title: "Same", rank: 1),
                         HybridLexicalCandidate(identity: page, title: "Same", rank: 2)]
    let sameSemantic = try [f.semantic(page, title: "Same", scores: [0.99]), f.semantic(source, title: "Same", scores: [0.8])]
    #expect(try HybridSearchRanking.fuse(query: "topic", lexical: sameTitle, semantic: sameSemantic,
        generation: f.generation).first?.identity == page)
}

@Test func hybridRankingFiltersLexicalScopeAndRejectsConflictingSemanticDuplicates() throws {
    let f = try HybridFixture(), page = try f.identity(), source = try f.identity(.source)
    let lexical = try [HybridLexicalCandidate(identity: page, title: "Page", rank: 1),
                       HybridLexicalCandidate(identity: source, title: "Source", rank: 2)]
    #expect(try HybridSearchRanking.fuse(query: "q", lexical: lexical, semantic: [], generation: f.generation, scope: .sources).map(\.identity) == [source])
    #expect(try HybridSearchRanking.fuse(query: "q", lexical: lexical, semantic: [], generation: f.generation, scope: .blocks).isEmpty)
    let a = try f.semantic(page, title: "Page"), b = try f.semantic(page, title: "Page", scores: [0.8])
    #expect(throws: EmbeddingContractError.invalidIdentity) {
        try HybridSearchRanking.fuse(query: "q", lexical: [], semantic: [a, b], generation: f.generation)
    }
}
