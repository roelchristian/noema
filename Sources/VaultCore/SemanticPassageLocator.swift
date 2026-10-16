import Foundation

/// Structural syntax only. Parsing never establishes currentness or navigation authority.
public enum SemanticPassageLocator: Sendable, Equatable {
    case block(UUID, segment: Int)
    case paragraph(Int, segment: Int)

    public init?(chunkID: String, entityKind: AIEntityKind) {
        let parts = chunkID.split(separator: "/", omittingEmptySubsequences: false)
        func index(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(text), String(value) == text else { return nil }
            return value
        }
        guard parts.count == 3, let segment = index(parts[2]) else { return nil }
        switch entityKind {
        case .page:
            guard parts[0] == "block", let block = UUID(uuidString: String(parts[1])) else { return nil }
            self = .block(block, segment: segment)
        case .source:
            guard parts[0] == "paragraph", let paragraph = index(parts[1]) else { return nil }
            self = .paragraph(paragraph, segment: segment)
        }
    }

    /// Hydrates only exact current chunk evidence under the selected vector space. The caller
    /// supplies freshly prepared canonical inputs and independently validates Source originals.
    /// Missing, moved, edited or regenerated locators return nil; no approximate navigation.
    public static func resolve(passage: SemanticSearchPassage, generation: EmbeddingIndexGeneration,
                               selectedGeneration: EmbeddingIndexGeneration,
                               current: EmbeddingPreparedInputSnapshot) -> EmbeddingChunkInput? {
        guard generation == selectedGeneration, generation.model == current.model, generation.vaultID == current.identity.vaultID,
              generation.chunkingVersion == EmbeddingChunker.version,
              passage.chunk.chunkingVersion == generation.chunkingVersion,
              passage.chunk.identity == current.identity,
              SemanticPassageLocator(chunkID: passage.chunk.chunkID, entityKind: current.identity.entityKind) != nil else { return nil }
        return current.inputs.first { $0.chunk == passage.chunk }
    }
}
