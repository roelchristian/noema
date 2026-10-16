import Foundation

/// Transient observation of current canonical evidence, never inference or publication authority.
/// Retains bounded text and metadata, not full original bytes or provider query input.
public struct SemanticContextEvidence: Sendable {
    public let candidate: SemanticSearchCandidate
    public let title: String
    public let aliases: [String]
    public let excerpt: String
    public let currentSemanticBlockIDs: Set<UUID>
    public let canonicalRevision: BlockStoreRevision
    public let permit: EmbeddingPublicationPermit
    public let queryScope: EmbeddingProcessingScope
    fileprivate let scope: HybridSearchScope
}

/// Provider-neutral, read-only context retrieval for search and later consumers. The supplied
/// vector must already be authorized and belong to the selected vector space. This actor never
/// embeds, sends requests, schedules work, modifies canonical content or generates enrichment.
///
/// Each return value is an observation, not a promise of permanent currentness. Callers revalidate
/// bounded evidence and publish synchronously under their exact-query publication authority and
/// EmbeddingPublicationPermit.withPublication(permits:authority:). No await or access-gate call
/// belongs inside that final assignment. Linked originals remain externally mutable after their
/// last validation; no SQLite permit can make external bytes transactional.
public actor SemanticContextRetrieval {
    private let repository: FileVaultRepository
    private let index: SQLiteEmbeddingIndex
    private let generation: EmbeddingIndexGeneration
    private let lease: VaultSessionLease
    private let extractOriginal: @Sendable (SourceSummarySnapshot) throws -> String

    public init(repository: FileVaultRepository, index: SQLiteEmbeddingIndex,
                generation: EmbeddingIndexGeneration, lease: VaultSessionLease,
                extractOriginal: @escaping @Sendable (SourceSummarySnapshot) throws -> String) throws {
        guard repository.sessionLease == lease, repository.manifest.id == lease.vaultID, generation.vaultID == lease.vaultID,
              repository.root.standardizedFileURL == lease.root.standardizedFileURL else {
            throw EmbeddingContractError.authorityDenied
        }
        guard generation.chunkingVersion == EmbeddingChunker.version else {
            throw EmbeddingContractError.incompatibleGeneration
        }
        self.repository = repository; self.index = index; self.generation = generation
        self.lease = lease; self.extractOriginal = extractOriginal
    }

    private func check(_ context: EmbeddingExecutionContext) throws {
        guard context.lease == lease, context.model == generation.model,
              case .query(let vaultID, _) = context.scope, vaultID == lease.vaultID else {
            throw EmbeddingContractError.authorityDenied
        }
        try context.validate(scope: context.scope, model: generation.model)
        try repository.validateAccess(operation: "semanticContext.retrieve")
    }
    private static func key(_ kind: AIEntityKind, _ id: UUID) -> String { kind.rawValue + "/" + id.uuidString }

    public func retrieve(vector: EmbeddingVector, scope: HybridSearchScope,
                         context: EmbeddingExecutionContext, limit: Int = 40,
                         taggedBlocks: [UUID: Set<UUID>] = [:]) async throws -> [SemanticContextEvidence] {
        try check(context)
        guard vector.model == generation.model else { throw EmbeddingContractError.incompatibleGeneration }
        guard (1...100).contains(limit) else { throw EmbeddingContractError.invalidInput }
        if scope == .blocks && taggedBlocks.isEmpty { return [] }
        let inventory = try await repository.aiProcessingInventory()
        try check(context)
        let revisions = Dictionary(uniqueKeysWithValues: inventory.filter { $0.kind != .removed }.map {
            (Self.key($0.entityKind, $0.entityID), $0.revision)
        })
        let requiresTaggedBlocks = scope == .blocks
        let isCurrent: @Sendable (EmbeddingDocumentCompletion) throws -> Bool = { completion in
            if requiresTaggedBlocks && taggedBlocks[completion.identity.entityID]?.isEmpty != false { return false }
            guard completion.identity.vaultID == context.lease.vaultID,
                  revisions[Self.key(completion.identity.entityKind, completion.identity.entityID)] == completion.identity.revision else { return false }
            if completion.identity.entityKind == .source {
                guard let original = completion.originalFingerprint else { return false }
                return completion.workRevision == completion.identity.revision ||
                    completion.workRevision == completion.identity.revision + ":" + original
            }
            return completion.workRevision == completion.identity.revision
        }
        let validateQuery: @Sendable () throws -> Void = {
            try context.validate(scope: context.scope, model: vector.model)
        }
        let kind: AIEntityKind?
        switch scope { case .all: kind = nil; case .pages, .blocks: kind = .page; case .sources: kind = .source }
        try check(context)
        let usable = try await index.hasCompletedSearchDocuments(generation: generation, kind: kind,
            isCurrent: isCurrent, validateQuery: validateQuery)
        try check(context)
        guard usable else { return [] }
        // Caller supplies its current tagged-block catalog for filtering before top-K; hydration
        // independently verifies actual canonical tags. An absent catalog fails closed.
        let isPassageEligible: (@Sendable (EmbeddingChunk) throws -> Bool)?
        if scope == .blocks {
            isPassageEligible = { @Sendable chunk in
                guard chunk.identity.entityKind == .page,
                      let locator = SemanticPassageLocator(chunkID: chunk.chunkID, entityKind: .page),
                      case .block(let id, _) = locator else { return false }
                return taggedBlocks[chunk.identity.entityID]?.contains(id) == true
            }
        } else { isPassageEligible = nil }
        let candidates = try await index.searchCandidates(query: vector, generation: generation,
            documentLimit: limit, passagesPerDocument: 3,
            kind: kind, isCurrent: isCurrent, isPassageEligible: isPassageEligible, validateQuery: validateQuery)
        try check(context)
        var result: [SemanticContextEvidence] = []
        for candidate in candidates {
            try check(context)
            if let evidence = try await hydrate(candidate, scope: scope, context: context) { result.append(evidence) }
            try check(context)
            if result.count == limit { break }
        }
        try check(context)
        return result
    }

    /// Rehydrates one bounded result without retaining a vault's originals. Stale or unavailable
    /// content is omitted; authority loss and cancellation still throw. Refreshed evidence must
    /// participate in the caller's final multi-permit assignment barrier.
    public func validate(evidence: SemanticContextEvidence, context: EmbeddingExecutionContext) async throws -> SemanticContextEvidence? {
        try check(context)
        guard evidence.queryScope == context.scope, evidence.candidate.generation == generation else {
            throw EmbeddingContractError.authorityDenied
        }
        let expectedCompletion = evidence.candidate.completion
        let stillCompleted = try await index.searchCompletion(identity: expectedCompletion.identity,
            generation: generation, validateQuery: { try context.validate(scope: context.scope, model: context.model) })
        try check(context)
        guard stillCompleted == expectedCompletion else { return nil }
        let result = try await hydrate(evidence.candidate, scope: evidence.scope, context: context)
        try check(context)
        return result
    }

    private func hydrate(_ candidate: SemanticSearchCandidate, scope: HybridSearchScope,
                         context: EmbeddingExecutionContext) async throws -> SemanticContextEvidence? {
        do {
            try check(context)
            guard candidate.generation == generation else { throw EmbeddingContractError.incompatibleGeneration }
            let identity = candidate.identity
            let current: EmbeddingPreparedInputSnapshot
            let title: String, aliases: [String], taggedIDs: Set<UUID>
            switch identity.entityKind {
            case .page:
                let page = try await repository.sqliteBlockStore.loadPage(pageID: identity.entityID)
                try check(context)
                current = try await repository.embeddingPageSnapshot(id: identity.entityID,
                    expectedRevision: identity.revision, model: generation.model)
                try check(context)
                guard page.snapshot.revision == current.canonicalRevision else { return nil }
                title = page.record.title; aliases = page.record.aliases
                taggedIDs = Set(page.snapshot.document.semanticGroups.flatMap(\.blocks).map(\.id))
            case .source:
                guard scope != .blocks, candidate.completion.originalFingerprint != nil else { return nil }
                current = try await repository.embeddingSourceSnapshot(id: identity.entityID,
                    expectedRevision: candidate.completion.workRevision, model: generation.model, extractOriginal: extractOriginal)
                try check(context)
                guard let source = current.sourceEvidence else { return nil }
                title = source.source.title; aliases = []; taggedIDs = []
            }
            guard current.identity == identity, current.inputs.count == candidate.completion.chunkCount,
                  current.inputFingerprint == candidate.completion.inputFingerprint,
                  current.originalFingerprint == candidate.completion.originalFingerprint else { return nil }
            var passages: [SemanticSearchPassage] = []
            var excerpt: String?
            for passage in candidate.passages {
                guard let input = SemanticPassageLocator.resolve(passage: passage, generation: candidate.generation,
                    selectedGeneration: generation, current: current) else { return nil }
                if scope == .blocks {
                    guard let locator = SemanticPassageLocator(chunkID: input.chunk.chunkID, entityKind: .page),
                          case .block(let id, _) = locator, taggedIDs.contains(id) else { continue }
                }
                passages.append(passage)
                if excerpt == nil { excerpt = String(input.text.prefix(600)) }
            }
            guard !passages.isEmpty, let excerpt else { return nil }
            try check(context)
            try await repository.validateEmbeddingSnapshot(current)
            try check(context)
            let permit: EmbeddingPublicationPermit
            switch identity.entityKind {
            case .page:
                permit = try await repository.sqliteBlockStore.embeddingPublicationPermit(pageID: identity.entityID, expected: current.canonicalRevision)
            case .source:
                permit = try await repository.sqliteBlockStore.embeddingPublicationPermit(sourceID: identity.entityID, expected: current.canonicalRevision)
            }
            try check(context)
            let filtered = try SemanticSearchCandidate(generation: generation, completion: candidate.completion, passages: passages)
            return SemanticContextEvidence(candidate: filtered, title: title, aliases: aliases, excerpt: excerpt,
                currentSemanticBlockIDs: taggedIDs, canonicalRevision: current.canonicalRevision, permit: permit,
                queryScope: context.scope, scope: scope)
        } catch {
            try check(context)
            if error is CancellationError { throw error }
            return nil
        }
    }
}
