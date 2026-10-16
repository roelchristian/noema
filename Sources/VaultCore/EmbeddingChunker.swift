import Foundation
import NaturalLanguage

/// Transient provider input. Only `chunk` belongs in the derived index; text is never persisted here.
public struct EmbeddingChunkInput: Sendable, Equatable {
    public let chunk: EmbeddingChunk
    public let text: String
}

/// Pure chunking of a caller-supplied committed snapshot. This type never reads canonical storage.
public enum EmbeddingChunker {
    public static let version = "block-source-v2"

    public static func page(_ document: BlockDocument, identity: EmbeddingEntityIdentity,
                            model: EmbeddingModelDescriptor) throws -> [EmbeddingChunkInput] {
        guard identity.entityKind == .page else { throw EmbeddingContractError.invalidInput }
        var pieces: [(String, String)] = []
        func visit(_ blocks: [EditorBlock]) throws {
            for block in blocks {
                // An AI-derived parent excludes its complete subtree, even if children lack a marker.
                guard block.metadata.extra["aiGenerated"] != "true" else { continue }
                for (part, text) in try split(block.text, model: model).enumerated() {
                    pieces.append(("block/\(block.id.uuidString)/\(part)", text))
                }
                try visit(block.children)
            }
        }
        try visit(document.blocks)
        return try inputs(pieces, identity: identity)
    }

    /// `originalText` must be extracted original content, never a generated summary or metadata body.
    public static func source(originalText: String, identity: EmbeddingEntityIdentity,
                              model: EmbeddingModelDescriptor) throws -> [EmbeddingChunkInput] {
        guard identity.entityKind == .source else { throw EmbeddingContractError.invalidInput }
        var paragraphs: [String] = [], lines: [String] = []
        // Treat a Windows line ending as one separator, not an empty paragraph.
        let normalized = originalText.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")); lines = [] }
            } else { lines.append(line) }
        }
        if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
        var pieces: [(String, String)] = []
        for (paragraph, text) in paragraphs.enumerated() {
            for (part, segment) in try split(text, model: model).enumerated() {
                pieces.append(("paragraph/\(paragraph)/\(part)", segment))
            }
        }
        return try inputs(pieces, identity: identity)
    }

    private static func inputs(_ pieces: [(String, String)], identity: EmbeddingEntityIdentity) throws -> [EmbeddingChunkInput] {
        try pieces.enumerated().map { ordinal, piece in
            let chunk = try EmbeddingChunk(identity: identity, chunkID: piece.0, ordinal: ordinal,
                                           contentFingerprint: digest(Data(piece.1.utf8)), chunkingVersion: version)
            return EmbeddingChunkInput(chunk: chunk, text: piece.1)
        }
    }

    /// Respect UTF-8 provider bounds without splitting grapheme clusters. Oversized individual
    /// graphemes fail explicitly rather than silently deleting or altering original content.
    private static func split(_ text: String, model: EmbeddingModelDescriptor) throws -> [String] {
        let limit = model.maximumInputUTF8Bytes
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let characters = Array(text)
        let sizes = characters.map { String($0).utf8.count }
        guard sizes.allSatisfy({ $0 <= limit }) else { throw EmbeddingContractError.invalidInput }
        let overlap = min(128, limit / 8)
        var start = 0, results: [String] = []
        while start < characters.count {
            var end = start, bytes = 0, boundary: Int?
            while end < characters.count && bytes + sizes[end] <= limit {
                bytes += sizes[end]
                end += 1
                if characters[end - 1].isWhitespace && bytes >= limit / 2 { boundary = end }
            }
            if end < characters.count, let boundary { end = boundary }
            // Native sentence embeddings impose an independent tokenizer bound. A byte-only
            // split can exceed it for short words, so shorten at the first excluded token.
            if let language = EmbeddingInputPreparation.nativeLanguage(model) {
                let candidate = String(characters[start..<end])
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.setLanguage(NLLanguage(rawValue: language))
                tokenizer.string = candidate
                var words = 0, cutoff: String.Index?
                tokenizer.enumerateTokens(in: candidate.startIndex..<candidate.endIndex) { range, _ in
                    words += 1
                    if words > 128 { cutoff = range.lowerBound; return false }
                    return true
                }
                if let cutoff {
                    end = start + candidate.distance(from: candidate.startIndex, to: cutoff)
                }
            }
            guard end > start else { throw EmbeddingContractError.invalidInput }
            let segment = String(characters[start..<end])
            if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { results.append(segment) }
            guard end < characters.count else { break }
            var next = end, overlapBytes = 0
            while next > start + 1 && overlapBytes + sizes[next - 1] <= overlap {
                next -= 1; overlapBytes += sizes[next]
            }
            start = next
        }
        return results
    }
}
