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

    @Test func createEditReopenUsesAdapterAndRetainsIdentity() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PageStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Original", body: "First body")
        #expect(store.state.withLock { $0.writes.filter { $0 != "vault.json" } } == [note.relativePath])
        let saved = try await repo.save(note: note, title: "Renamed", body: "Edited body", tags: ["History"])
        #expect(saved.id == note.id)
        #expect(saved.relativePath == note.relativePath)
        #expect(saved.aliases == ["Original"])
        #expect(saved.tags == ["history"])
        let reopened = try FileVaultRepository.open(root: root)
        let fresh = try #require(try await reopened.scan().notes.first)
        #expect(fresh == saved)
        #expect(try store.base.read(at: saved.relativePath) == NoteCodec.encode(saved))
        #expect(store.state.withLock { $0.reads.contains(note.relativePath) })
        try await repo.trash(note: saved)
        let trashed = try #require(try await repo.trashedPages().first)
        #expect(trashed.note.id == note.id)
        #expect(trashed.note.body == saved.body)
        #expect(store.state.withLock { $0.reads.contains(trashed.note.relativePath) })
    }

    @Test func externalScanPreservesBytesAndCachesReads() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PageStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Wiki/Nested"), withIntermediateDirectories: true)
        let path = "Wiki/Nested/External.md"
        let bytes = Data("---\ncustom: retained\n---\nExternal body #outside".utf8)
        try bytes.write(to: root.appendingPathComponent(path))
        let note = try #require(try await repo.scan().notes.first)
        _ = try await repo.scan()
        #expect(store.state.withLock { $0.reads.filter { $0 != "vault.json" } } == [path])
        #expect(try store.base.read(at: path) == bytes)
        #expect(store.state.withLock { $0.writes.allSatisfy { $0 == "vault.json" } })
        let saved = try await repo.save(note: note, title: "External", body: "Saved body", tags: [])
        #expect(saved.id == note.id)
        #expect(saved.originalHeader?.contains("custom: retained") == true)
        var changed = saved; changed.body = "Externally modified to a longer body"
        let external = try NoteCodec.encode(changed)
        try external.write(to: root.appendingPathComponent(path), options: .atomic)
        let fresh = try #require(try await repo.scan().notes.first)
        #expect(fresh.body == changed.body)
        #expect(fresh.contentHash == digest(external))
        #expect(fresh.id == note.id)
    }

    @Test(arguments: [false, true]) func racePreservesCanonicalAndRecoveryDraft(deleted: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PageStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Race", body: "Original")
        var changed = note; changed.body = "External edit"
        let external = try NoteCodec.encode(changed)
        let draft = DraftRecord(note: note, title: note.title, body: "Unsaved competing draft", tags: [])
        let journalURL = root.appendingPathComponent("LocalDrafts")
        let journal = try RecoveryStore(unguardedTestingDirectory: journalURL)
        try await journal.store(draft)
        store.state.withLock { $0.race = deleted ? nil : external; $0.deleteBeforeWrite = deleted }
        do {
            _ = try await repo.save(note: note, title: draft.title, body: draft.body, tags: draft.tags)
            Issue.record("Expected a page conflict")
        } catch VaultError.conflict(let path) {
            let preserved = try NoteCodec.decode(store.base.read(at: "Conflicts/" + URL(fileURLWithPath: path).lastPathComponent), path: note.relativePath, vaultID: repo.manifest.id)
            #expect(preserved.id == note.id)
            #expect(preserved.body == draft.body)
        }
        if deleted { #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(note.relativePath).path)) }
        else { #expect(try store.base.read(at: note.relativePath) == external) }
        let reopenedJournal = try RecoveryStore(unguardedTestingDirectory: journalURL)
        #expect(try await reopenedJournal.drafts().first?.body == draft.body)
        #expect(store.state.withLock { $0.writes.contains { $0.hasPrefix("Conflicts/") } })
    }

    @Test func acceptedArtifactsRemainIndependentThroughReopenAndManualCorrection() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PageStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
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
        let reopened = try FileVaultRepository.open(root: root, contentStore: store)
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
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Original", body: "Original body")
        let provenance = SummaryProvenance(provider: "OpenAI", model: "test", generatedAt: Date())
        let snapshot = try await repo.pageSummarySnapshot(note)
        let bytes = try store.base.read(at: note.relativePath)
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
        #expect(try store.base.read(at: note.relativePath) == bytes)
        var external = note; external.title = "Manual correction"; external.lcc = "Q"
        let externalBytes = try NoteCodec.encode(external)
        try store.base.write(externalBytes, at: note.relativePath, condition: .replace(expected: bytes))
        await #expect(throws: (any Error).self) {
            try await repo.publishPageTitle(snapshot, title: "Delayed title", provenance: provenance, validate: {})
        }
        await #expect(throws: (any Error).self) {
            try await repo.publishPageLCC(snapshot, lcc: "QA", provenance: provenance, validate: {})
        }
        #expect(try store.base.read(at: note.relativePath) == externalBytes)
        let corrected = try #require(try await repo.scan().notes.first { $0.id == note.id })
        let locked = try await repo.setEditingLock(note: corrected, locked: true)
        await #expect(throws: (any Error).self) { try await repo.pageSummarySnapshot(locked) }
    }

    @Test func acceptedPageTitleRejectsRaceInsideConditionalWrite() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PageStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Original", body: "Content")
        let snapshot = try await repo.pageSummarySnapshot(note)
        var external = note; external.lcc = "Q"
        let bytes = try NoteCodec.encode(external)
        store.state.withLock { $0.race = bytes }
        await #expect(throws: (any Error).self) {
            try await repo.publishPageTitle(snapshot, title: "Delayed", provenance: SummaryProvenance(provider: "OpenAI", model: "test", generatedAt: Date()), validate: {})
        }
        #expect(try store.base.read(at: note.relativePath) == bytes)
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

    @Test func duplicateYAMLKeysAreRejectedWithoutRewritingCanonicalBytes() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PageStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let path = "Wiki/Invalid.md"
        let bytes = Data("---\ntitle: Original\nlcc: Q\nlcc: QA\n---\nPreserved content".utf8)
        try store.base.write(bytes, at: path, condition: .createOnly)
        #expect(throws: VaultError.self) { try NoteCodec.decode(bytes, path: path, vaultID: repo.manifest.id) }
        let scanned = try await repo.scan()
        #expect(scanned.notes.isEmpty)
        #expect(scanned.issues.contains { $0.contains("invalid YAML") })
        #expect(try store.base.read(at: path) == bytes)
        #expect(store.state.withLock { $0.writes.allSatisfy { $0 == "vault.json" } })
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

    @Test func externalMarkdownIsNotRewrittenDuringScanning() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let url = folder.appendingPathComponent("Wiki/External.md")
        let original = Data("A page edited outside the app. #outside".utf8)
        try original.write(to: url)
        let scan = try await repo.scan()
        #expect(scan.notes.count == 1)
        #expect(try Data(contentsOf: url) == original)
        let saved = try await repo.save(note: scan.notes[0], title: "External", body: "An updated thought", tags: ["outside"])
        #expect(saved.id == scan.notes[0].id)
        #expect(saved.originalHeader?.contains("id:") == true)
    }

    @Test func renameAliasesAndDuplicateTitleValidation() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
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
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Deleted", body: "Original")
        try FileManager.default.removeItem(at: folder.appendingPathComponent(note.relativePath))
        await #expect(throws: (any Error).self) { try await repo.save(note: note, title: note.title, body: "Draft", tags: []) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(note.relativePath).path))
    }

    @Test func externalMovePreservesIdentityAndDuplicateIDsAreQuarantined() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Move me", body: "Personal context")
        let original = folder.appendingPathComponent(note.relativePath)
        let moved = folder.appendingPathComponent("Wiki/Moved.md")
        try FileManager.default.moveItem(at: original, to: moved)
        let fresh = try await repo.scan().notes[0]
        #expect(fresh.id == note.id)
        #expect(fresh.relativePath == "Wiki/Moved.md")
        try FileManager.default.copyItem(at: moved, to: folder.appendingPathComponent("Wiki/Duplicate.md"))
        let duplicate = try await repo.scan()
        #expect(duplicate.notes.isEmpty)
        #expect(duplicate.issues.contains { $0.contains("Duplicate note ID") })
        await #expect(throws: (any Error).self) { try await repo.save(note: fresh, title: fresh.title, body: "Do not overwrite", tags: []) }
    }

    @Test func articleLockPersistsAndRejectsEdits() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
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
        #expect(edited.body == "Changed")
    }

    @Test func editingLockMetadataPreservesContentTimestampAndRejectsStaleWrites() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let original = try await repo.create(title: "Page", body: "Original #tag")
        var old = original; old.updatedAt = "2020-01-01T00:00:00Z"
        try NoteCodec.encode(old).write(to: folder.appendingPathComponent(original.relativePath), options: .atomic)
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
        #expect(edited.updatedAt > note.updatedAt)
        #expect(relocked.updatedAt == edited.updatedAt && relocked.body == "New content")
    }
}
