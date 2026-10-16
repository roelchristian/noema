import Foundation

/// Completed provider output retains every request-specific publication validator until COMMIT.
public struct EmbeddingDispatchResult: Sendable {
    public let vectors: [EmbeddingVector]
    public let validatePublication: @Sendable () throws -> Void
    public init(vectors: [EmbeddingVector], validatePublication: @escaping @Sendable () throws -> Void) {
        self.vectors = vectors; self.validatePublication = validatePublication
    }
}

/// Incremental derived indexing only. The coordinator owns admission/retries; the injected
/// dispatch owns provider-specific execution authority and must mint it for each exact batch.
public struct EmbeddingWorkProcessor: AIWorkProcessor {
    public static let identifier = "semantic-embedding"
    public typealias Dispatch = @Sendable ([EmbeddingChunkInput], EmbeddingProcessingScope, AIProcessingExecutionContext) async throws -> EmbeddingDispatchResult
    public typealias ExtractOriginal = @Sendable (SourceSummarySnapshot) throws -> String

    public let descriptor: AIProcessorDescriptor
    private let batchID: UUID?
    private let repository: FileVaultRepository
    private let index: SQLiteEmbeddingIndex
    private let generation: EmbeddingIndexGeneration
    private let lease: VaultSessionLease
    private let publicationAuthority: EmbeddingPublicationAuthority
    private let dispatch: Dispatch
    private let extractOriginal: ExtractOriginal
    private let validateAuthority: @Sendable () throws -> Void

    public init(repository: FileVaultRepository, index: SQLiteEmbeddingIndex,
                generation: EmbeddingIndexGeneration, lease: VaultSessionLease,
                publicationAuthority: EmbeddingPublicationAuthority,
                dispatch: @escaping Dispatch, extractOriginal: @escaping ExtractOriginal,
                validateAuthority: @escaping @Sendable () throws -> Void, batchID: UUID? = nil) throws {
        guard repository.manifest.id == lease.vaultID, repository.sessionLease == lease,
              generation.vaultID == lease.vaultID, generation.chunkingVersion == EmbeddingChunker.version,
              publicationAuthority.lease == lease, publicationAuthority.generation == generation else {
            throw EmbeddingContractError.authorityDenied
        }
        self.batchID = batchID
        self.repository = repository; self.index = index; self.generation = generation; self.lease = lease
        self.publicationAuthority = publicationAuthority; self.dispatch = dispatch
        self.extractOriginal = extractOriginal; self.validateAuthority = validateAuthority
        descriptor = AIProcessorDescriptor(identifier: batchID.map { Self.identifier + ".history." + $0.uuidString } ?? Self.identifier, version: generation.id.uuidString,
            targets: [.page, .source], dependencies: [.body, .title, .metadata, .sourceContent, .lifecycle],
            provider: generation.model.providerID == "openai" ? .cloud : .onDevice,
            recoverOnVersionChange: false, observesCommittedChanges: batchID == nil)
    }

    public func prepare(_ item: AIWorkItem, lease: VaultSessionLease) async throws -> any AIWorkSnapshot {
        try validate(lease)
        guard item.key.vaultID == lease.vaultID, item.key.processorID == descriptor.identifier,
              item.processorVersion == descriptor.version, item.batchID == batchID else { throw AIWorkFailure.authority }
        let prepared: EmbeddingPreparedInputSnapshot
        do {
            switch item.key.entityKind {
            case .page:
                prepared = try await repository.embeddingPageSnapshot(id: item.key.entityID,
                    expectedRevision: item.revision, model: generation.model)
            case .source:
                prepared = try await repository.embeddingSourceSnapshot(id: item.key.entityID,
                    expectedRevision: item.revision, model: generation.model, extractOriginal: extractOriginal)
            }
        } catch EmbeddingInputPreparationError.unsupportedLanguage { throw AIWorkFailure.unsupported }
          catch EmbeddingInputPreparationError.unsupportedDocument { throw AIWorkFailure.unsupported }
          catch EmbeddingInputPreparationError.unsupportedSourceType { throw AIWorkFailure.unsupported }
          catch EmbeddingInputPreparationError.unavailableOriginal { throw AIWorkFailure.unavailable }
          catch VaultContentStoreError.missing { throw AIWorkFailure.unavailable }
          catch VaultContentStoreError.unavailable { throw AIWorkFailure.unavailable }
          catch VaultError.unavailable { throw AIWorkFailure.unavailable }
        try validate(lease)
        return Prepared(input: prepared)
    }

