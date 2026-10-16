import Foundation
import ExternalAI
import VaultCore

extension AppModel {
    func retireMeaningSearch() {
        meaningNavigationID = UUID()
        if !sidebarSearchResults.hybridOrder.isEmpty {
            sidebarSearchResults = meaningLexicalFallback.flatMap { $0.query == searchText ? $0 : nil } ?? SidebarSearchResults()
            searchStatus = sidebarSearchResults.query == searchText && isSearching ? .results : .idle
        }
        meaningLexicalFallback = nil
        meaningEpoch?.invalidate(); meaningEpoch = nil
        meaningAdapter?.invalidate(); meaningAdapter = nil
        meaningTask?.cancel(); meaningTask = nil
        meaningSubmissionID = nil; meaningEvidence = [:]
        pendingSemanticQueryDisclosure = nil
        meaningApproval?.resume(returning: false); meaningApproval = nil
        semanticSearchStatus = searchRetrievalMode == .meaning && isSearching ? .needsSubmission : .idle
    }

    func cancelMeaningSearch() { retireMeaningSearch() }

    func setSearchRetrievalMode(_ mode: VaultSearchRetrievalMode) {
        guard mode != searchRetrievalMode else { return }
        retireMeaningSearch(); searchRetrievalMode = mode
        queryChanged()
    }

    func approveSemanticQuery(queryID: UUID) {
        guard pendingSemanticQueryDisclosure?.id == queryID, meaningSubmissionID == queryID,
              canOperateOnLoadedContent else { return }
        pendingSemanticQueryDisclosure = nil
        let continuation = meaningApproval; meaningApproval = nil
        continuation?.resume(returning: true)
    }

    func declineSemanticQuery(queryID: UUID) {
        guard pendingSemanticQueryDisclosure?.id == queryID else { return }
        pendingSemanticQueryDisclosure = nil
        let continuation = meaningApproval; meaningApproval = nil
        semanticSearchStatus = .declined
        continuation?.resume(returning: false)
    }

