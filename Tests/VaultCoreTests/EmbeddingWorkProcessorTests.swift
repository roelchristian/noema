import Foundation
import SQLite3
import Synchronization
import Testing
@testable import VaultCore

private final class EmbeddingInferenceCount: Sendable {
    let value = Mutex<Int>(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private final class LifecycleSentenceBackend: AppleSentenceEmbeddingBackend {
    let languageCode = "en", revision = 7, dimension = 3
    let calls: EmbeddingInferenceCount
    init(calls: EmbeddingInferenceCount) { self.calls = calls }
    func dominantLanguage(for text: String) -> String? { "en" }
    func wordCount(for text: String) -> Int { 8 }
    func vector(for text: String) -> [Double]? { calls.increment(); return [1, 0, -1] }
}

private actor EmbeddingInferencePause {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private struct EmbeddingLifecycleFixture: Sendable {
    let repository: FileVaultRepository
    let manager: VaultSessionManager
    let lease: VaultSessionLease
    let index: SQLiteEmbeddingIndex
    let generation: EmbeddingIndexGeneration
    let authority: EmbeddingPublicationAuthority
    let provider: AppleSentenceEmbeddingProvider
    let calls: EmbeddingInferenceCount

    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-04-06-continuation/fixtures/\(UUID())")
        let canonical = root.appendingPathComponent("canonical")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: canonical, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, lease, repository) = try await manager.openRepository(root: canonical)
        let calls = EmbeddingInferenceCount()
        let provider = try AppleSentenceEmbeddingProvider(backend: LifecycleSentenceBackend(calls: calls))
        let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: provider.descriptor, chunkingVersion: EmbeddingChunker.version)
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"), lease: lease, accessGate: manager.accessGate)
        let authority = try EmbeddingPublicationAuthority(accessGate: manager.accessGate, lease: lease, generation: generation)
        return Self(repository: repository, manager: manager, lease: lease, index: index, generation: generation, authority: authority, provider: provider, calls: calls)
    }
    func processor(pause: EmbeddingInferencePause? = nil, extract: (@Sendable (SourceSummarySnapshot) throws -> String)? = nil, completedValidation: @escaping @Sendable () throws -> Void = {}) throws -> EmbeddingWorkProcessor {
        let gate = manager.accessGate, lease = lease, provider = provider
        return try EmbeddingWorkProcessor(repository: repository, index: index, generation: generation,
            lease: lease, publicationAuthority: authority, dispatch: { inputs, scope, execution in
                if let pause { await pause.suspend() }
                let context = try EmbeddingExecutionContext(lease: lease, scope: scope, model: provider.descriptor) {
                    try execution.validate()
                }
                let vectors = try await provider.embed(inputs.map(\.text), scope: scope, context: context)
                return EmbeddingDispatchResult(vectors: vectors, validatePublication: { try execution.validate(); try completedValidation() })
            }, extractOriginal: { snapshot in
                if let extract { return try extract(snapshot) }
                guard let value = String(data: snapshot.original, encoding: .utf8) else { throw EmbeddingInputPreparationError.unavailableOriginal }
                return value
            }, validateAuthority: {
                try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.lifecycle.test")
            })
    }
    func item(_ processor: EmbeddingWorkProcessor, kind: AIEntityKind = .page, id: UUID, revision: String) -> AIWorkItem {
        .init(key: .init(vaultID: lease.vaultID, entityKind: kind, entityID: id, processorID: processor.descriptor.identifier),
            revision: revision, processorVersion: processor.descriptor.version, eligibleAt: Date())
    }
    var context: AIProcessingExecutionContext {
        let gate = manager.accessGate, lease = lease
        return .init(lease: lease, validate: {
            try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.lifecycle.test.publish")
        })
    }
}

private actor EmbeddingProcessorLedger: AIWorkLedger {
    var rows: [AIWorkKey: AIWorkItem] = [:]
    var baseline: [AIContentChange]?
    func load(vaultID: UUID) -> [AIWorkItem] { rows.values.filter { $0.key.vaultID == vaultID } }
    func save(_ item: AIWorkItem) { rows[item.key] = item }
    func checkpoint(vaultID: UUID) -> [AIContentChange]? { baseline }
    func saveCheckpoint(vaultID: UUID, changes: [AIContentChange]) { baseline = changes }
}

private struct EmbeddingProcessorPolicy: AIProcessingPolicyResolver {
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority { .allowed }
    func validateExecution(lease: VaultSessionLease) throws {}
}

