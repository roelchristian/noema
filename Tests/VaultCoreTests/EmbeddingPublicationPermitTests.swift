import Foundation
import Synchronization
import Testing
@testable import VaultCore

private func publicationPermitRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-publication-permit-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func publicationBoundaryReached(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}

private func publicationBackground<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue(label: "noema.publication-boundary.\(UUID())").async {
            do { continuation.resume(returning: try body()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

private final class PublicationBoundaryTrace: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ value: String) { entries.withLock { $0.append(value) } }
    var values: [String] { entries.withLock { $0 } }
}

private func publicationPermitDocument(_ text: String) -> BlockDocument {
    BlockDocument(blocks: [EditorBlock(runs: [RichRun(text)])])
}

@Test func embeddingPublicationPermitRejectsEntityPropertyCommitOnCurrentSchema() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/embedding-property-permit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".active"))
    defer {
        try? Data().write(to: root.appendingPathComponent(".complete"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".active"))
    }
    let vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(
        url: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    let page = try await store.save(publicationPermitDocument("Original page"), pageID: UUID(), condition: .createOnly)
    let entity = try await store.createEntity(.init(typeKey: "person", label: "Ada"),
        expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Occupation", kind: .text, cardinality: .one)
    _ = try await store.savePropertyDefinition(definition, expected: nil,
        expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let permit = try await store.embeddingPublicationPermit(pageID: page.pageID, expected: page.revision)
    _ = try await store.savePropertyValues(entityID: entity.entity.id,
        assignments: [.init(definitionID: definition.id, value: .text("Mathematician"))],
        expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    #expect(throws: EmbeddingContractError.authorityDenied) {
        try permit.withPublication(authority: EmbeddingPublicationAuthority()) {}
    }
    #expect(try await store.load(pageID: page.pageID).revision == page.revision)
    try await store.close()
}

@Test func embeddingPublicationPermitRejectsCrossConnectionEditAndRemoval() async throws {
    let root = try publicationPermitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), pageID = UUID()
    let first = try SQLiteBlockStore(unguardedTestingURL: url)
    let snapshot = try await first.save(publicationPermitDocument("original"), pageID: pageID, condition: .createOnly)
    let second = try SQLiteBlockStore(unguardedTestingURL: url, createIfMissing: false)
    let authority = EmbeddingPublicationAuthority()
    let editPermit = try await first.embeddingPublicationPermit(pageID: pageID, expected: snapshot.revision)
    let changed = try await second.save(publicationPermitDocument("changed"), pageID: pageID, condition: .replace(expected: snapshot.revision))
    let called = Mutex(false)
    #expect(throws: (any Error).self) {
        try editPermit.withPublication(authority: authority) { called.withLock { $0 = true } }
    }
    #expect(!called.withLock { $0 })
    let removalPermit = try await first.embeddingPublicationPermit(pageID: pageID, expected: changed.revision)
    try await second.delete(pageID: pageID, expected: changed.revision)
    #expect(throws: (any Error).self) {
        try removalPermit.withPublication(authority: authority) { called.withLock { $0 = true } }
    }
    #expect(!called.withLock { $0 })
    try await first.close(); try await second.close()
}

@Test func embeddingPublicationPermitRejectsStaleIssuanceTrashAndClose() async throws {
    let root = try publicationPermitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteBlockStore(unguardedTestingURL: root.appendingPathComponent("blocks.sqlite"))
    let pageID = UUID()
    let initial = try await store.save(publicationPermitDocument("initial"), pageID: pageID, condition: .createOnly)
    let latest = try await store.save(publicationPermitDocument("latest"), pageID: pageID, condition: .replace(expected: initial.revision))
    await #expect(throws: (any Error).self) {
        try await store.embeddingPublicationPermit(pageID: pageID, expected: initial.revision)
    }
    let permit = try await store.embeddingPublicationPermit(pageID: pageID, expected: latest.revision)
    let trashed = try await store.setTrashed(pageID: pageID, expected: latest.revision, trashed: true)
    #expect(throws: (any Error).self) { try permit.withPublication(authority: EmbeddingPublicationAuthority()) {} }
    await #expect(throws: (any Error).self) {
        try await store.embeddingPublicationPermit(pageID: pageID, expected: trashed.revision)
    }
    let restored = try await store.setTrashed(pageID: pageID, expected: trashed.revision, trashed: false)
    let closePermit = try await store.embeddingPublicationPermit(pageID: pageID, expected: restored.revision)
    try await store.close()
    #expect(throws: (any Error).self) { try closePermit.withPublication(authority: EmbeddingPublicationAuthority()) {} }
}