    func submitMeaningSearch() {
        guard searchRetrievalMode == .meaning, searchMode == .vault, isSearching,
              canOperateOnLoadedContent, canInteractWithWorkspace else { return }
        retireMeaningSearch()
        queryTask?.cancel(); queryTask = nil
        let id = UUID(), query = searchText, requestedScope = searchScope
        let epoch = MeaningSearchEpoch()
        meaningEpoch = epoch; meaningSubmissionID = id; semanticSearchStatus = .preparing
        meaningTask = Task { [weak self] in
            guard let self else { return }
            // Settle keyword results first. This is the only explicit Meaning execution entry.
            await updateRows(keepingMeaningSubmission: true)
            guard meaningSubmissionID == id else { return }
            let revision = searchRevision
            let ticket = issueCompletionTicket(kind: .search, capturedText: query)
            do {
                try epoch.validate()
                guard let repository, let index = semanticIndex,
                      let lease = sessionManager.accessGate.currentLease,
                      let selected = semanticProcessingGeneration else {
                    semanticSearchStatus = .unavailable("Keyword results only. Build a semantic index in Semantic Indexing.")
                    return
                }
                let configuration = vaultAIConfigurationStore.configuration(for: lease.vaultID)
                guard configuration.enabled else {
                    semanticSearchStatus = .unavailable("Keyword results only. Enable intelligence and semantic indexing for this vault.")
                    return
                }
                let provider: (any EmbeddingProvider)? = configuration.provider == .onDevice ? try embeddingProviderFactory() : nil
                let model = provider?.descriptor ?? externalAIService.embeddingConfiguration.embeddingDescriptor
                guard selected.vaultID == lease.vaultID, selected.model == model,
                      selected.chunkingVersion == EmbeddingChunker.version else {
                    semanticSearchStatus = .unavailable("Keyword results only. The selected model requires a compatible rebuilt index.")
                    return
                }
                let policy = try vaultAIConfigurationStore.processingPolicyValidation(lease: lease, gate: sessionManager.accessGate)
                let validate: @Sendable () throws -> Void = { try epoch.validate(); try policy() }
                @MainActor func current() throws {
                    try validate()
                    guard self.meaningSubmissionID == id, self.searchRevision == revision,
                          self.searchText == query, self.searchScope == requestedScope,
                          self.searchMode == .vault, self.searchRetrievalMode == .meaning,
                          self.repository === repository, self.semanticIndex === index,
                          self.semanticProcessingGeneration == selected,
                          self.vaultAIConfigurationStore.configuration(for: lease.vaultID) == configuration,
                          self.isCompletionValid(ticket, currentText: self.searchText, operation: "meaningSearch") else {
                        throw CancellationError()
                    }
                }
                let inventory = try await repository.aiProcessingInventory()
                try current()
                let revisions = Dictionary(inventory.filter { $0.kind != .removed }.map {
                    (Self.meaningKey($0.entityKind, $0.entityID), $0.revision)
                }, uniquingKeysWith: { first, _ in first })
                let capturedNotes = notes
                let taggedBlocks: [UUID: Set<UUID>]
                if requestedScope == .blocks {
                    taggedBlocks = await Task.detached {
                        Dictionary(capturedNotes.filter { revisions[Self.meaningKey(.page, $0.id)] == $0.contentHash }.map { note in
                            (note.id, Set(BlockDocumentCodec.decode(note.body).flattened.filter { $0.metadata.semantic != nil }.map(\.id)))
                        }, uniquingKeysWith: { first, _ in first })
                    }.value
                    try current()
                } else { taggedBlocks = [:] }
                let eligible: @Sendable (EmbeddingDocumentCompletion) throws -> Bool = { completion in
                    revisions[Self.meaningKey(completion.identity.entityKind, completion.identity.entityID)] == completion.identity.revision
                        && (completion.identity.entityKind == .page || completion.originalFingerprint != nil)
                        && (requestedScope != .blocks || taggedBlocks[completion.identity.entityID]?.isEmpty == false)
                }
                let kind: AIEntityKind? = requestedScope == .sources ? .source : requestedScope == .all ? nil : .page
                guard try await index.hasCompletedSearchDocuments(generation: selected, kind: kind,
                    isCurrent: eligible, validateQuery: validate) else {
                    try current()
                    semanticSearchStatus = .unavailable("Keyword results only. No current completed passages are available in this scope. Build or rebuild Semantic Indexing; older Source indexes need original-file evidence.")
                    return
                }
                try current()
                let adapter: SemanticQueryExecutionAdapter
                if let provider {
                    adapter = try .native(provider: provider, lease: lease, generation: selected,
                        accessGate: sessionManager.accessGate, queryID: id, validateCurrentAuthority: validate)
                } else {
                    adapter = try .cloud(service: externalAIService, lease: lease, generation: selected,
                        accessGate: sessionManager.accessGate, queryID: id, validateCurrentAuthority: validate,
                        approveQuery: { [weak self] request in
                            guard let self else { throw CancellationError() }
                            try current()
                            self.semanticSearchStatus = .awaitingApproval
                            self.pendingSemanticQueryDisclosure = .init(id: id, query: query,
                                provider: "OpenAI", model: request.model.modelID)
                            let approved = await withCheckedContinuation { continuation in
                                self.meaningApproval = continuation
                            }
                            try current()
                            return approved
                        })
                }
                meaningAdapter = adapter
                semanticSearchStatus = .searching
                let completed = try await adapter.execute(query: query)
                try current(); try completed.validatePublication()
                let passageFilter: (@Sendable (EmbeddingChunk) throws -> Bool)?
                if requestedScope == .blocks {
                    passageFilter = { @Sendable chunk in
                        guard case .block(let blockID, _) = SemanticPassageLocator(chunkID: chunk.chunkID, entityKind: chunk.identity.entityKind) else { return false }
                        return taggedBlocks[chunk.identity.entityID]?.contains(blockID) == true
                    }
                } else { passageFilter = nil }
                let candidates = try await index.searchCandidates(query: completed.vector, generation: selected,
                    documentLimit: 40, passagesPerDocument: 3, kind: kind,
                    isCurrent: eligible, isPassageEligible: passageFilter, validateQuery: validate)
                try current(); try completed.validatePublication()
                let lexical = sidebarSearchResults
                meaningLexicalFallback = lexical
                var pageMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var semantic: [HybridSemanticCandidate] = []
                var evidence: [String: MeaningSearchEvidence] = [:]
                var permits: [EmbeddingPublicationPermit] = []
                var excerpts: [String: String] = [:]
                // Only the bounded winners hydrate canonical passages and Source originals.
                for candidate in candidates {
                    try current()
                    do {
                        let snapshot: EmbeddingPreparedInputSnapshot
                        let title: String, aliases: [String], tagged: Set<UUID>
                        if candidate.identity.entityKind == .page {
                            let page = try await repository.sqliteBlockStore.loadPage(pageID: candidate.identity.entityID)
                            try current()
                            guard page.snapshot.revision.token.base64EncodedString() == candidate.identity.revision else { continue }
                            snapshot = try await repository.embeddingPageSnapshot(id: candidate.identity.entityID,
                                expectedRevision: candidate.identity.revision, model: model)
                            try current()
                            pageMap[candidate.identity.entityID] = page.record
                            title = page.record.title; aliases = page.record.aliases
                            tagged = Set(page.snapshot.document.flattened.filter { $0.metadata.semantic != nil }.map(\.id))
                        } else {
                            snapshot = try await repository.embeddingSourceSnapshot(id: candidate.identity.entityID,
                                expectedRevision: candidate.completion.workRevision, model: model,
                                extractOriginal: Self.embeddingOriginalText)
                            try current()
                            guard snapshot.originalFingerprint == candidate.completion.originalFingerprint,
                                  let source = snapshot.sourceRecord else { continue }
                            sourceMap[source.id] = SourceRecord(metadata: source.metadata, body: "", contentState: .notLoaded); title = source.title; aliases = []; tagged = []
                        }
                        guard snapshot.inputFingerprint == candidate.completion.inputFingerprint,
                              snapshot.inputs.count == candidate.completion.chunkCount,
                              snapshot.identity == candidate.identity else { continue }
                        let passages = candidate.passages.filter {
                            SemanticPassageLocator.resolve(passage: $0, generation: selected,
                                selectedGeneration: selected, current: snapshot) != nil
                        }
                        guard let passage = passages.first else { continue }
                        let validated = try SemanticSearchCandidate(generation: selected, completion: candidate.completion, passages: passages)
                        semantic.append(.init(candidate: validated, title: title, aliases: aliases, currentSemanticBlockIDs: tagged))
                        let key = Self.meaningKey(candidate.identity.entityKind, candidate.identity.entityID)
                        evidence[key] = .init(completion: candidate.completion, passage: passage, generation: selected)
                        excerpts[key] = String(snapshot.inputs.first(where: { $0.chunk == passage.chunk })!.text.prefix(600))
                        try await repository.validateEmbeddingSnapshot(snapshot)
                        try current()
                        let permit = candidate.identity.entityKind == .page
                            ? try await repository.sqliteBlockStore.embeddingPublicationPermit(pageID: candidate.identity.entityID, expected: snapshot.canonicalRevision)
                            : try await repository.sqliteBlockStore.embeddingPublicationPermit(sourceID: candidate.identity.entityID, expected: snapshot.canonicalRevision)
                        permits.append(permit)
                        try current()
                    } catch is CancellationError { throw CancellationError() }
                    catch { try current(); continue }
                }
                guard !semantic.isEmpty else {
                    semanticSearchStatus = .unavailable("Keyword results only. Indexed evidence is stale or unavailable; rebuild Semantic Indexing.")
                    return
                }
                var texts: [HybridLexicalCandidate] = []
                for (position, page) in lexical.pages.prefix(200).enumerated() {
                    let key = Self.meaningKey(.page, page.id)
                    guard let revision = revisions[key], let currentPage = pageMap[page.id], currentPage.contentHash == revision else { continue }
                    let tagged = Set(lexical.blocks.filter { $0.pageID == page.id }.map(\.blockID))
                    texts.append(try .init(identity: EmbeddingEntityIdentity(vaultID: lease.vaultID, entityKind: .page, entityID: page.id, revision: revision),
                        title: currentPage.title, aliases: currentPage.aliases, excerpt: lexical.pageExcerpts[page.id] ?? "", rank: position + 1, currentSemanticBlockIDs: tagged))
                }
                if requestedScope == .blocks {
                    for hit in lexical.blocks.prefix(200) where !texts.contains(where: { $0.identity.entityID == hit.pageID }) {
                        let key = Self.meaningKey(.page, hit.pageID)
                        guard let revision = revisions[key], let page = pageMap[hit.pageID], page.contentHash == revision else { continue }
                        texts.append(try .init(identity: EmbeddingEntityIdentity(vaultID: lease.vaultID, entityKind: .page,
                            entityID: page.id, revision: revision), title: page.title, aliases: page.aliases,
                            excerpt: hit.preview, rank: texts.count + 1,
                            currentSemanticBlockIDs: Set(lexical.blocks.filter { $0.pageID == page.id }.map(\.blockID))))
                    }
                }
                for (position, source) in lexical.sources.prefix(200).enumerated() {
                    let key = Self.meaningKey(.source, source.id)
                    guard let revision = revisions[key],
                          let metadata = try? await repository.sqliteBlockStore.sourceSnapshot(id: source.id) else { continue }
                    try current()
                    guard !metadata.trashed, metadata.revision.token.base64EncodedString() == revision else { continue }
                    let record = SourceRecord(metadata: try metadata.source.sourceMetadata(), body: "", contentState: .notLoaded)
                    sourceMap[source.id] = record
                    texts.append(try .init(identity: EmbeddingEntityIdentity(vaultID: lease.vaultID, entityKind: .source, entityID: source.id, revision: revision),
                        title: record.title, excerpt: lexical.sourceExcerpts[source.id] ?? "", rank: position + 1))
                }
                let rankingScope: HybridSearchScope = requestedScope == .blocks ? .blocks : requestedScope == .pages ? .pages : requestedScope == .sources ? .sources : .all
                let fused = try HybridSearchRanking.fuse(query: query, lexical: texts, semantic: semantic,
                    generation: selected, scope: rankingScope, limit: 200)
                var result = SidebarSearchResults(query: query)
                for item in fused {
                    let key = Self.meaningKey(item.identity.entityKind, item.identity.entityID)
                    result.hybridOrder.append(key); result.relevance[key] = item.provenance
                    if item.identity.entityKind == .page, let page = pageMap[item.identity.entityID] {
                        if requestedScope == .blocks {
                            if let winning = item.passages.first,
                               case .block(let blockID, _) = SemanticPassageLocator(chunkID: winning.chunk.chunkID, entityKind: .page),
                               let block = BlockDocumentCodec.decode(page.body).block(blockID), let tag = block.metadata.semantic {
                                let hit = SemanticBlockHit(pageID: page.id, blockID: blockID, pageTitle: page.title,
                                    semantic: tag, preview: excerpts[key] ?? block.text, status: block.metadata.status)
                                result.blocks.append(hit); result.relevance["block:\(hit.id)"] = item.provenance
                            } else if let hit = lexical.blocks.first(where: { $0.pageID == page.id }) { result.blocks.append(hit) }
                        } else {
                            result.pages.append(page); result.pageExcerpts[page.id] = excerpts[key] ?? item.excerpt
                            if let winning = item.passages.first,
                               case .block(let blockID, _) = SemanticPassageLocator(chunkID: winning.chunk.chunkID, entityKind: .page) {
                                result.pageBlocks[page.id] = blockID
                            }
                        }
                    } else if let source = sourceMap[item.identity.entityID] {
                        result.sources.append(source); result.sourceExcerpts[source.id] = excerpts[key] ?? item.excerpt
                    }
                }
                // Revalidate hydrated originals after all suspensions, then mint a common final epoch.
                for value in evidence.values {
                    let fresh = try await Self.hydrateMeaningEvidence(value, repository: repository)
                    try current(); try await repository.validateEmbeddingSnapshot(fresh); try current()
                }
                permits = []
                for item in fused {
                    let revision = BlockStoreRevision(token: Data(base64Encoded: item.identity.revision) ?? Data())
                    let permit = item.identity.entityKind == .page
                        ? try await repository.sqliteBlockStore.embeddingPublicationPermit(pageID: item.identity.entityID, expected: revision)
                        : try await repository.sqliteBlockStore.embeddingPublicationPermit(sourceID: item.identity.entityID, expected: revision)
                    permits.append(permit); try current()
                }
                try await beforeMeaningPublication?()
                try current(); try completed.validatePublication()
                try EmbeddingPublicationPermit.withPublication(permits: permits, authority: adapter.publicationAuthority) {
                    sidebarSearchResults = result; meaningEvidence = evidence
                    searchStatus = .results; semanticSearchStatus = .completed
                }
            } catch {
                guard meaningSubmissionID == id, searchRevision == revision,
                      isCompletionValid(ticket, currentText: searchText, operation: "meaningSearch.error") else { return }
                if semanticSearchStatus == .declined { return }
                semanticSearchStatus = error is CancellationError || Task.isCancelled
                    ? .needsSubmission : .failed("Meaning search unavailable. Keyword results retained. \(Self.meaningFailure(error))")
            }
        }
    }

