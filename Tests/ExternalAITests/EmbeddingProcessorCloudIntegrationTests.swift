import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore

private struct CloudIndexAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws {}
}

private final class CloudIndexKeychain: ExternalAIKeychain, Sendable {
    private let value = Mutex<Data?>(nil)
    func read() throws -> Data? { value.withLock { $0 } }
    func write(_ data: Data) throws { value.withLock { $0 = data } }
    func delete() throws { value.withLock { $0 = nil } }
}

/// This exercises the actual restricted OpenAI request path, with no network or live key.
private actor CloudIndexTransport: OpenAITransporting {
    private(set) var requests: [URLRequest] = []
    func perform(_ request: URLRequest,
                 beforeDispatch: @Sendable (@Sendable () -> Void) throws -> Void,
                 didDispatch: @escaping @Sendable () -> Void) async throws -> OpenAIHTTPResponse {
        let started = Mutex(false)
        try beforeDispatch { started.withLock { $0 = true } }
        guard started.withLock({ $0 }) else { throw ExternalAIError.cancelled }
        requests.append(request)
        didDispatch()
        let body = try JSONSerialization.data(withJSONObject: [
            "object": "list", "model": "text-embedding-3-small",
            "data": [["object": "embedding", "index": 0,
                      "embedding": Array(repeating: 0.25, count: 1_536)]],
            "usage": ["prompt_tokens": 9, "total_tokens": 9]
        ])
        return OpenAIHTTPResponse(statusCode: 200, body: body)
    }
}

private struct CloudIndexFixture: Sendable {
    let repository: FileVaultRepository
    let manager: VaultSessionManager
    let lease: VaultSessionLease
    let index: SQLiteEmbeddingIndex
    let broker: ExternalAICredentialBroker
    let sessions: ExternalAISessionManager
    let authorizer: ExternalAIEmbeddingAuthorizer
    let generation: EmbeddingIndexGeneration
    let authority: EmbeddingPublicationAuthority
    let transport: CloudIndexTransport

    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-04b/cloud-fixtures/\(UUID())")
        let canonical = root.appendingPathComponent("canonical")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: canonical, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, lease, repository) = try await manager.openRepository(root: canonical)
        let broker = ExternalAICredentialBroker(keychain: CloudIndexKeychain())
        try await broker.store("synthetic-cloud-index-key")
        let sessions = ExternalAISessionManager(accessGate: manager.accessGate, credentialBroker: broker,
            authenticator: CloudIndexAuthenticator(), observeSystemEvents: false)
        let transport = CloudIndexTransport()
        let authorizer = ExternalAIEmbeddingAuthorizer(credentialBroker: broker, sessionManager: sessions,
            accessGate: manager.accessGate, transport: transport)
        let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: authorizer.descriptor,
            chunkingVersion: EmbeddingChunker.version)
        let authority = try EmbeddingPublicationAuthority(accessGate: manager.accessGate, lease: lease,
            generation: generation)
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"),
            lease: lease, accessGate: manager.accessGate)
        return Self(repository: repository, manager: manager, lease: lease, index: index, broker: broker,
            sessions: sessions, authorizer: authorizer, generation: generation, authority: authority, transport: transport)
    }

    func processor(approval: @escaping EmbeddingRequestExecutor.ApproveRequest = {
        try ExternalAIEmbeddingConsent(approvingDocument: $0)
    }, afterEvidence: @escaping @Sendable () async throws -> Void = {}) throws -> EmbeddingWorkProcessor {
        let executor = EmbeddingRequestExecutor(authorizer: authorizer, publicationAuthority: authority,
            approveRequest: approval)
        let gate = manager.accessGate, lease = lease
        return try EmbeddingWorkProcessor(repository: repository, index: index, generation: generation,
            lease: lease, publicationAuthority: authority, dispatch: { inputs, scope, execution in
                let context = try EmbeddingExecutionContext(lease: execution.lease, scope: scope,
                    model: executor.descriptor, validateCurrentAuthority: { try execution.validate() })
                let completed = try await executor.embedWithEvidence(inputs.map(\.text), scope: scope, context: context)
                try await afterEvidence()
                // Capturing the evidence, rather than only its vector array, retains
                // issuer/session/credential revocation callbacks through derived COMMIT.
                return EmbeddingDispatchResult(vectors: completed.result.vectors,
                    validatePublication: { try completed.validatePublication() })
            }, extractOriginal: {
                guard let text = String(data: $0.original, encoding: .utf8) else {
                    throw EmbeddingInputPreparationError.unavailableOriginal
                }
                return text
            }, validateAuthority: {
                try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID,
                    operation: "cloud.embedding.processor")
            })
    }

    func snapshot(_ processor: EmbeddingWorkProcessor, kind: AIEntityKind = .page, id: UUID,
                  revision: String) async throws -> any AIWorkSnapshot {
        let item = AIWorkItem(key: .init(vaultID: lease.vaultID, entityKind: kind, entityID: id,
            processorID: processor.descriptor.identifier), revision: revision,
            processorVersion: processor.descriptor.version, eligibleAt: Date())
        return try await processor.prepare(item, lease: lease)
    }

    var context: AIProcessingExecutionContext {
        let gate = manager.accessGate, lease = lease
        return .init(lease: lease, validate: {
            try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID,
                operation: "cloud.embedding.processor.commit")
        })
    }
}

