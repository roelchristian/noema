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
        #expect(store.state.withLock { $0.writes } == [note.relativePath])
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
        #expect(store.state.withLock { $0.reads } == [path])
        #expect(try store.base.read(at: path) == bytes)
        #expect(store.state.withLock { $0.writes.isEmpty })
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
        let journal = try RecoveryStore(directory: journalURL)
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
        let reopenedJournal = try RecoveryStore(directory: journalURL)
        #expect(try await reopenedJournal.drafts().first?.body == draft.body)
        #expect(store.state.withLock { $0.writes.contains { $0.hasPrefix("Conflicts/") } })
    }
}
