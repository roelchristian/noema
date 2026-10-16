import Foundation

/// Metadata-only passage evidence. A locator is usable only after canonical revalidation.
public struct SemanticSearchPassage: Sendable, Equatable {
    public let chunk: EmbeddingChunk
    public let cosineSimilarity: Double

    public init(chunk: EmbeddingChunk, cosineSimilarity: Double) throws {
        guard cosineSimilarity.isFinite, (-1...1).contains(cosineSimilarity) else {
            throw EmbeddingContractError.invalidVector
        }
        self.chunk = chunk
        self.cosineSimilarity = cosineSimilarity
    }
}

/// One completed indexed document, not proof of current canonical content or vault coverage.
/// No vectors, original text, consent, or execution authority are retained here.
public struct SemanticSearchCandidate: Sendable, Equatable {
    public let generation: EmbeddingIndexGeneration
    public let completion: EmbeddingDocumentCompletion
    public let passages: [SemanticSearchPassage]
    public var identity: EmbeddingEntityIdentity { completion.identity }
    public var cosineSimilarity: Double { passages.first?.cosineSimilarity ?? -1 }

    public init(generation: EmbeddingIndexGeneration, completion: EmbeddingDocumentCompletion,
                passages: [SemanticSearchPassage]) throws {
        guard completion.identity.vaultID == generation.vaultID,
              completion.chunkCount > 0, !passages.isEmpty,
              passages.count <= completion.chunkCount,
              passages.allSatisfy({ $0.chunk.identity == completion.identity &&
                  $0.chunk.chunkingVersion == generation.chunkingVersion }),
              Set(passages.map(\.chunk.chunkID)).count == passages.count else {
            throw EmbeddingContractError.invalidChunk
        }
        self.generation = generation
        self.completion = completion
        self.passages = passages.sorted {
            if $0.cosineSimilarity != $1.cosineSimilarity { return $0.cosineSimilarity > $1.cosineSimilarity }
            if $0.chunk.ordinal != $1.chunk.ordinal { return $0.chunk.ordinal < $1.chunk.ordinal }
            return $0.chunk.chunkID < $1.chunk.chunkID
        }
    }
}
