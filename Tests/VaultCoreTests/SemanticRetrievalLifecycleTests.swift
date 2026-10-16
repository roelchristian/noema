import Foundation
import Testing
@testable import VaultCore

private struct SearchLifecycleFixture: Sendable {
    let store: SQLiteBlockStore, index: SQLiteEmbeddingIndex
    let session: VaultSession, gate: VaultAccessGate
    let generation: EmbeddingIndexGeneration, support: URL
    var vector: EmbeddingVector { get throws { try .init(values: [1, 0], model: generation.model) } }
    func identity(_ snapshot: BlockStoreSnapshot) throws -> EmbeddingEntityIdentity {
        try .init(vaultID: session.vaultID, entityKind: .page, entityID: snapshot.pageID,
            revision: snapshot.revision.token.base64EncodedString())
    }
    func publish(_ snapshot: BlockStoreSnapshot, partial: Bool = false) async throws -> EmbeddingEntityIdentity {
        let identity = try identity(snapshot)
        let inputs = try EmbeddingInputPreparation.page(snapshot.document, identity: identity, model: generation.model)
        let records = try inputs.map { try EmbeddingRecord(generation: generation, chunk: $0.chunk, vector: vector) }
        let fingerprint = digest(Data(inputs.map { $0.chunk.chunkID + ":" + $0.chunk.contentFingerprint }.joined(separator: "\n").utf8))
        let permit = try await store.embeddingPublicationPermit(pageID: snapshot.pageID, expected: snapshot.revision)
        let authority = try EmbeddingPublicationAuthority(accessGate: gate, lease: session.lease, generation: generation)
        let completion = EmbeddingDocumentCompletion(identity: identity, workRevision: identity.revision,
            inputFingerprint: fingerprint, chunkCount: records.count)
        try await index.replaceDocument(identity: identity, generation: generation, records: records,
            permit: permit, authority: authority, completion: partial ? nil : completion,
            checkpoint: partial ? .init(identity: identity, workRevision: identity.revision,
                inputFingerprint: fingerprint, chunkCount: records.count) : nil, validatePublication: {})
        return identity
    }
    func search(current: EmbeddingEntityIdentity?) async throws -> [SemanticSearchCandidate] {
        try await index.searchCandidates(query: vector, generation: generation,
            isCurrent: { $0.identity == current }, validateQuery: {})
    }
}

private func withSearchLifecycle(_ body: (SearchLifecycleFixture) async throws -> Void) async throws {
    let run = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/retrieval-lifecycle-\(UUID())")
    let canonical = run.appendingPathComponent("canonical")
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    try Data().write(to: run.appendingPathComponent(".active"))
    defer {
        try? Data().write(to: run.appendingPathComponent(".complete"))
        try? FileManager.default.removeItem(at: run.appendingPathComponent(".active"))
    }
    do {
        let session = VaultSession(vaultID: UUID(), root: canonical, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let store = try SQLiteBlockStore(canonicalStagingURL: canonical.appendingPathComponent("blocks.sqlite"),
            vaultID: session.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
            schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
        let model = try EmbeddingModelDescriptor(providerID: "lifecycle-synthetic", modelID: "stable", revision: "1",
            dimensions: 2, maximumInputUTF8Bytes: 1024, maximumBatchSize: 16)
        let generation = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
        let support = run.appendingPathComponent("support")
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: session.lease, accessGate: gate)
        try await body(.init(store: store, index: index, session: session, gate: gate, generation: generation, support: support))
        try await store.close()
    } catch {
        try? Data().write(to: run.appendingPathComponent(".failed"))
        throw error
    }
}

@Test func semanticRetrievalLifecycleEditTrashRestoreAndLatePublication() async throws {
    try await withSearchLifecycle { f in
        let original = try await f.store.save(BlockDocumentCodec.decode("A committed medical paragraph."), pageID: UUID(), condition: .createOnly)
        let originalID = try await f.publish(original)
        let hydrated = try await f.search(current: originalID)
        #expect(hydrated.count == 1)
        let permit = try await f.store.embeddingPublicationPermit(pageID: original.pageID, expected: original.revision)
        let authority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: f.generation)
        // Independent canonical change after hydration but before synchronous UI assignment.
        let edited = try await f.store.save(BlockDocumentCodec.decode("The current paragraph now concerns gardening."),
            pageID: original.pageID, condition: .replace(expected: original.revision))
        #expect(throws: EmbeddingContractError.authorityDenied) {
            try permit.withPublication(authority: authority) { Issue.record("Stale hydrated evidence published") }
        }
        #expect(try await f.search(current: f.identity(edited)).isEmpty)
        let editedID = try await f.publish(edited)
        #expect(try await f.search(current: editedID).count == 1)
        let trashed = try await f.store.setTrashed(pageID: edited.pageID, expected: edited.revision, trashed: true)
        #expect(try await f.search(current: nil).isEmpty)
        let restored = try await f.store.setTrashed(pageID: edited.pageID, expected: trashed.revision, trashed: false)
        #expect(try await f.search(current: f.identity(restored)).isEmpty)
        let restoredID = try await f.publish(restored)
        #expect(try await f.search(current: restoredID).count == 1)
        let unchanged = try await f.store.load(pageID: restored.pageID)
        #expect(unchanged.revision == restored.revision && unchanged.document == restored.document)
    }
}

@Test func semanticRetrievalLifecyclePartialCompletionReopenAndRevocation() async throws {
    try await withSearchLifecycle { f in
        let page = try await f.store.save(BlockDocumentCodec.decode("A complete human astronomy paragraph."), pageID: UUID(), condition: .createOnly)
        let identity = try await f.publish(page, partial: true)
        #expect(try await f.search(current: identity).isEmpty)
        _ = try await f.publish(page)
        #expect(try await f.search(current: identity).count == 1)
        let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: f.support, lease: f.session.lease, accessGate: f.gate)
        let results = try await reopened.searchCandidates(query: f.vector, generation: f.generation,
            isCurrent: { $0.identity == identity }, validateQuery: {})
        #expect(results.count == 1 && results[0].completion.workRevision == identity.revision)
        f.gate.updateState(.closed)
        await #expect(throws: (any Error).self) { try await f.search(current: identity) }
        // Derived rejection never mutates acknowledged canonical content.
        #expect(try await f.store.load(pageID: page.pageID).document == page.document)
    }
}
