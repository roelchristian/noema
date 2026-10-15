import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class PageStoreProbe: VaultContentStore {
    struct State {
        var reads: [String] = []
        var writes: [String] = []
        var race: Data?
        var deleteBeforeWrite = false
    }
    let base: PlaintextVaultContentStore
    let state = Mutex(State())
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func synchronize(at path: String) throws { try base.synchronize(at: path) }
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.publishCanonicalOriginal(data, metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalOriginal(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalLinked(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data {
        state.withLock { $0.reads.append(path) }
        return try base.read(at: path)
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        let race = state.withLock { state -> (Data?, Bool) in
            state.writes.append(path)
            guard case .replace = condition else { return (nil, false) }
            let race = (state.race, state.deleteBeforeWrite)
            state.race = nil; state.deleteBeforeWrite = false
            return race
        }
        if let external = race.0 { try base.write(external, at: path, condition: condition) }
        if race.1, case .replace(let expected) = condition { try base.delete(at: path, expected: .file(expected)) }
        try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        try base.move(from: source, to: destination, expected: expected)
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

struct WikiPageAdapterTests {
    private func folder() throws -> URL {
        // Keep all fixture files inside the repository's ignored build directory.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/wiki-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }




    @Test func acceptedArtifactsRemainIndependentThroughReopenAndManualCorrection() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PageStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        var document = BlockDocumentCodec.decode("User authored content")
        document.setAISummary("Legacy summary")
        let note = try await repo.create(title: "Original", body: BlockDocumentCodec.encode(document))
        let provenance = SummaryProvenance(provider: "OpenAI", model: "test-model", generatedAt: Date(timeIntervalSince1970: 100))
        let titleSnapshot = try await repo.pageSummarySnapshot(note)
        let titled = try await repo.publishPageTitle(titleSnapshot, title: "Accepted title", provenance: provenance, validate: {})
        #expect(titled.body == note.body)
        #expect(titled.relativePath == note.relativePath)
        #expect(titled.aliases == ["Original"])
        #expect(titled.aiTitleProvenance?.sourceRevision == titleSnapshot.sourceRevision)
        #expect(titled.aiLCCProvenance == nil)
        let lccSnapshot = try await repo.pageSummarySnapshot(titled)
        let classified = try await repo.publishPageLCC(lccSnapshot, lcc: "QA", provenance: provenance, validate: {})
        #expect(classified.title == titled.title)
        #expect(classified.body == titled.body)
        #expect(classified.aiTitleProvenance == titled.aiTitleProvenance)
        let reopened = try await canonicalSchema5TestRepository(root: root, contentStore: store)
        #expect(try await reopened.scan().notes.first == classified)
        let summarySnapshot = try await reopened.pageSummarySnapshot(classified)
        let summarized = try await reopened.publishPageSummary(summarySnapshot, summary: "Explicit replacement", provenance: provenance, validate: {})
        #expect(summarized.title == classified.title && summarized.lcc == "QA")
        #expect(summarized.aiTitleProvenance == classified.aiTitleProvenance)
        #expect(summarized.aiLCCProvenance == classified.aiLCCProvenance)
        #expect(BlockDocumentCodec.decode(summarized.body).aiSummary?.metadata.extra["aiSourceRevision"] == titleSnapshot.sourceRevision)
        var corrected = summarized; corrected.lcc = "Q"
        let saved = try await reopened.save(note: corrected, title: "Manual title", body: corrected.body, tags: corrected.tags)
        #expect(saved.aiTitleProvenance == nil && saved.aiLCCProvenance == nil)
        #expect(saved.body == summarized.body)
        #expect(saved.title == "Manual title" && saved.lcc == "Q")
    }

    @Test func legacyProvenanceIsAbsentAndUnknownFrontmatterSurvives() throws {
        let data = Data("---\ntitle: Legacy\nlcc: QA\ncustom: retained\n---\nExisting content".utf8)
        let note = try NoteCodec.decode(data, path: "Wiki/Legacy.md", vaultID: UUID())
        #expect(note.aiTitleProvenance == nil && note.aiLCCProvenance == nil)
        let saved = try NoteCodec.decode(NoteCodec.encode(note), path: note.relativePath, vaultID: UUID())
        #expect(saved.originalHeader?.contains("custom: retained") == true)
        #expect(saved.title == note.title && saved.lcc == note.lcc && saved.body == note.body)
        let provenance = try JSONDecoder().decode(SummaryProvenance.self, from: Data("{\"provider\":\"OpenAI\",\"model\":\"legacy-model\",\"generatedAt\":0}".utf8))
        #expect(provenance.sourceRevision == nil)
    }

    @Test func titleAndClassificationRefuseStaleInvalidAndUnauthorizedWrites() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PageStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Original", body: "Original body")
        let provenance = SummaryProvenance(provider: "OpenAI", model: "test", generatedAt: Date())
        let snapshot = try await repo.pageSummarySnapshot(note)
        let bytes = note
        await #expect(throws: (any Error).self) {
            try await repo.publishPageTitle(snapshot, title: "Rejected", provenance: provenance, validate: { throw CancellationError() })
        }
        await #expect(throws: (any Error).self) {
            try await repo.publishPageLCC(snapshot, lcc: "QA9999.9", provenance: provenance, validate: {})
        }
        _ = try await repo.create(title: "Occupied", body: "Peer")
        await #expect(throws: (any Error).self) {
            try await repo.publishPageTitle(snapshot, title: "Occupied", provenance: provenance, validate: {})
        }
        #expect(try await repo.scan().notes.first { $0.id == note.id } == bytes)
        var external = note; external.title = "Manual correction"; external.lcc = "Q"
        let externalBytes = try await repo.save(note: external, title: external.title, body: external.body, tags: external.tags)
        await #expect(throws: (any Error).self) {
            try await repo.publishPageTitle(snapshot, title: "Delayed title", provenance: provenance, validate: {})
        }
        await #expect(throws: (any Error).self) {
            try await repo.publishPageLCC(snapshot, lcc: "QA", provenance: provenance, validate: {})
        }
        #expect(try await repo.scan().notes.first { $0.id == note.id } == externalBytes)
        let corrected = try #require(try await repo.scan().notes.first { $0.id == note.id })
        let locked = try await repo.setEditingLock(note: corrected, locked: true)
        await #expect(throws: (any Error).self) { try await repo.pageSummarySnapshot(locked) }
    }


    @Test func clearingOptionalClassificationAndProvenancePreservesUnknownYAML() throws {
        let data = Data("""
        ---
        title: Original
        lcc: QA
        ai_title_provenance:
          provider: OpenAI
          model: test
          generated_at: '2026-01-01T00:00:00Z'
        ai_lcc_provenance:
          provider: OpenAI
          model: test
          generated_at: '2026-01-01T00:00:00Z'
        custom:
          nested: retained
        ---
        Existing content
        """.utf8)
        let vaultID = UUID()
        var note = try NoteCodec.decode(data, path: "Wiki/Original.md", vaultID: vaultID)
        #expect(note.lcc == "QA" && note.aiTitleProvenance?.provider == "OpenAI")
        note.lcc = nil; note.aiTitleProvenance = nil; note.aiLCCProvenance = nil
        let encoded = try NoteCodec.encode(note)
        let cleared = try NoteCodec.decode(encoded, path: note.relativePath, vaultID: vaultID)
        #expect(cleared.lcc == nil)
        #expect(cleared.aiTitleProvenance == nil && cleared.aiLCCProvenance == nil)
        #expect(cleared.originalHeader?.contains("nested: retained") == true)
        #expect(cleared.body == note.body)
        #expect(String(decoding: encoded, as: UTF8.self).contains("ai_title_provenance") == false)
    }


}


