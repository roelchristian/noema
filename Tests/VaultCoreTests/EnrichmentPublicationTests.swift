import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class EnrichmentStoreProbe: VaultContentStore {
    struct State { var writes: [String] = []; var fail = false; var race: Data? }
    let base: PlaintextVaultContentStore
    let state = Mutex(State())
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data { try base.read(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func changeToken(at path: String) throws -> VaultContentChangeToken? { try base.changeToken(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        let pending = state.withLock { value -> (Bool, Data?) in
            value.writes.append(path)
            let result = (value.fail, value.race); value.race = nil
            return result
        }
        if pending.0 { throw VaultError.storage("Injected write failure") }
        if let race = pending.1 { try base.write(race, at: path, condition: condition) }
        try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        try base.move(from: source, to: destination, expected: expected)
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

struct EnrichmentPublicationTests {
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/enrichment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private var facts: SummaryProvenance {
        SummaryProvenance(provider: "OpenAI", model: "test", generatedAt: Date(timeIntervalSince1970: 100), generationID: UUID())
    }
    private var classification: LCCClassification { LCCClassification(code: "QA76", level: .schedule, caption: "Untrusted caption") }

    @Test func pageArtifactsCommitTogetherAndRegenerationPreservesHumanContent() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnrichmentStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Human title", body: "Human body\n\n## Heading\nMore text", lcc: "Legacy manual value")
        let snapshot = try await repo.pageSummarySnapshot(note)
        let provenance = facts
        store.state.withLock { $0.writes = [] }
        let saved = try await repo.publishPageEnrichment(snapshot, summary: "New summary", classification: classification,
            title: "Ignored generated title", provenance: provenance, validate: {})
        #expect(store.state.withLock { $0.writes } == [note.relativePath])
        #expect(saved.title == note.title)
        #expect(saved.aiTitleProvenance == nil)
        #expect(saved.lcc == "QA76")
        #expect(saved.lccClassification?.caption == LCCClassificationVocabulary.caption(for: "QA76"))
        #expect(saved.lccClassification?.provenance?.generationID == provenance.generationID)
        #expect(BlockDocumentCodec.decode(saved.body).aiSummary?.metadata.extra["aiGenerationID"] == provenance.generationID?.uuidString.lowercased())
        #expect(BlockDocumentCodec.readable(BlockDocumentCodec.decode(saved.body).withoutAISummary) == BlockDocumentCodec.readable(BlockDocumentCodec.decode(note.body)))
        let again = try await repo.pageSummarySnapshot(saved)
        let cleared = try await repo.publishPageEnrichment(again, summary: "Replacement", classification: nil, provenance: facts, validate: {})
        #expect(cleared.lcc == nil && cleared.lccClassification == nil && cleared.aiLCCProvenance == nil)
        #expect(cleared.title == note.title)
        let reopened = try FileVaultRepository.open(root: root, contentStore: store)
        #expect(try await reopened.scan().notes.first == cleared)
    }

    @Test func initialUntitledTitleAndClassificationShareGeneration() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try FileVaultRepository.open(root: root, create: true)
        let note = try await repo.create(title: "Untitled", body: "Original")
        let provenance = facts
        let snapshot = try await repo.pageSummarySnapshot(note)
        let result = try await repo.publishPageEnrichment(snapshot, summary: "Summary", classification: classification,
            title: "Generated topic", provenance: provenance, validate: {})
        #expect(result.title == "Generated topic" && result.aliases == ["Untitled"])
        #expect(result.aiTitleProvenance?.generationID == result.aiLCCProvenance?.generationID)
        #expect(result.aiLCCProvenance?.sourceRevision == snapshot.sourceRevision)
    }

    @Test(arguments: [false, true]) func pageFailureOrRacePreservesCoherentCanonicalBytes(race: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnrichmentStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Existing", body: "Original", lcc: "QA")
        let snapshot = try await repo.pageSummarySnapshot(note)
        var external = note; external.body = "External edit"; external.lcc = "Q"
        let original = try store.base.read(at: note.relativePath)
        let competing = try NoteCodec.encode(external)
        store.state.withLock { $0.fail = !race; $0.race = race ? competing : nil }
        await #expect(throws: (any Error).self) {
            try await repo.publishPageEnrichment(snapshot, summary: "Rejected", classification: classification, provenance: facts, validate: {})
        }
        #expect(try store.base.read(at: note.relativePath) == (race ? competing : original))
    }

    @Test func authorizationInvalidClassificationAndTitleCollisionNeverWrite() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnrichmentStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Untitled", body: "Original")
        _ = try await repo.create(title: "Occupied", body: "Other")
        let snapshot = try await repo.pageSummarySnapshot(note)
        store.state.withLock { $0.writes = [] }
        await #expect(throws: (any Error).self) {
            try await repo.publishPageEnrichment(snapshot, summary: "Summary", classification: classification, provenance: facts, validate: { throw CancellationError() })
        }
        await #expect(throws: (any Error).self) {
            try await repo.publishPageEnrichment(snapshot, summary: "Summary", classification: LCCClassification(code: "QA9999.9", level: .schedule, caption: "Fake"), provenance: facts, validate: {})
        }
        await #expect(throws: (any Error).self) {
            try await repo.publishPageEnrichment(snapshot, summary: "Summary", classification: classification, title: "Occupied", provenance: facts, validate: {})
        }
        #expect(store.state.withLock { $0.writes.isEmpty })
    }

    @Test func sourcePublicationIsOneWriteAndPreservesTitleAndOriginal() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnrichmentStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let original = Data("Complete captured text".utf8)
        let source = try await repo.importSource(data: original, filename: "source.txt", title: "Human source", originURL: nil)
        let snapshot = try await repo.sourceSummarySnapshot(id: source.id)
        let provenance = facts
        store.state.withLock { $0.writes = [] }
        let saved = try await repo.publishSourceEnrichment(snapshot, summary: "Summary", classification: classification, title: "Generated title", provenance: provenance, validate: {})
        #expect(saved.title == source.title && saved.body == source.body)
        #expect(saved.metadata.lcc == "QA76")
        #expect(saved.metadata.aiSummaryProvenance?.generationID == saved.metadata.lccClassification?.provenance?.generationID)
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        #expect(store.state.withLock { $0.writes } == [path])
        #expect(try FileVaultRepository.readSourceOriginal(saved, root: root, contentStore: store) == original)
        let before = try store.base.read(at: path)
        let next = try await repo.sourceSummarySnapshot(id: source.id)
        store.state.withLock { $0.fail = true }
        await #expect(throws: (any Error).self) {
            try await repo.publishSourceEnrichment(next, summary: "Failed replacement", classification: nil, provenance: facts, validate: {})
        }
        #expect(try store.base.read(at: path) == before)
    }

    @Test func composedPageCreatedOnceWithAllArtifactsAndCapturedSourceRelationship() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnrichmentStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let source = try await repo.importSource(data: Data("Original source".utf8), filename: "source.txt", title: "Source", originURL: nil)
        let snapshot = try await repo.sourceSummarySnapshot(id: source.id)
        let id = UUID()
        store.state.withLock { $0.writes = [] }
        let result = try await repo.createEnrichedPage(id: id, title: "Created", body: "Generated body", summary: "Generated summary", classification: classification, provenance: facts, source: snapshot, validate: {})
        #expect(result.id == id && result.linkedSourceIDs == [source.id])
        #expect(result.lcc == "QA76")
        #expect(result.aiTitleProvenance?.generationID == result.aiLCCProvenance?.generationID)
        #expect(store.state.withLock { $0.writes } == [result.relativePath])
        await #expect(throws: (any Error).self) {
            try await repo.createEnrichedPage(id: id, title: "Other", body: "Body", summary: "Summary", classification: nil, provenance: facts, validate: {})
        }
        await #expect(throws: (any Error).self) {
            try await repo.createEnrichedPage(title: "Created", body: "Body", summary: "Summary", classification: nil, provenance: facts, validate: {})
        }
        #expect(try await repo.scan().notes.count == 1)
    }

    @Test func composedPageRefusesChangedSourceAndRevokedPermissionWithoutCreatingPage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EnrichmentStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let source = try await repo.importSource(data: Data("Original source".utf8), filename: "source.txt", title: "Source", originURL: nil)
        let snapshot = try await repo.sourceSummarySnapshot(id: source.id)
        _ = try await repo.renameSource(source, title: "Changed")
        await #expect(throws: (any Error).self) {
            try await repo.createEnrichedPage(title: "Stale", body: "Body", summary: "Summary", classification: nil, provenance: facts, source: snapshot, validate: {})
        }
        await #expect(throws: (any Error).self) {
            try await repo.createEnrichedPage(title: "Unauthorized", body: "Body", summary: "Summary", classification: nil, provenance: facts, validate: { throw CancellationError() })
        }
        #expect(try await repo.scan().notes.isEmpty)
    }

    @Test func capturedEnrichmentCannotCrossVaultLockAndNewLease() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try FileVaultRepository.open(root: root, create: true)
        let manager = VaultSessionManager()
        let (_, _, repo) = try await manager.openRepository(root: root)
        let note = try await repo.create(title: "Original", body: "Human content", lcc: "QA")
        let source = try await repo.importSource(data: Data("Source original".utf8), filename: "source.txt", title: "Source", originURL: nil)
        let pageSnapshot = try await repo.pageSummarySnapshot(note)
        let sourceSnapshot = try await repo.sourceSummarySnapshot(id: source.id)
        let store = try PlaintextVaultContentStore(root: root)
        let pageBefore = try store.read(at: note.relativePath)
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        let sourceBefore = try store.read(at: path)
        try await manager.lock()
        await #expect(throws: (any Error).self) {
            try await repo.publishPageEnrichment(pageSnapshot, summary: "Delayed", classification: classification, provenance: facts, validate: {})
        }
        await #expect(throws: (any Error).self) {
            try await repo.publishSourceEnrichment(sourceSnapshot, summary: "Delayed", classification: classification, provenance: facts, validate: {})
        }
        await #expect(throws: (any Error).self) {
            try await repo.createEnrichedPage(title: "Delayed page", body: "Body", summary: "Summary", classification: nil, provenance: facts, source: sourceSnapshot, validate: {})
        }
        #expect(try store.read(at: note.relativePath) == pageBefore)
        #expect(try store.read(at: path) == sourceBefore)
    }

    @Test func legacyValuesAndProvenanceRemainReadableWithoutMigrationWrites() throws {
        let vaultID = UUID()
        let data = Data("---\ntitle: Legacy\nlcc: QA76.73.S95\ncustom: retained\n---\nHuman body".utf8)
        let note = try NoteCodec.decode(data, path: "Wiki/Legacy.md", vaultID: vaultID)
        #expect(note.lcc == "QA76.73.S95" && note.lccClassification == nil)
        let reopened = try NoteCodec.decode(NoteCodec.encode(note), path: note.relativePath, vaultID: vaultID)
        #expect(reopened.lcc == note.lcc && reopened.body == note.body)
        #expect(reopened.originalHeader?.contains("custom: retained") == true)
        let oldFacts = try JSONDecoder().decode(SummaryProvenance.self, from: Data("{\"provider\":\"OpenAI\",\"model\":\"legacy\",\"generatedAt\":0}".utf8))
        #expect(oldFacts.generationID == nil)
        var source = SourceMetadata(id: UUID(), title: "Legacy", capturedAt: "", originalFilename: "a.txt", originURL: nil, sha256: "", storedFilename: "original.txt")
        source.lcc = "Manually entered legacy value"
        let legacy = try JSONDecoder().decode(SourceMetadata.self, from: JSONEncoder().encode(source))
        #expect(legacy.lcc == source.lcc && legacy.lccClassification == nil)
    }
}
