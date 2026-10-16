import Foundation

public enum HybridSearchScope: Sendable { case all, pages, sources, blocks }
public enum HybridSearchProvenance: String, Sendable, Equatable {
    case text = "Text match", meaning = "Related passage", both = "Text and meaning"
}

/// Current canonical metadata supplied by composition. Rank is the one-based FTS ordinal,
/// never a BM25 score. In blocks scope IDs identify current matched tagged blocks.
public struct HybridLexicalCandidate: Sendable {
    public let identity: EmbeddingEntityIdentity
    public let title: String
    public let aliases: [String]
    public let excerpt: String
    public let rank: Int
    public let currentSemanticBlockIDs: Set<UUID>
    public init(identity: EmbeddingEntityIdentity, title: String, aliases: [String] = [],
                excerpt: String = "", rank: Int, currentSemanticBlockIDs: Set<UUID> = []) throws {
        guard rank > 0 else { throw EmbeddingContractError.invalidInput }
        self.identity = identity; self.title = title; self.aliases = aliases
        self.excerpt = excerpt; self.rank = rank; self.currentSemanticBlockIDs = currentSemanticBlockIDs
    }
}

/// Caller must validate current canonical revision and original bytes before wrapping evidence.
/// Fusion performs no I/O and cannot certify that a caller-supplied snapshot remains current.
public struct HybridSemanticCandidate: Sendable {
    public let candidate: SemanticSearchCandidate
    public let title: String
    public let aliases: [String]
    public let currentSemanticBlockIDs: Set<UUID>
    public init(candidate: SemanticSearchCandidate, title: String, aliases: [String] = [],
                currentSemanticBlockIDs: Set<UUID> = []) {
        self.candidate = candidate; self.title = title; self.aliases = aliases
        self.currentSemanticBlockIDs = currentSemanticBlockIDs
    }
}

public struct HybridSearchResult: Sendable {
    public let identity: EmbeddingEntityIdentity
    public let title: String
    public let excerpt: String?
    public let provenance: HybridSearchProvenance
    public let lexicalRank: Int?
    public let semanticRank: Int?
    /// Reciprocal rank fusion score, never probability or confidence.
    public let score: Double
    public let passages: [SemanticSearchPassage]
    public let generation: EmbeddingIndexGeneration?
    public let completion: EmbeddingDocumentCompletion?
}

public enum HybridSearchRanking {
    public static let reciprocalRankConstant = 60.0
    private static func key(_ identity: EmbeddingEntityIdentity) -> String {
        identity.entityKind.rawValue + "/" + identity.entityID.uuidString
    }
    private static func allows(_ identity: EmbeddingEntityIdentity, scope: HybridSearchScope) -> Bool {
        switch scope {
        case .all: true
        case .pages, .blocks: identity.entityKind == .page
        case .sources: identity.entityKind == .source
        }
    }
    private static func titleKey(_ title: String, _ identity: EmbeddingEntityIdentity) -> String {
        normalized(title) + "\u{0}" + key(identity)
    }

    /// Equal-weight RRF after document aggregation. Lexical-only fallback preserves FTS order.
    /// Hybrid ties use normalized title, entity kind then UUID, independent of locale.
    /// In blocks scope only passages targeting explicitly supplied current tagged IDs qualify.
    public static func fuse(query: String, lexical: [HybridLexicalCandidate],
                            semantic: [HybridSemanticCandidate], generation: EmbeddingIndexGeneration,
                            scope: HybridSearchScope = .all, limit: Int = 100) throws -> [HybridSearchResult] {
        guard limit >= 0 else { throw EmbeddingContractError.invalidInput }
        guard lexical.allSatisfy({ $0.identity.vaultID == generation.vaultID }),
              semantic.allSatisfy({ $0.candidate.generation == generation }) else {
            throw EmbeddingContractError.incompatibleGeneration
        }
        if limit == 0 { return [] }
        var texts: [String: HybridLexicalCandidate] = [:]
        var textOrder: [String] = []
        for item in lexical.enumerated().sorted(by: {
            $0.element.rank == $1.element.rank ? $0.offset < $1.offset : $0.element.rank < $1.element.rank
        }).map(\.element) where allows(item.identity, scope: scope) {
            if scope == .blocks && item.currentSemanticBlockIDs.isEmpty { continue }
            let id = key(item.identity)
            if texts[id] == nil { texts[id] = item; textOrder.append(id) }
        }
        var meanings: [String: HybridSemanticCandidate] = [:]
        var evidence: [String: [SemanticSearchPassage]] = [:]
        for item in semantic where allows(item.candidate.identity, scope: scope) {
            let id = key(item.candidate.identity)
            let passages = item.candidate.passages.filter { passage in
                guard let locator = SemanticPassageLocator(chunkID: passage.chunk.chunkID,
                                                           entityKind: passage.chunk.identity.entityKind) else { return false }
                if scope != .blocks { return true }
                if case .block(let blockID, _) = locator { return item.currentSemanticBlockIDs.contains(blockID) }
                return false
            }
            guard !passages.isEmpty else { continue }
            if let text = texts[id], text.identity != item.candidate.identity {
                // A newer lexical snapshot must not acquire stale semantic provenance.
                continue
            }
            if let previous = meanings[id] {
                guard previous.candidate == item.candidate, previous.title == item.title,
                      previous.aliases == item.aliases, evidence[id] == passages else {
                    throw EmbeddingContractError.invalidIdentity
                }
                continue
            }
            meanings[id] = item; evidence[id] = passages
        }
        let meaningOrder = meanings.keys.sorted {
            let lhs = evidence[$0]!.first!.cosineSimilarity, rhs = evidence[$1]!.first!.cosineSimilarity
            if lhs != rhs { return lhs > rhs }
            return titleKey(meanings[$0]!.title, meanings[$0]!.candidate.identity) < titleKey(meanings[$1]!.title, meanings[$1]!.candidate.identity)
        }
        let ranks = Dictionary(uniqueKeysWithValues: meaningOrder.enumerated().map { ($0.element, $0.offset + 1) })
        let ids = textOrder + meaningOrder.filter { texts[$0] == nil }
        var results = ids.map { id -> HybridSearchResult in
            let text = texts[id], meaning = meanings[id]
            let rankL = text?.rank, rankS = ranks[id]
            return HybridSearchResult(identity: text?.identity ?? meaning!.candidate.identity,
                title: text?.title ?? meaning!.title, excerpt: text?.excerpt,
                provenance: rankL == nil ? .meaning : rankS == nil ? .text : .both,
                lexicalRank: rankL, semanticRank: rankS,
                score: (rankL.map { 1 / (reciprocalRankConstant + Double($0)) } ?? 0)
                    + (rankS.map { 1 / (reciprocalRankConstant + Double($0)) } ?? 0),
                passages: evidence[id] ?? [], generation: meaning?.candidate.generation,
                completion: meaning?.candidate.completion)
        }
        if !meanings.isEmpty {
            let queryKey = normalized(query)
            func exact(_ result: HybridSearchResult) -> Bool {
                let id = key(result.identity)
                let aliases = texts[id]?.aliases ?? meanings[id]?.aliases ?? []
                return !queryKey.isEmpty && ([result.title] + aliases).contains { normalized($0) == queryKey }
            }
            results.sort {
                if exact($0) != exact($1) { return exact($0) }
                if $0.score != $1.score { return $0.score > $1.score }
                return titleKey($0.title, $0.identity) < titleKey($1.title, $1.identity)
            }
        }
        return Array(results.prefix(limit))
    }
}