extension WikiPageAdapterTests {
    @Test func markdownRoundTripPreservesUnknownMetadata() throws {
        let id = UUID()
        let input = Data("---\nid: \(id.uuidString)\ntitle: Pertinax\ntags: [history]\ncustom:\n  confidence: tentative\n  values: [one, two]\n---\n## Personal context\n\nMy own perspective. [[Rome|the city]] #learning\n".utf8)
        var note = try NoteCodec.decode(input, path: "Wiki/Pertinax.md", vaultID: UUID())
        note.title = "Pertinax in my reading"; note.updatedAt = timestamp()
        let output = try NoteCodec.encode(note)
        let decoded = try NoteCodec.decode(output, path: note.relativePath, vaultID: UUID())
        #expect(decoded.id == id)
        #expect(decoded.body == note.body)
        #expect(decoded.originalHeader?.contains("confidence: tentative") == true)
        #expect(decoded.originalHeader?.contains("values:") == true)
        #expect(decoded.allTags == ["history", "learning"])
    }

    @Test func malformedTextAndFrontmatterAreRejected() throws {
        for input in [Data([0xff, 0xfe, 0xfd]), Data("---\ntitle: [unclosed\n---\nbody".utf8), Data("---\ntitle: x\nbody".utf8), Data("---\nid: not-a-uuid\n---\nbody".utf8)] {
            #expect(throws: (any Error).self) { try NoteCodec.decode(input, path: "Wiki/bad.md", vaultID: UUID()) }
        }
    }