    nonisolated static func hydrateMeaningEvidence(_ evidence: MeaningSearchEvidence,
        repository: FileVaultRepository) async throws -> EmbeddingPreparedInputSnapshot {
        let snapshot: EmbeddingPreparedInputSnapshot
        if evidence.identity.entityKind == .page {
            snapshot = try await repository.embeddingPageSnapshot(id: evidence.identity.entityID,
                expectedRevision: evidence.identity.revision, model: evidence.generation.model)
        } else {
            snapshot = try await repository.embeddingSourceSnapshot(id: evidence.identity.entityID,
                expectedRevision: evidence.completion.workRevision, model: evidence.generation.model,
                extractOriginal: Self.embeddingOriginalText)
            guard evidence.completion.originalFingerprint != nil,
                  snapshot.originalFingerprint == evidence.completion.originalFingerprint else {
                throw EmbeddingInputPreparationError.staleRevision
            }
        }
        guard snapshot.identity == evidence.identity,
              snapshot.inputFingerprint == evidence.completion.inputFingerprint,
              snapshot.inputs.count == evidence.completion.chunkCount,
              snapshot.inputs.contains(where: { $0.chunk == evidence.passage.chunk }) else {
            throw EmbeddingInputPreparationError.staleRevision
        }
        return snapshot
    }

