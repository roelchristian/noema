import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class TrashStoreProbe: VaultContentStore {
    struct State {
        var operations: [String] = []
        var failMove = false
        var partiallyDeleteSource = false
        var occupyDestination = false
        var race: Data?
        var ledgerRace: Data?
    }
    let base: PlaintextVaultContentStore
    let state = Mutex(State())
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func createDirectory(at path: String) throws {
        state.withLock { $0.operations.append("mkdir " + path) }
        try base.createDirectory(at: path)
    }
    func read(at path: String) throws -> Data {
        state.withLock { $0.operations.append("read " + path) }
        return try base.read(at: path)
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        let race = state.withLock { state -> Data? in
            state.operations.append("write " + path)
            guard path == "Trash Retention.json" else { return nil }
            let race = state.ledgerRace; state.ledgerRace = nil
            return race
        }
        if let race { try base.write(race, at: path, condition: condition) }
        try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        let flags = state.withLock { state -> (Bool, Bool, Data?) in
            state.operations.append("move " + source)
            let flags = (state.failMove, state.occupyDestination, state.race)
            state.failMove = false; state.occupyDestination = false; state.race = nil
            return flags
        }
        if flags.0 { throw VaultContentStoreError.io(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, message: "Injected failed move") }
        if flags.1 { try base.write(Data("Occupied".utf8), at: destination, condition: .createOnly) }
        if let race = flags.2, case .file(let bytes) = expected {
            try base.write(race, at: source, condition: .replace(expected: bytes))
        }
        try base.move(from: source, to: destination, expected: expected)
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws {
        if state.withLock({ $0.partiallyDeleteSource }), case .directory(let files) = expected, let metadata = files["metadata.json"] {
            try base.delete(at: path + "/metadata.json", expected: .file(metadata))
            throw VaultContentStoreError.io(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, message: "Injected partial directory deletion")
        }
        let race = state.withLock { state -> Data? in
            state.operations.append("delete " + path)
            let race = state.race; state.race = nil
            return race
        }
        if let race, case .file(let bytes) = expected {
            try base.write(race, at: path, condition: .replace(expected: bytes))
        }
        try base.delete(at: path, expected: expected)
    }
}

struct TrashAdapterTests {
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/trash-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func manifestTrashRestoreAndDeletionUseAdapter() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        #expect(store.state.withLock { $0.operations.contains("write vault.json") && $0.operations.contains("mkdir Removed Pages") })
        let note = try await repo.create(title: "Preserved", body: "Exact bytes")
        let bytes = try store.base.read(at: note.relativePath)
        try await repo.trash(note: note)
        let entry = try #require(try await repo.trashedPages().first)
        #expect(try store.base.read(at: entry.id) == bytes)
        try await repo.restore(entry)
        let restored = try #require(try await repo.scan().notes.first)
        #expect(restored.id == note.id)
        #expect(try store.base.read(at: restored.relativePath) == bytes)
        try await repo.trash(note: restored)
        let deleted = try #require(try await repo.trashedPages().first)
        try await repo.permanentlyDelete(deleted)
        #expect(try await repo.trashedPages().isEmpty)
        _ = try FileVaultRepository.open(root: root, contentStore: store)
        #expect(store.state.withLock { $0.operations.contains("read vault.json") && $0.operations.contains("move " + entry.id) && $0.operations.contains("delete " + deleted.id) })
    }

    @Test(arguments: ["failure", "collision", "stale"]) func failedTrashPreservesCurrentBytes(mode: String) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Keep", body: "Before")
        let bytes = try store.base.read(at: note.relativePath)
        var external = note; external.body = "External change during move"
        let changed = try NoteCodec.encode(external)
        store.state.withLock { $0.failMove = mode == "failure"; $0.occupyDestination = mode == "collision"; $0.race = mode == "stale" ? changed : nil }
        await #expect(throws: (any Error).self) { try await repo.trash(note: note) }
        #expect(try store.base.read(at: note.relativePath) == (mode == "stale" ? changed : bytes))
        if mode == "collision" {
            let entry = try #require(try await repo.trashedPages().first)
            #expect(try store.base.read(at: entry.id) == Data("Occupied".utf8))
        } else { #expect(try await repo.trashedPages().isEmpty) }
    }

    @Test(arguments: [false, true]) func restoreAndDeleteRejectChangesInsideAdapter(deleting: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Race", body: "Before")
        try await repo.trash(note: note)
        let entry = try #require(try await repo.trashedPages().first)
        var external = entry.note; external.body = "External edit after snapshot"
        let changed = try NoteCodec.encode(external)
        store.state.withLock { $0.race = changed }
        await #expect(throws: (any Error).self) {
            if deleting { try await repo.permanentlyDelete(entry) }
            else { try await repo.restore(entry) }
        }
        #expect(try store.base.read(at: entry.id) == changed)
        #expect(try await repo.scan().notes.isEmpty)
    }

    @Test func legacyFailedMoveAndCollisionKeepBothVersions() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        try store.base.createDirectory(at: ".Trash")
        let bytes = Data("Legacy bytes".utf8), occupied = Data("Existing trash".utf8)
        try store.base.write(bytes, at: ".Trash/Legacy.md", condition: .createOnly)
        try store.base.write(occupied, at: "Removed Pages/Legacy.md", condition: .createOnly)
        store.state.withLock { $0.failMove = true }
        let failed = try await repo.trashedPages()
        #expect(failed.first { $0.id == ".Trash/Legacy.md" }?.readIssue != nil)
        #expect(try store.base.read(at: ".Trash/Legacy.md") == bytes)
        let migrated = try await repo.trashedPages()
        #expect(migrated.count == 2)
        #expect(try store.base.read(at: "Removed Pages/Legacy.md") == occupied)
        let preserved = try #require(migrated.first { $0.id != "Removed Pages/Legacy.md" })
        #expect(try store.base.read(at: preserved.id) == bytes)
    }

    @Test func corruptedTrashAndLedgerRemainProtected() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let damaged = Data("---\ntitle: Unclosed".utf8)
        try store.base.write(damaged, at: "Removed Pages/Damaged.md", condition: .createOnly)
        try store.base.createDirectory(at: "Removed Pages/broken.source")
        try store.base.write(Data("Invalid JSON".utf8), at: "Removed Pages/broken.source/metadata.json", condition: .createOnly)
        let items = try await repo.trashItems()
        #expect(items.count == 2 && items.allSatisfy { $0.readIssue != nil })
        for item in items { await #expect(throws: (any Error).self) { try await repo.restore(item) } }
        let now = Date()
        #expect(try await repo.expireTrash(now: now).isEmpty)
        #expect(try await repo.expireTrash(now: now.addingTimeInterval(16 * 86400)).count == 2)
        let ledger = try store.base.read(at: "Trash Retention.json")
        try store.base.write(Data("Corrupted ledger".utf8), at: "Trash Retention.json", condition: .replace(expected: ledger))
        await #expect(throws: (any Error).self) { _ = try await repo.expireTrash(now: now.addingTimeInterval(30 * 86400)) }
        #expect(try store.base.read(at: "Removed Pages/Damaged.md") == damaged)
        #expect(await repo.emptyTrashItems(items).isEmpty)
    }

    @Test(arguments: [false, true]) func competingLedgerUpdateAbortsExpiration(existing: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let note = try await repo.create(title: "Old", body: "Retain on ledger conflict")
        try await repo.trash(note: note)
        let entry = try #require(try await repo.trashedPages().first)
        if existing { _ = try await repo.expireTrash() }
        if existing {
            // Force an update of the existing ledger as well as the create-only case.
            try store.base.write(Data("Undated".utf8), at: "Removed Pages/Undated.md", condition: .createOnly)
        }
        let now = Date().addingTimeInterval(30 * 86400)
        let competing = try JSONEncoder().encode([entry.id: now])
        store.state.withLock { $0.ledgerRace = competing }
        await #expect(throws: (any Error).self) { _ = try await repo.expireTrash(now: now) }
        #expect(try store.base.read(at: "Trash Retention.json") == competing)
        #expect(try await repo.trashedPages().count == (existing ? 2 : 1))
        #expect(store.state.withLock { !$0.operations.contains("delete " + entry.id) })
    }

    @Test func partialFilesystemDeletionReportsFailureAndPreservesRemainingRecoverableOriginal() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let bytes = Data("Only recoverable source original".utf8)
        let source = try await repo.importSource(data: bytes, filename: "source.txt", title: "Source", originURL: nil)
        try await repo.deleteSource(source)
        let item = try #require(try await repo.trashItems().first)
        store.state.withLock { $0.partiallyDeleteSource = true }
        let failures = await repo.emptyTrashItems([item])
        #expect(failures.count == 1 && failures[0].contains("Injected partial directory deletion"))
        #expect(try store.base.snapshot(at: item.id) == .directory(["original.txt": bytes]))
        let reopened = try FileVaultRepository.open(root: root, contentStore: store)
        let damaged = try #require(try await reopened.trashItems().first)
        #expect(damaged.id == item.id && damaged.readIssue != nil)
        await #expect(throws: (any Error).self) { try await reopened.restore(damaged) }
        // Automatic retention must not discard the remaining content of a damaged record.
        _ = try await reopened.expireTrash(now: Date().addingTimeInterval(60 * 86400))
        #expect(try store.base.read(at: item.id + "/original.txt") == bytes)
    }

    @Test func corruptAndUnsafeManifestNeverRewritten() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let bad = Data("Malformed manifest".utf8)
        try store.base.write(bad, at: "vault.json", condition: .createOnly)
        #expect(throws: (any Error).self) { _ = try FileVaultRepository.open(root: root, create: true, contentStore: store) }
        #expect(try store.base.read(at: "vault.json") == bad)
        try store.base.delete(at: "vault.json", expected: .file(bad))
        try store.base.write(bad, at: "outside.json", condition: .createOnly)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("vault.json"), withDestinationURL: root.appendingPathComponent("outside.json"))
        #expect(throws: (any Error).self) { _ = try FileVaultRepository.open(root: root, create: true, contentStore: store) }
        #expect(try store.base.read(at: "outside.json") == bad)
        #expect(store.state.withLock { !$0.operations.contains("write vault.json") })
    }
}