    @Test func renameAliasesAndDuplicateTitleValidation() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await canonicalSchema5TestRepository(root: folder, create: true)
        let original = try await repo.create(title: "Pertinax", body: "My history notes")
        let renamed = try await repo.save(note: original, title: "Pertinax and leadership", body: original.body, tags: ["History"])
        #expect(renamed.id == original.id)
        #expect(renamed.aliases == ["Pertinax"])
        #expect(renamed.tags == ["history"])
        let other = try await repo.create(title: "Other", body: "")
        await #expect(throws: (any Error).self) { try await repo.save(note: other, title: "pertinax", body: "", tags: []) }
    }

    @Test func deletedPageCannotBeSilentlyRecreatedByStaleEditor() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await canonicalSchema5TestRepository(root: folder, create: true)
        let note = try await repo.create(title: "Deleted", body: "Original")
        try await repo.trash(note: note)
        await #expect(throws: (any Error).self) { try await repo.save(note: note, title: note.title, body: "Draft", tags: []) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(note.relativePath).path))
    }


    @Test func articleLockPersistsAndRejectsEdits() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await canonicalSchema5TestRepository(root: folder, create: true)
        var note = try await repo.create(title: "Locked", body: "Original")
        note.editingLocked = true
        note = try await repo.save(note: note, title: note.title, body: note.body, tags: note.tags)
        #expect(note.isEditingLocked)
        await #expect(throws: (any Error).self) { try await repo.save(note: note, title: "Changed", body: "Changed", tags: []) }
        #expect(try await repo.scan().notes.first?.isEditingLocked == true)
        note.editingLocked = false
        note = try await repo.save(note: note, title: note.title, body: note.body, tags: note.tags)
        #expect(!note.isEditingLocked)
        let edited = try await repo.save(note: note, title: note.title, body: "Changed", tags: [])
        #expect(canonicalTestReadableBody(edited.body) == "Changed")
    }

    @Test func editingLockMetadataPreservesContentTimestampAndRejectsStaleWrites() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await canonicalSchema5TestRepository(root: folder, create: true)
        _ = try await repo.create(title: "Page", body: "Original #tag")

        let note = try #require(try await repo.scan().notes.first)
        let locked = try await repo.setEditingLock(note: note, locked: true)
        #expect(locked.isEditingLocked)
        #expect(locked.updatedAt == note.updatedAt)
        #expect(locked.body == note.body && locked.tags == note.tags && locked.relativePath == note.relativePath)
        await #expect(throws: (any Error).self) { try await repo.setEditingLock(note: note, locked: false) }
        #expect(try await repo.scan().notes.first?.isEditingLocked == true)
        let unlocked = try await repo.setEditingLock(note: locked, locked: false)
        #expect(!unlocked.isEditingLocked && unlocked.updatedAt == note.updatedAt)
        let edited = try await repo.save(note: unlocked, title: unlocked.title, body: "New content", tags: unlocked.tags)
        let relocked = try await repo.setEditingLock(note: edited, locked: true)
        #expect(edited.updatedAt >= note.updatedAt)
        #expect(relocked.updatedAt == edited.updatedAt && canonicalTestReadableBody(relocked.body) == "New content")
    }
}