struct EmbeddingProcessorCloudIntegrationTests {
    @Test func openAICommittedPagesAndSourcesPublishWithoutCanonicalMutation() async throws {
        let f = try await CloudIndexFixture.make()
        let approvals = Mutex<[ExternalAIEmbeddingRequest]>([])
        let processor = try f.processor(approval: { request in
            approvals.withLock { $0.append(request) }
            return try ExternalAIEmbeddingConsent(approvingDocument: request)
        })
        let page = try await f.repository.create(title: "Human title", body: "A committed human paragraph.")
        let source = try await f.repository.importSource(data: Data("The complete original source paragraph.".utf8),
            filename: "source.txt", title: "Source human title", originURL: nil)
        let before = try await f.repository.aiProcessingInventory()
        for (kind, id) in [(AIEntityKind.page, page.id), (.source, source.id)] {
            let revision = try #require(before.first { $0.entityID == id }?.revision)
            let snapshot = try await f.snapshot(processor, kind: kind, id: id, revision: revision)
            _ = try await processor.execute(snapshot, context: f.context)
        }
        let after = try await f.repository.aiProcessingInventory()
        #expect(before == after)
        let records = try await f.index.records(generation: f.generation)
        #expect(records.count == 2)
        #expect(Set(records.map { $0.chunk.identity.entityKind }) == [.page, .source])
        #expect(try await f.index.completedDocuments(generation: f.generation).count == 2)
        let requests = approvals.withLock { $0 }
        #expect(requests.count == 2)
        #expect(Set(requests.map(\.id)).count == 2)
        #expect(requests.allSatisfy {
            if case .document(let identity) = $0.scope { return identity.vaultID == f.lease.vaultID }
            return false
        })
        #expect(requests.map(\.inputs) == [["A committed human paragraph."], ["The complete original source paragraph."]])
        #expect(await f.transport.requests.count == 2)
    }

    @Test func openAIUnchangedStructuralChunkReusesVectorAndAdvancesRevision() async throws {
        let f = try await CloudIndexFixture.make(), processor = try f.processor()
        let retained = EditorBlock(runs: [.init("A retained human paragraph.")])
        var changed = EditorBlock(runs: [.init("An old human paragraph.")])
        let page = try await f.repository.create(title: "Human title",
            body: BlockDocumentCodec.encode(.init(blocks: [retained, changed])))
        let first = try await f.snapshot(processor, id: page.id, revision: page.contentHash)
        _ = try await processor.execute(first, context: f.context)
        #expect(await f.transport.requests.count == 2)
        changed.runs = [.init("A newly changed human paragraph.")]
        let saved = try await f.repository.save(note: page, title: page.title,
            document: .init(blocks: [retained, changed]), tags: [])
        let second = try await f.snapshot(processor, id: saved.id, revision: saved.contentHash)
        _ = try await processor.execute(second, context: f.context)
        #expect(await f.transport.requests.count == 3)
        let records = try await f.index.records(generation: f.generation)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.chunk.identity.revision == saved.contentHash })
        #expect(try await f.index.completedDocuments(generation: f.generation).first?.workRevision == saved.contentHash)
    }

    @Test func openAIEmptyDocumentCompletesWithoutConsentOrSubmission() async throws {
        let f = try await CloudIndexFixture.make()
        let processor = try f.processor(approval: { _ in throw ExternalAIError.consentRequired })
        let page = try await f.repository.create(title: "Empty human page", body: "")
        let snapshot = try await f.snapshot(processor, id: page.id, revision: page.contentHash)
        _ = try await processor.execute(snapshot, context: f.context)
        #expect(await f.transport.requests.isEmpty)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
        #expect(try await f.index.completedDocuments(generation: f.generation).contains {
            $0.identity.entityID == page.id && $0.workRevision == page.contentHash && $0.chunkCount == 0
        })
    }

    @Test func openAIDeclinedEmbeddingConsentNeverSubmitsAndCanonicalSaveStillWorks() async throws {
        let f = try await CloudIndexFixture.make()
        let processor = try f.processor(approval: { _ in throw ExternalAIError.consentRequired })
        let page = try await f.repository.create(title: "Private page", body: "Committed private content.")
        let snapshot = try await f.snapshot(processor, id: page.id, revision: page.contentHash)
        await #expect(throws: ExternalAIError.consentRequired) {
            try await processor.execute(snapshot, context: f.context)
        }
        #expect(await f.transport.requests.isEmpty)
        let saved = try await f.repository.save(note: page, title: page.title, body: "Later canonical content.", tags: [])
        #expect(saved.contentHash != page.contentHash)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    }

    @Test(arguments: ["issuer", "credential", "session", "authority"])
    func openAICompletedResponseCannotPublishAfterRevocation(_ change: String) async throws {
        let f = try await CloudIndexFixture.make()
        let processor = try f.processor(afterEvidence: {
            switch change {
            case "issuer": f.authorizer.invalidate()
            case "credential": try await f.broker.replace("synthetic-replacement-cloud-index-key")
            case "session": f.sessions.revoke()
            default: f.authority.invalidate()
            }
        })
        let page = try await f.repository.create(title: "Human page", body: "Human committed paragraph.")
        let snapshot = try await f.snapshot(processor, id: page.id, revision: page.contentHash)
        await #expect(throws: (any Error).self) { try await processor.execute(snapshot, context: f.context) }
        #expect(await f.transport.requests.count == 1)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    }

    @Test(arguments: ["edit", "trash"])
    func openAIResponseCannotPublishOverConcurrentCanonicalMutation(_ change: String) async throws {
        let f = try await CloudIndexFixture.make()
        let page = try await f.repository.create(title: "Human page", body: "Earlier committed paragraph.")
        let processor = try f.processor(afterEvidence: {
            if change == "edit" {
                _ = try await f.repository.save(note: page, title: page.title, body: "Newer committed paragraph.", tags: [])
            } else {
                try await f.repository.trash(note: page)
            }
        })
        let snapshot = try await f.snapshot(processor, id: page.id, revision: page.contentHash)
        await #expect(throws: (any Error).self) { try await processor.execute(snapshot, context: f.context) }
        #expect(await f.transport.requests.count == 1)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    }

    @Test func openAIResponseRejectsIndependentlyChangedOriginalBytes() async throws {
        let f = try await CloudIndexFixture.make()
        let source = try await f.repository.importSource(data: Data("Captured original bytes.".utf8),
            filename: "source.txt", title: "Source", originURL: nil)
        let processor = try f.processor(afterEvidence: {
            let path = f.lease.root.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)")
            try Data("Unexpected external replacement bytes.".utf8).write(to: path)
        })
        let revision = try #require(try await f.repository.aiProcessingInventory().first { $0.entityID == source.id }?.revision)
        let snapshot = try await f.snapshot(processor, kind: .source, id: source.id, revision: revision)
        await #expect(throws: (any Error).self) { try await processor.execute(snapshot, context: f.context) }
        #expect(await f.transport.requests.count == 1)
        #expect(try await f.index.records(generation: f.generation).isEmpty)
        #expect(try await f.index.completedDocuments(generation: f.generation).isEmpty)
    }
}