@Test func embeddingPublicationPermitRejectsRevokedAuthorityAtBoundary() async throws {
    let root = try publicationPermitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteBlockStore(unguardedTestingURL: root.appendingPathComponent("blocks.sqlite"))
    let pageID = UUID()
    let snapshot = try await store.save(publicationPermitDocument("committed"), pageID: pageID, condition: .createOnly)
    let permit = try await store.embeddingPublicationPermit(pageID: pageID, expected: snapshot.revision)
    let authority = EmbeddingPublicationAuthority()
    authority.invalidate()
    let called = Mutex(false)
    #expect(throws: (any Error).self) {
        try permit.withPublication(authority: authority) { called.withLock { $0 = true } }
    }
    #expect(!called.withLock { $0 })
    try await store.close()
}

@Test func embeddingPublicationPermitConservativelyInvalidatesAfterRollback() async throws {
    let root = try publicationPermitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteBlockStore(unguardedTestingURL: root.appendingPathComponent("blocks.sqlite"))
    let pageID = UUID()
    let snapshot = try await store.save(publicationPermitDocument("committed"), pageID: pageID, condition: .createOnly)
    let permit = try await store.embeddingPublicationPermit(pageID: pageID, expected: snapshot.revision)
    await #expect(throws: (any Error).self) {
        try await store.save(publicationPermitDocument("rejected"), pageID: pageID,
                             condition: .replace(expected: BlockStoreRevision(token: Data("stale".utf8))))
    }
    #expect(try await store.load(pageID: pageID) == snapshot)
    #expect(throws: (any Error).self) { try permit.withPublication(authority: EmbeddingPublicationAuthority()) {} }
    let fresh = try await store.embeddingPublicationPermit(pageID: pageID, expected: snapshot.revision)
    #expect(try fresh.withPublication(authority: EmbeddingPublicationAuthority()) { 42 } == 42)
    try await store.close()
}

@Test func embeddingPublicationAuthoritySessionRevocationIsSynchronous() async throws {
    let root = try publicationPermitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteBlockStore(unguardedTestingURL: root.appendingPathComponent("blocks.sqlite"))
    let pageID = UUID()
    let snapshot = try await store.save(publicationPermitDocument("committed"), pageID: pageID, condition: .createOnly)
    let permit = try await store.embeddingPublicationPermit(pageID: pageID, expected: snapshot.revision)
    let session = VaultSession(vaultID: UUID(), root: root, generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    let model = try EmbeddingModelDescriptor(providerID: "mock", modelID: "permit", revision: "1", dimensions: 2, maximumInputUTF8Bytes: 128, maximumBatchSize: 1)
    let generation = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: model, chunkingVersion: "1")
    let authority = try EmbeddingPublicationAuthority(accessGate: gate, lease: session.lease, generation: generation)
    gate.updateState(.closed)
    #expect(throws: (any Error).self) { try permit.withPublication(authority: authority) {} }
    #expect(throws: (any Error).self) { try EmbeddingPublicationAuthority(accessGate: gate, lease: session.lease, generation: generation) }
    try await store.close()
}