    public func execute(_ snapshot: any AIWorkSnapshot, context: AIProcessingExecutionContext) async throws -> AIWorkOutcome {
        try validate(context.lease); try context.validate()
        guard let prepared = snapshot as? Prepared, prepared.input.model == generation.model,
              prepared.input.identity.vaultID == lease.vaultID else { throw AIWorkFailure.validation }
        let input = prepared.input
        let previous = try await index.records(generation: generation)
        var records = try EmbeddingInputPreparation.reusableRecords(previous, for: input, generation: generation)
        let reused = Set(records.map(\.chunk.chunkID))
        let changed = input.inputs.filter { !reused.contains($0.chunk.chunkID) }
        var publicationValidators: [@Sendable () throws -> Void] = []
        // Batch identity only selects a scope; dispatch must obtain fresh exact-request authority.
        let scope = batchID.map { EmbeddingProcessingScope.historicalBackfill(jobID: $0, entity: input.identity) }
            ?? EmbeddingProcessingScope.document(input.identity)
        for batch in EmbeddingInputPreparation.requestBatches(changed, model: generation.model) {
            try validate(context.lease); try context.validate()
            let result: EmbeddingDispatchResult
            do { result = try await dispatch(batch, scope, context) }
            catch AppleSentenceEmbeddingError.unsupportedInputLanguage { throw AIWorkFailure.unsupported }
            catch AppleSentenceEmbeddingError.unavailable { throw AIWorkFailure.unavailable }
            let vectors = result.vectors
            try result.validatePublication()
            publicationValidators.append(result.validatePublication)
            try validate(context.lease); try context.validate()
            guard vectors.count == batch.count else { throw EmbeddingContractError.invalidVector }
            records += try zip(batch, vectors).map { try EmbeddingRecord(generation: generation, chunk: $0.0.chunk, vector: $0.1) }
            if records.count < input.inputs.count {
                // A completed request is durable before another request starts. Partial rows never
                // claim document completion; a restart reuses only exact compatible fingerprints.
                try await publish(records, input: input, context: context,
                                  validators: publicationValidators, completed: false)
            }
        }
        try await publish(records, input: input, context: context,
                          validators: publicationValidators, completed: true)
        return changed.isEmpty ? .skipped : .completed
    }

    private func publish(_ records: [EmbeddingRecord], input: EmbeddingPreparedInputSnapshot,
                         context: AIProcessingExecutionContext,
                         validators: [@Sendable () throws -> Void], completed: Bool) async throws {
        try await repository.validateEmbeddingSnapshot(input)
        try validate(context.lease); try context.validate()
        let permit: EmbeddingPublicationPermit
        switch input.identity.entityKind {
        case .page:
            permit = try await repository.sqliteBlockStore.embeddingPublicationPermit(pageID: input.identity.entityID, expected: input.canonicalRevision)
        case .source:
            permit = try await repository.sqliteBlockStore.embeddingPublicationPermit(sourceID: input.identity.entityID, expected: input.canonicalRevision)
        }
        try validate(context.lease); try context.validate()
        let completion = completed ? EmbeddingDocumentCompletion(identity: input.identity, workRevision: input.revision,
            inputFingerprint: input.inputFingerprint, chunkCount: records.count) : nil
        let checkpoint = completed ? nil : EmbeddingDocumentCheckpoint(identity: input.identity, workRevision: input.revision,
            inputFingerprint: input.inputFingerprint, chunkCount: records.count)
        try await index.replaceDocument(identity: input.identity, generation: generation,
            records: records.sorted { $0.chunk.ordinal < $1.chunk.ordinal },
            permit: permit, authority: publicationAuthority, completion: completion, checkpoint: checkpoint, validatePublication: {
                try context.validate(); try validateAuthority()
                for validator in validators { try validator() }
            })
    }

    public func isCurrent(_ item: AIWorkItem, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async throws -> Bool {
        try validate(lease)
        guard let prepared = snapshot as? Prepared, item.revision == prepared.revision,
              item.key.entityID == prepared.input.identity.entityID,
              item.key.entityKind == prepared.input.identity.entityKind else { return false }
        do { try await repository.validateEmbeddingSnapshot(prepared.input) }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
        try validate(lease)
        return true
    }

    private func validate(_ requestedLease: VaultSessionLease) throws {
        try Task.checkCancellation()
        guard requestedLease == lease else { throw AIWorkFailure.authority }
        try validateAuthority()
    }

    private struct Prepared: AIWorkSnapshot {
        let input: EmbeddingPreparedInputSnapshot
        var revision: String { input.revision }
        // Revision changes still require execution to rebind reused vectors and durable completion.
        var inputFingerprint: String { digest(Data((revision + ":" + input.inputFingerprint).utf8)) }
    }
}