    nonisolated static func meaningKey(_ kind: AIEntityKind, _ id: UUID) -> String {
        (kind == .page ? "page:" : "source:") + id.uuidString
    }
    nonisolated static func meaningFailure(_ error: any Error) -> String {
        if error is EmbeddingContractError || error is EmbeddingInputPreparationError { return "Input or indexed evidence is incompatible with the selected model." }
        if error is ExternalAIError { return "Provider authority or processing failed; retry explicitly." }
        return "The semantic service could not complete this query."
    }

    @discardableResult
    func openSearchResult(entryID: UUID, blockID: UUID?, isSource: Bool) -> Task<Void, Never>? {
        let navigation = UUID()
        meaningNavigationID = navigation
        let ticket = issueCompletionTicket(kind: .search, targetID: entryID, capturedText: searchText)
        let key = Self.meaningKey(isSource ? .source : .page, entryID)
        guard let evidence = meaningEvidence[key] else {
            select(entryID, scope: isSource ? .sources : .wiki, block: blockID, previewSource: isSource)
            return nil
        }
        return Task {
            guard let repository, let lease = sessionManager.accessGate.currentLease else { return }
            @MainActor func currentNavigation() throws {
                guard meaningNavigationID == navigation, self.repository === repository,
                      sessionManager.accessGate.currentLease == lease,
                      semanticProcessingGeneration == evidence.generation,
                      isCompletionValid(ticket, currentText: searchText, operation: "meaningNavigation") else { throw CancellationError() }
            }
            do {
                try await beforeMeaningNavigation?(entryID)
                try currentNavigation()
                let snapshot = try await Self.hydrateMeaningEvidence(evidence, repository: repository)
                try currentNavigation()
                try await repository.validateEmbeddingSnapshot(snapshot)
                try currentNavigation()
                let authority = try EmbeddingPublicationAuthority(accessGate: sessionManager.accessGate, lease: lease, generation: evidence.generation)
                let permit = isSource
                    ? try await repository.sqliteBlockStore.embeddingPublicationPermit(sourceID: entryID, expected: evidence.canonicalRevision)
                    : try await repository.sqliteBlockStore.embeddingPublicationPermit(pageID: entryID, expected: evidence.canonicalRevision)
                try currentNavigation()
                // Validate before handing navigation to its existing completion-ticket path.
                try permit.withPublication(authority: authority) {}
                select(entryID, scope: isSource ? .sources : .wiki, previewSource: isSource)
                if !isSource, let blockID,
                   currentNote?.contentHash == evidence.identity.revision,
                   let live = try? EmbeddingInputPreparation.page(editorDocument, identity: evidence.identity, model: evidence.generation.model),
                   live.contains(where: { $0.chunk == evidence.passage.chunk }) {
                    try permit.withPublication(authority: authority) {
                        selectedSemanticID = "\(entryID):\(blockID)"; editorAction = EditorAction(operation: .block(blockID))
                    }
                }
            } catch {
                // A stale passage never drives precise navigation. The current document is still openable.
                guard (try? currentNavigation()) != nil else { return }
                select(entryID, scope: isSource ? .sources : .wiki, previewSource: isSource)
            }
        }
    }
}