@Test func embeddingPublicationBoundarySerializesCanonicalCommitAndAuthorityRevocation() async throws {
    let root = try publicationPermitRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), pageID = UUID()
    let first = try SQLiteBlockStore(unguardedTestingURL: url)
    let snapshot = try await first.save(publicationPermitDocument("original"), pageID: pageID, condition: .createOnly)
    let second = try SQLiteBlockStore(unguardedTestingURL: url, createIfMissing: false)
    let permit = try await first.embeddingPublicationPermit(pageID: pageID, expected: snapshot.revision)
    let authority = EmbeddingPublicationAuthority()
    let entered = DispatchGroup(); entered.enter()
    let release = DispatchSemaphore(value: 0)
    let revokeAttempt = DispatchSemaphore(value: 0), editAttempt = DispatchSemaphore(value: 0)
    let order = PublicationBoundaryTrace(), attemptsObserved = PublicationBoundaryTrace()
    let (publication, published) = AsyncThrowingStream<Void, Error>.makeStream()
    let (revocation, revoked) = AsyncThrowingStream<Void, Error>.makeStream()
    let (edit, edited) = AsyncThrowingStream<Void, Error>.makeStream()
    // Install every contender and the release controller synchronously before any
    // cooperative suspension. A blocked actor executor cannot prevent lock release.
    DispatchQueue(label: "noema.publication-owner").async {
        do {
            try permit.withPublication(authority: authority) {
                order.append("publication-enter"); entered.leave()
                guard release.wait(timeout: .now() + 5) == .success else { throw VaultError.invalid("Boundary test release timed out.") }
                order.append("publication-exit")
            }
            published.finish()
        } catch { published.finish(throwing: error) }
    }
    DispatchQueue(label: "noema.publication-revoker").async {
        guard entered.wait(timeout: .now() + 5) == .success else {
            revoked.finish(throwing: VaultError.invalid("Publication never entered.")); return
        }
        revokeAttempt.signal()
        authority.invalidate(); order.append("revocation-complete"); revoked.finish()
    }
    DispatchQueue(label: "noema.publication-editor").async {
        guard entered.wait(timeout: .now() + 5) == .success else {
            edited.finish(throwing: VaultError.invalid("Publication never entered.")); return
        }
        editAttempt.signal()
        Task {
            do {
                _ = try await second.save(publicationPermitDocument("edited"), pageID: pageID, condition: .replace(expected: snapshot.revision))
                order.append("canonical-commit"); edited.finish()
            } catch { edited.finish(throwing: error) }
        }
    }
    DispatchQueue(label: "noema.publication-release").async {
        if revokeAttempt.wait(timeout: .now() + 5) == .success { attemptsObserved.append("revoke") }
        if editAttempt.wait(timeout: .now() + 5) == .success { attemptsObserved.append("edit") }
        release.signal()
    }
    for try await _ in publication {}
    for try await _ in revocation {}
    for try await _ in edit {}
    #expect(attemptsObserved.values == ["revoke", "edit"])
    let observed = order.values
    #expect(observed.first == "publication-enter")
    #expect(observed.dropFirst().first == "publication-exit")
    #expect(Set(observed.dropFirst(2)) == Set(["revocation-complete", "canonical-commit"]))
    #expect(throws: (any Error).self) { try permit.withPublication(authority: authority) {} }
    #expect(try await first.load(pageID: pageID).document.blocks.first?.text == "edited")
    try await first.close(); try await second.close()
}

private struct ProtectedEmbeddingFixture: Sendable {
    let root: URL
    let store: SQLiteBlockStore
    let index: SQLiteEmbeddingIndex
    let session: VaultSession
    let gate: VaultAccessGate
    let generation: EmbeddingIndexGeneration
    let snapshot: BlockStoreSnapshot
    let identity: EmbeddingEntityIdentity
    let record: EmbeddingRecord

    static func make() async throws -> Self {
        let root = try publicationPermitRoot()
        let canonical = root.appendingPathComponent("canonical")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        let session = VaultSession(vaultID: UUID(), root: canonical, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let store = try SQLiteBlockStore(canonicalStagingURL: canonical.appendingPathComponent("blocks.sqlite"),
            vaultID: session.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
            schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
        let snapshot = try await store.save(publicationPermitDocument("canonical body"), pageID: UUID(), condition: .createOnly)
        let model = try EmbeddingModelDescriptor(providerID: "mock", modelID: "publication", revision: "1",
            dimensions: 2, maximumInputUTF8Bytes: 128, maximumBatchSize: 1)
        let generation = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: model, chunkingVersion: "1")
        let identity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page,
            entityID: snapshot.pageID, revision: snapshot.revision.token.base64EncodedString())
        let chunk = try EmbeddingChunk(identity: identity, chunkID: "block", ordinal: 0,
            contentFingerprint: "initial", chunkingVersion: "1")
        let record = try EmbeddingRecord(generation: generation, chunk: chunk,
            vector: EmbeddingVector(values: [1, 2], model: model))
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"),
            lease: session.lease, accessGate: gate)
        return Self(root: root, store: store, index: index, session: session, gate: gate,
                    generation: generation, snapshot: snapshot, identity: identity, record: record)
    }
}