@Suite(.timeLimit(.minutes(1))) struct EmbeddingWorkProcessorTests {
    @Test(arguments: [AIWorkFailure.authority, .consent])
    func preparePermissionFailurePersistsBlockedCoordinatorWork(_ failure: AIWorkFailure) async throws {
        let f = try await EmbeddingLifecycleFixture.make()
        let processor = try EmbeddingWorkProcessor(repository: f.repository, index: f.index,
            generation: f.generation, lease: f.lease, publicationAuthority: f.authority,
            dispatch: { _, _, _ in f.calls.increment(); throw AIWorkFailure.validation },
            extractOriginal: { _ in "" }, validateAuthority: { throw failure })
        let ledger = EmbeddingProcessorLedger()
        var configuration = AIProcessingConfiguration()
        configuration.newPageDelay = 0
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: f.manager.accessGate,
            policy: EmbeddingProcessorPolicy(),
            clock: .init(now: { Date(timeIntervalSince1970: 1000) }, sleep: { _ in await Task.yield() }),
            configuration: configuration)
        await coordinator.register(processor)
        try await coordinator.bind(lease: f.lease, inventory: [])
        let page = try await f.repository.create(title: "Permission", body: "The original paragraph explains the history of a beautiful city.")
        try await coordinator.receive(.init(vaultID: f.lease.vaultID, entityKind: .page,
            entityID: page.id, revision: page.contentHash, kind: .created))
        while !(await coordinator.workItems().contains { [.blocked, .failed, .completed, .cancelled].contains($0.state) }) {
            try Task.checkCancellation(); await Task.yield()
        }
        let work = try #require(await ledger.load(vaultID: f.lease.vaultID).first)
        #expect(work.state == .blocked)
        #expect(work.failure == failure)
        #expect(await coordinator.status().failedCount == 0)
        #expect(f.calls.count == 0)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
        try await coordinator.suspend()
    }

    @Test(arguments: [AIWorkFailure.authority, .consent])
    func dispatchPermissionFailureBlocksWithoutCompletingDocument(_ failure: AIWorkFailure) async throws {
        let f = try await EmbeddingLifecycleFixture.make()
        let processor = try EmbeddingWorkProcessor(repository: f.repository, index: f.index,
            generation: f.generation, lease: f.lease, publicationAuthority: f.authority,
            dispatch: { _, _, _ in throw failure }, extractOriginal: { _ in "" }, validateAuthority: {})
        let page = try await f.repository.create(title: "Permission", body: "The original paragraph explains the history of a beautiful city.")
        let snapshot = try await processor.prepare(f.item(processor, id: page.id, revision: page.contentHash), lease: f.lease)
        guard case .blocked(let reason) = try await processor.execute(snapshot, context: f.context) else {
            Issue.record("A recoverable permission failure must block the embedding job"); return
        }
        #expect(reason == failure)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
        #expect(f.calls.count == 0)
    }

    @Test(arguments: [AIEntityKind.page, .source])
    func unrelatedDamagedVectorsDoNotBlockHealthyDocument(_ damagedKind: AIEntityKind) async throws {
        let f = try await EmbeddingLifecycleFixture.make(), processor = try f.processor()
        let page = try await f.repository.create(title: "Healthy", body: "The original paragraph explains the history of a beautiful city.")
        // A Source deliberately shares the healthy Page UUID: reuse must scope by both kind
        // and entity ID, while a different Page exercises the entity-ID predicate.
        let damagedIdentity = try EmbeddingEntityIdentity(vaultID: f.lease.vaultID,
            entityKind: damagedKind, entityID: damagedKind == .source ? page.id : UUID(), revision: "old-revision")
        let damagedChunk = try EmbeddingChunk(identity: damagedIdentity, chunkID: "damaged", ordinal: 0,
            contentFingerprint: "damaged", chunkingVersion: EmbeddingChunker.version)
        let damaged = try EmbeddingRecord(generation: f.generation, chunk: damagedChunk,
            vector: EmbeddingVector(values: [1, 0, -1], model: f.generation.model))
        try await f.index.replaceDocument(identity: damagedIdentity, generation: f.generation,
            records: [damaged], validatePublication: {})
        let url = f.lease.root.deletingLastPathComponent()
            .appendingPathComponent("support/KnowledgeVault/\(f.lease.vaultID.uuidString)/semantic.sqlite")
        var connection: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        let db = try #require(connection)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE embedding_chunks SET vector=X''", nil, nil, nil) == SQLITE_OK)

        let snapshot = try await processor.prepare(f.item(processor, id: page.id, revision: page.contentHash), lease: f.lease)
        guard case .completed = try await processor.execute(snapshot, context: f.context) else {
            Issue.record("Unrelated vector damage prevented healthy-document completion"); return
        }
        #expect(f.calls.count == 1)
        let healthy = try await f.index.records(generation: f.generation, entityKind: .page, entityID: page.id)
        #expect(healthy.count == 1)
        #expect(healthy.first?.chunk.identity.revision == page.contentHash)
        await #expect(throws: (any Error).self) {
            try await f.index.records(generation: f.generation,
                entityKind: damagedKind, entityID: damagedIdentity.entityID)
        }
        await #expect(throws: (any Error).self) { try await f.index.records(generation: f.generation) }
        f.manager.accessGate.updateState(.closed)
        await #expect(throws: (any Error).self) {
            try await f.index.records(generation: f.generation, entityKind: .page, entityID: page.id)
        }
    }

    @Test func nativePageAndSourceCommitThroughProtectedIndex() async throws {
        let f = try await EmbeddingLifecycleFixture.make(), processor = try f.processor()
        let page = try await f.repository.create(title: "Human page", body: "The original paragraph explains the history of this beautiful city.")
        let source = try await f.repository.importSource(data: Data("The complete source document explains the history of a distant city.".utf8), filename: "source.txt", title: "Original", originURL: nil)
        let inventory = try await f.repository.aiProcessingInventory()
        for (kind, id) in [(AIEntityKind.page, page.id), (.source, source.id)] {
            let revision = try #require(inventory.first { $0.entityID == id }?.revision)
            let item = f.item(processor, kind: kind, id: id, revision: revision)
            let snapshot = try await processor.prepare(item, lease: f.lease)
            _ = try await processor.execute(snapshot, context: f.context)
            #expect(try await processor.isCurrent(item, snapshot: snapshot, lease: f.lease))
        }
        let records = try await f.index.records(generation: f.generation)
        #expect(Set(records.map { $0.chunk.identity.entityKind }) == [.page, .source])
        #expect(f.calls.count == 2)
    }

    @Test func unchangedChunksAvoidInferenceAndAdvanceRevision() async throws {
        let f = try await EmbeddingLifecycleFixture.make(), processor = try f.processor()
        let first = EditorBlock(runs: [.init("The first original paragraph explains the history of a beautiful city.")])
        var second = EditorBlock(runs: [.init("The second original paragraph explains the history of a distant country.")])
        let page = try await f.repository.create(title: "Page", body: BlockDocumentCodec.encode(.init(blocks: [first, second])))
        let initial = try await processor.prepare(f.item(processor, id: page.id, revision: page.contentHash), lease: f.lease)
        _ = try await processor.execute(initial, context: f.context)
        #expect(f.calls.count == 2)
        second.runs = [.init("The changed paragraph explains the geography of a distant country.")]
        let changed = try await f.repository.save(note: page, title: page.title, body: BlockDocumentCodec.encode(.init(blocks: [first, second])), tags: [])
        let snapshot = try await processor.prepare(f.item(processor, id: changed.id, revision: changed.contentHash), lease: f.lease)
        #expect(initial.inputFingerprint != snapshot.inputFingerprint)
        _ = try await processor.execute(snapshot, context: f.context)
        #expect(f.calls.count == 3)
        let records = try await f.index.records(generation: f.generation)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.chunk.identity.revision == changed.contentHash })
    }

    @Test func emptyDocumentPersistsCompletionWithoutInference() async throws {
        let f = try await EmbeddingLifecycleFixture.make(), processor = try f.processor()
        let page = try await f.repository.create(title: "Empty", body: "")
        let snapshot = try await processor.prepare(f.item(processor, id: page.id, revision: page.contentHash), lease: f.lease)
        _ = try await processor.execute(snapshot, context: f.context)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
        #expect(try await f.index.completedDocuments(generation: f.generation).contains { $0.identity.entityID == page.id && $0.workRevision == page.contentHash && $0.chunkCount == 0 })
        #expect(f.calls.count == 0)
    }

    @Test(arguments: ["edit", "trash", "authority", "lock", "switch"])
    func suspendedInferenceRejectsStalePublication(_ mutation: String) async throws {
        let f = try await EmbeddingLifecycleFixture.make(), pause = EmbeddingInferencePause()
        let processor = try f.processor(pause: pause)
        let page = try await f.repository.create(title: "Page", body: "The committed original paragraph explains the history of a beautiful city.")
        let snapshot = try await processor.prepare(f.item(processor, id: page.id, revision: page.contentHash), lease: f.lease)
        let execution = Task { try await processor.execute(snapshot, context: f.context) }
        await pause.waitUntilEntered()
        let originalState = f.manager.accessGate.currentState
        switch mutation {
        case "edit": _ = try await f.repository.save(note: page, title: page.title, body: "This changed document describes another subject entirely.", tags: [])
        case "trash": try await f.repository.trash(note: page)
        case "lock": f.manager.accessGate.updateState(.closed)
        case "switch": f.manager.accessGate.updateState(.open(VaultSession(vaultID: UUID(), root: f.lease.root.appendingPathComponent("other"), generation: 2)))
        default: f.authority.invalidate()
        }
        await pause.release()
        await #expect(throws: (any Error).self) { try await execution.value }
        f.manager.accessGate.updateState(originalState)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
    }

    @Test func completedRequestValidatorRemainsLiveThroughPublication() async throws {
        let f = try await EmbeddingLifecycleFixture.make()
        let validations = EmbeddingInferenceCount()
        let processor = try f.processor(completedValidation: {
            validations.increment()
            if validations.count >= 2 { throw EmbeddingContractError.authorityDenied }
        })
        let page = try await f.repository.create(title: "Page", body: "The original committed paragraph explains the history of a beautiful city.")
        let snapshot = try await processor.prepare(f.item(processor, id: page.id, revision: page.contentHash), lease: f.lease)
        await #expect(throws: (any Error).self) { try await processor.execute(snapshot, context: f.context) }
        #expect(f.calls.count == 1)
        #expect(validations.count >= 2)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
    }

    @Test func sourceOriginalReplacementDuringInferenceRejectsPublication() async throws {
        let f = try await EmbeddingLifecycleFixture.make(), pause = EmbeddingInferencePause()
        let processor = try f.processor(pause: pause)
        let source = try await f.repository.importSource(data: Data("The original source document explains the history of a beautiful city.".utf8), filename: "source.txt", title: "Original", originURL: nil)
        let revision = try #require(try await f.repository.aiProcessingInventory().first { $0.entityID == source.id }?.revision)
        let snapshot = try await processor.prepare(f.item(processor, kind: .source, id: source.id, revision: revision), lease: f.lease)
        let execution = Task { try await processor.execute(snapshot, context: f.context) }
        await pause.waitUntilEntered()
        let original = f.lease.root.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)")
        try Data("Independently replaced original bytes.".utf8).write(to: original)
        await pause.release()
        await #expect(throws: (any Error).self) { try await execution.value }
        #expect(try await f.index.records(generation: f.generation).isEmpty)
    }
    @Test func coordinatorRunsNativeProcessorWithoutEnrichmentAndPreservesInitialBaseline() async throws {
        let f = try await EmbeddingLifecycleFixture.make(), processor = try f.processor()
        let historical = try await f.repository.create(title: "Historical", body: "The older original paragraph explains the history of a beautiful city.")
        let ledger = EmbeddingProcessorLedger()
        var configuration = AIProcessingConfiguration()
        configuration.newPageDelay = 0; configuration.updatedPageDelay = 0
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: f.manager.accessGate,
            policy: EmbeddingProcessorPolicy(),
            clock: .init(now: { Date(timeIntervalSince1970: 1000) }, sleep: { _ in await Task.yield() }),
            configuration: configuration)
        await coordinator.register(processor)
        try await coordinator.bind(lease: f.lease, inventory: try await f.repository.aiProcessingInventory())
        #expect(await coordinator.workItems().isEmpty)
        #expect(f.calls.count == 0)
        let fresh = try await f.repository.create(title: "Fresh", body: "The newly committed paragraph explains the history of a distant city.")
        try await coordinator.receive(.init(vaultID: f.lease.vaultID, entityKind: .page,
            entityID: fresh.id, revision: fresh.contentHash, kind: .created))
        while !(await coordinator.workItems().contains { [.completed, .failed, .blocked, .cancelled].contains($0.state) }) {
            try Task.checkCancellation(); await Task.yield()
        }
        let work = await coordinator.workItems()
        #expect(work.count == 1)
        #expect(work.first?.state == .completed)
        let documents = try await f.index.completedDocuments(generation: f.generation)
        #expect(documents.map { $0.identity.entityID } == [fresh.id])
        #expect(!documents.contains { $0.identity.entityID == historical.id })
        #expect(f.calls.count == 1)
        try await coordinator.suspend()
    }

    @Test func unavailableOriginalExtractionIsExplicitAndStartsNoInference() async throws {
        let f = try await EmbeddingLifecycleFixture.make()
        let processor = try f.processor(extract: { _ in throw EmbeddingInputPreparationError.unavailableOriginal })
        let source = try await f.repository.importSource(data: Data("The original source document explains the history of a beautiful city.".utf8), filename: "source.txt", title: "Original", originURL: nil)
        let revision = try #require(try await f.repository.aiProcessingInventory().first { $0.entityID == source.id }?.revision)
        await #expect(throws: AIWorkFailure.unavailable) {
            try await processor.prepare(f.item(processor, kind: .source, id: source.id, revision: revision), lease: f.lease)
        }
        #expect(f.calls.count == 0)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    }

    @Test func rejectedReplacementPreservesAcknowledgedVectorsAndCompletion() async throws {
        let f = try await EmbeddingLifecycleFixture.make(), processor = try f.processor()
        let original = try await f.repository.create(title: "Page", body: "The original paragraph explains the history of a beautiful city.")
        let initial = try await processor.prepare(f.item(processor, id: original.id, revision: original.contentHash), lease: f.lease)
        _ = try await processor.execute(initial, context: f.context)
        let records = try await f.index.records(generation: f.generation)
        let completions = try await f.index.completedDocuments(generation: f.generation)
        let changed = try await f.repository.save(note: original, title: original.title,
            body: "The changed paragraph explains the geography of a distant country.", tags: [])
        let validations = EmbeddingInferenceCount()
        let rejecting = try f.processor(completedValidation: {
            validations.increment()
            if validations.count >= 2 { throw EmbeddingContractError.authorityDenied }
        })
        let snapshot = try await rejecting.prepare(f.item(rejecting, id: changed.id, revision: changed.contentHash), lease: f.lease)
        await #expect(throws: (any Error).self) { try await rejecting.execute(snapshot, context: f.context) }
        #expect(try await f.index.records(generation: f.generation) == records)
        let after = try await f.index.completedDocuments(generation: f.generation)
        #expect(after.count == completions.count)
        #expect(after.first?.workRevision == original.contentHash)
        #expect(after.first?.inputFingerprint == completions.first?.inputFingerprint)
    }

    @Test func missingOwnedOriginalIsUnavailableWithoutInferenceOrFalseCompletion() async throws {
        let f = try await EmbeddingLifecycleFixture.make(), processor = try f.processor()
        let source = try await f.repository.importSource(data: Data("The original source document explains the history of a beautiful city.".utf8), filename: "source.txt", title: "Original", originURL: nil)
        let revision = try #require(try await f.repository.aiProcessingInventory().first { $0.entityID == source.id }?.revision)
        let original = f.lease.root.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)")
        // Preserve the synthetic original as failure evidence while simulating external disappearance.
        try FileManager.default.moveItem(at: original, to: original.appendingPathExtension("preserved"))
        await #expect(throws: AIWorkFailure.unavailable) {
            try await processor.prepare(f.item(processor, kind: .source, id: source.id, revision: revision), lease: f.lease)
        }
        #expect(f.calls.count == 0)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    }

}