private enum ProtectedEmbeddingInterruption: String, CaseIterable, Sendable {
    case edit, remove, authorityRevocation, lock, vaultSwitch
}

@Test(.serialized, arguments: ProtectedEmbeddingInterruption.allCases)
private func embeddingSQLitePublicationRejectsFinalBoundaryChanges(_ interruption: ProtectedEmbeddingInterruption) async throws {
    let f = try await ProtectedEmbeddingFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let authority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: f.generation)
    let initialPermit = try await f.store.embeddingPublicationPermit(pageID: f.snapshot.pageID, expected: f.snapshot.revision)
    try await f.index.replaceDocument(identity: f.identity, generation: f.generation, records: [f.record],
        permit: initialPermit, authority: authority, validatePublication: {})
    let permit = try await f.store.embeddingPublicationPermit(pageID: f.snapshot.pageID, expected: f.snapshot.revision)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let validations = Mutex(0)
    let publication = Task.detached {
        try await f.index.replaceDocument(identity: f.identity, generation: f.generation, records: [],
            permit: permit, authority: authority, validatePublication: {
                let finalBoundary = validations.withLock { count in count += 1; return count == 2 }
                if finalBoundary {
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else { throw VaultError.invalid("Index boundary release timed out.") }
                }
            })
    }
    #expect(await publicationBoundaryReached(entered))
    switch interruption {
    case .edit:
        _ = try await f.store.save(publicationPermitDocument("changed before derived COMMIT"),
            pageID: f.snapshot.pageID, condition: .replace(expected: f.snapshot.revision))
    case .remove:
        let trashed = try await f.store.setTrashed(pageID: f.snapshot.pageID, expected: f.snapshot.revision, trashed: true)
        let collection = try await f.store.canonicalVaultRevision()
        try await f.store.purgeCanonicalEntity(id: f.snapshot.pageID, kind: .page,
            expected: trashed.revision, expectedVaultRevision: collection)
    case .authorityRevocation:
        authority.invalidate()
    case .lock:
        f.gate.updateState(.locking(f.session))
    case .vaultSwitch:
        f.gate.updateState(.open(VaultSession(vaultID: UUID(), root: f.root.appendingPathComponent("other"), generation: 2)))
    }
    release.signal()
    await #expect(throws: (any Error).self) { try await publication.value }
    // Restore only fixture read access, then verify the failed derived transaction rolled back.
    // The original authority remains revoked after session invalidation.
    f.gate.updateState(.open(f.session))
    #expect(try await f.index.records(generation: f.generation) == [f.record])
    try await f.store.close()
}

@Test func embeddingSQLitePublicationRejectsWrongEntityAndGenerationAuthority() async throws {
    let f = try await ProtectedEmbeddingFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let permit = try await f.store.embeddingPublicationPermit(pageID: f.snapshot.pageID, expected: f.snapshot.revision)
    let differentGeneration = try EmbeddingIndexGeneration(vaultID: f.session.vaultID,
        model: f.generation.model, chunkingVersion: f.generation.chunkingVersion)
    let authority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: differentGeneration)
    await #expect(throws: (any Error).self) {
        try await f.index.replaceDocument(identity: f.identity, generation: f.generation, records: [f.record],
            permit: permit, authority: authority, validatePublication: {})
    }
    let rightAuthority = try EmbeddingPublicationAuthority(accessGate: f.gate, lease: f.session.lease, generation: f.generation)
    let wrongIdentity = try EmbeddingEntityIdentity(vaultID: f.session.vaultID, entityKind: .source,
        entityID: f.snapshot.pageID, revision: f.identity.revision)
    await #expect(throws: (any Error).self) {
        try await f.index.replaceDocument(identity: wrongIdentity, generation: f.generation, records: [],
            permit: permit, authority: rightAuthority, validatePublication: {})
    }
    #expect(try await f.index.records(generation: f.generation).isEmpty)
    try await f.store.close()
}