@Test(arguments: [AIWorkState.completed, .cancelled, .blocked, .running])
func embeddingVersionSelectionCannotReviveRecordedWork(_ state: AIWorkState) async throws {
    let fixture = try await EmbeddingLifecycleFixture.make()
    let processor = try fixture.processor()
    let note = try await fixture.repository.create(title: "Recorded", body: "Previously recorded content stays quiet after selecting a new model.")
    let ledger = EmbeddingProcessorLedger()
    let inventory = try await fixture.repository.aiProcessingInventory()
    let key = AIWorkKey(vaultID: fixture.lease.vaultID, entityKind: .page, entityID: note.id,
                        processorID: EmbeddingWorkProcessor.identifier)
    let old = AIWorkItem(key: key, revision: note.contentHash, processorVersion: "previous-generation",
                         state: state, attemptCount: 2, eligibleAt: Date(), inputFingerprint: "recorded")
    await ledger.save(old)
    await ledger.saveCheckpoint(vaultID: fixture.lease.vaultID, changes: inventory)
    let coordinator = AIProcessingCoordinator(ledger: ledger, gate: fixture.manager.accessGate,
        policy: EmbeddingProcessorPolicy(), clock: .init(now: { Date() }, sleep: { _ in await Task.yield() }))
    await coordinator.register(processor)
    try await coordinator.bind(lease: fixture.lease, inventory: inventory)
    #expect(await coordinator.workItems().isEmpty)
    #expect(await ledger.load(vaultID: fixture.lease.vaultID) == [old])
    #expect(fixture.calls.count == 0)
    #expect(try await fixture.index.completedDocuments(generation: fixture.generation).isEmpty)
    try await coordinator.suspend()
}
