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

    // UI.R.REM03: retain migration failure reporting and both versions across URL directory hints.
    @Test(arguments: [false, true]) func legacyFailedMoveAndCollisionKeepBothVersions(rootDirectoryHint: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrashStoreProbe(root: root)
        let repoRoot = URL(fileURLWithPath: root.path, isDirectory: rootDirectoryHint)
        let repo = try FileVaultRepository.open(root: repoRoot, create: true, contentStore: store)
        try store.base.createDirectory(at: ".Trash")
        let bytes = Data("Legacy bytes".utf8), occupied = Data("Existing trash".utf8)
        try store.base.write(bytes, at: ".Trash/Legacy.md", condition: .createOnly)
        try store.base.write(occupied, at: "Removed Pages/Legacy.md", condition: .createOnly)
        store.state.withLock { $0.failMove = true }
        let failed = try await repo.trashedPages()
        #expect(failed.count == 2)
        let legacy = try #require(failed.first { $0.id == ".Trash/Legacy.md" })
        #expect(legacy.readIssue?.contains("Injected failed move") == true)
        #expect(!legacy.canRestore)
        await #expect(throws: (any Error).self) { try await repo.restore(legacy) }
        #expect(try store.base.read(at: ".Trash/Legacy.md") == bytes)
        #expect(try store.base.read(at: "Removed Pages/Legacy.md") == occupied)
        let migrated = try await repo.trashedPages()
        #expect(migrated.count == 2)
        #expect(migrated.allSatisfy { $0.readIssue == nil })
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


extension TrashAdapterTests {
    @Test func missingTrashDoesNotBlockPageCreationOrRecovery() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let trash = folder.appendingPathComponent(FileVaultRepository.trashDirectoryName)
        try FileManager.default.removeItem(at: trash)
        let note = try await repo.create(title: "New page", body: "Original")
        #expect(try await repo.trashedPages().isEmpty)
        #expect(try await repo.scan().notes.map(\.id) == [note.id])
        let saved = try await repo.save(note: note, title: note.title, body: "Saved body", tags: [])
        let bytes = try Data(contentsOf: folder.appendingPathComponent(saved.relativePath))
        try FileManager.default.removeItem(at: trash)
        try await repo.trash(note: saved)
        let page = try #require(await repo.trashedPages().first)
        try await repo.restore(page)
        #expect(try Data(contentsOf: folder.appendingPathComponent(saved.relativePath)) == bytes)
    }

    @Test func trashLockedPagePreservesBytesAndOtherPages() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let other = try await repo.create(title: "Keep", body: "Other page")
        var target = try await repo.create(title: "Trash", body: "Recover me")
        target.editingLocked = true
        target = try await repo.save(note: target, title: target.title, body: target.body, tags: target.tags)
        let bytes = try Data(contentsOf: folder.appendingPathComponent(target.relativePath))
        try await repo.trash(note: target)
        let remaining = try await repo.scan().notes
        #expect(remaining.map(\.id) == [other.id])
        #expect(remaining.first?.body == other.body)
        let trash = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(FileVaultRepository.trashDirectoryName), includingPropertiesForKeys: nil)
        #expect(trash.count == 1)
        #expect(try Data(contentsOf: #require(trash.first)) == bytes)
    }

    @Test func trashRestoreAndPermanentDeletionKeepIdentityAndRejectStaleData() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Restore me", body: "Original")
        let bytes = try Data(contentsOf: folder.appendingPathComponent(note.relativePath))
        try await repo.trash(note: note)
        let trashed = try #require(await repo.trashedPages().first)
        #expect(trashed.note.id == note.id)
        try await repo.restore(trashed)
        let restored = try #require(await repo.scan().notes.first)
        #expect(restored.id == note.id)
        #expect(try Data(contentsOf: folder.appendingPathComponent(restored.relativePath)) == bytes)
        #expect(try await repo.trashedPages().isEmpty)
        try await repo.trash(note: restored)
        let stale = try #require(await repo.trashedPages().first)
        let url = folder.appendingPathComponent(stale.id)
        var changed = stale.note; changed.body = "External change"
        try NoteCodec.encode(changed).write(to: url, options: .atomic)
        await #expect(throws: (any Error).self) { try await repo.restore(stale) }
        await #expect(throws: (any Error).self) { try await repo.permanentlyDelete(stale) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        let fresh = try #require(await repo.trashedPages().first)
        try await repo.permanentlyDelete(fresh)
        #expect(try await repo.trashedPages().isEmpty)
        #expect(try await repo.scan().notes.isEmpty)
    }

    @Test func trashRestoreRejectsOccupiedIdentityAndPathsOutsideTrash() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Keep", body: "Keep me")
        let bytes = try Data(contentsOf: folder.appendingPathComponent(note.relativePath))
        try await repo.trash(note: note)
        let trashed = try #require(await repo.trashedPages().first)
        try bytes.write(to: folder.appendingPathComponent(note.relativePath))
        await #expect(throws: (any Error).self) { try await repo.restore(trashed) }
        await #expect(throws: (any Error).self) { try await repo.permanentlyDelete(TrashedPage(note: note)) }
        #expect(try Data(contentsOf: folder.appendingPathComponent(note.relativePath)) == bytes)
        #expect(try await repo.trashedPages().count == 1)
    }

    @Test func trashDamagedFilesRemainVisibleAndDoNotBlockRecovery() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Recover me", body: "Keep these bytes")
        try await repo.trash(note: note)
        let damagedURL = folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/Damaged.md")
        let bytes = Data("---\ntitle: Unclosed YAML".utf8)
        try bytes.write(to: damagedURL)
        let entries = try await repo.trashedPages()
        #expect(entries.count == 2)
        let damaged = try #require(entries.first { $0.note.title == "Damaged" })
        #expect(damaged.readIssue != nil)
        #expect(!damaged.canRestore)
        #expect(damaged.canPermanentlyDelete)
        await #expect(throws: (any Error).self) { try await repo.restore(damaged) }
        try await repo.restore(#require(entries.first { $0.note.id == note.id }))
        #expect(try await repo.scan().notes.map(\.id) == [note.id])
        #expect(try Data(contentsOf: damagedURL) == bytes)
        try await repo.permanentlyDelete(damaged)
        #expect(try await repo.trashedPages().isEmpty)
    }

    @Test func trashEmptyUsesConfirmedSnapshotAndReportsPartialFailures() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let keep = try await repo.create(title: "Active", body: "Keep me")
        let changed = try await repo.create(title: "Changed", body: "Before")
        let deleted = try await repo.create(title: "Delete", body: "Disposable")
        try await repo.trash(note: changed); try await repo.trash(note: deleted)
        let confirmed = try await repo.trashedPages()
        let stale = try #require(confirmed.first { $0.note.id == changed.id })
        var replacement = stale.note; replacement.body = "Changed after confirmation"
        let replacementBytes = try NoteCodec.encode(replacement)
        try replacementBytes.write(to: folder.appendingPathComponent(stale.id), options: .atomic)
        let later = try await repo.create(title: "Later", body: "Not confirmed")
        try await repo.trash(note: later)
        let failures = await repo.emptyTrash(confirmed)
        #expect(failures.count == 1)
        #expect(failures.first?.contains("Changed") == true)
        #expect(try Data(contentsOf: folder.appendingPathComponent(stale.id)) == replacementBytes)
        let remaining = try await repo.trashedPages()
        #expect(Set(remaining.map { $0.note.id }) == [changed.id, later.id])
        #expect(try await repo.scan().notes.map(\.id) == [keep.id])
        #expect(await repo.emptyTrash(remaining).isEmpty)
        #expect(try await repo.trashedPages().isEmpty)
        #expect(await repo.emptyTrash([]).isEmpty)
    }

    @Test func trashSymlinksCannotDeleteOutsideFiles() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Protected", body: "Keep me")
        let original = folder.appendingPathComponent(note.relativePath)
        let bytes = try Data(contentsOf: original)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/Link.md"), withDestinationURL: original)
        let entries = try await repo.trashedPages()
        let entry = try #require(entries.first)
        #expect(entry.readIssue != nil)
        #expect(!entry.canRestore && !entry.canPermanentlyDelete)
        #expect(await repo.emptyTrash(entries).count == 1)
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func trashSurvivesRefreshAndReopenUntilExplicitDeletion() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Retained", body: "Keep until explicitly restored or deleted")
        let bytes = try Data(contentsOf: folder.appendingPathComponent(note.relativePath))
        try await repo.trash(note: note)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".Trash").path))
        for _ in 0..<3 {
            let reopened = try FileVaultRepository.open(root: folder)
            #expect(try await reopened.scan().notes.isEmpty)
            let entries = try await reopened.trashedPages()
            let retained = try #require(entries.first)
            #expect(entries.count == 1)
            #expect(retained.id.hasPrefix("Removed Pages/"))
            #expect(retained.note.id == note.id)
            #expect(try Data(contentsOf: folder.appendingPathComponent(retained.id)) == bytes)
        }
        let retained = try #require(await repo.trashedPages().first)
        try await repo.restore(retained)
        #expect(try await repo.scan().notes.map(\.id) == [note.id])
    }

    @Test func legacyTrashMigratesWithoutOverwritingOrRewritingBytes() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let legacy = folder.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let filename = "Legacy.md"
        let existing = Data("---\nid: \(UUID())\ntitle: Current trash\n---\nNew storage".utf8)
        let old = Data("---\nid: \(UUID())\ntitle: Legacy trash\ncustom: retained\n---\nKeep original bytes".utf8)
        let damaged = Data("---\nUnclosed YAML".utf8)
        try existing.write(to: folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/" + filename))
        try old.write(to: legacy.appendingPathComponent(filename))
        try damaged.write(to: legacy.appendingPathComponent("Damaged.md"))
        let entries = try await repo.trashedPages()
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.id.hasPrefix("Removed Pages/") })
        #expect(Set(try entries.map { try Data(contentsOf: folder.appendingPathComponent($0.id)) }) == [existing, old, damaged])
        #expect(try FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil).isEmpty)
        #expect(try await repo.trashedPages().count == 3)
        let migrated = try #require(entries.first { $0.note.title == "Legacy trash" })
        try await repo.restore(migrated)
        let restored = try #require(await repo.scan().notes.first)
        #expect(try Data(contentsOf: folder.appendingPathComponent(restored.relativePath)) == old)
        #expect(await repo.emptyTrash(try await repo.trashedPages()).isEmpty)
    }

    @Test func sourceTrashRejectsStaleSnapshotsAndDuplicateRestoration() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let bytes = Data("Preserved original".utf8)
        let source = try await repo.importSource(data: bytes, filename: "original.txt", title: "Source", originURL: nil)
        try await repo.deleteSource(source)
        let item = try #require(await repo.trashItems().first)
        let original = folder.appendingPathComponent(item.id + "/original.txt")
        try Data("Changed".utf8).write(to: original)
        await #expect(throws: (any Error).self) { try await repo.restore(item) }
        await #expect(throws: (any Error).self) { try await repo.permanentlyDelete(item) }
        #expect(try await repo.trashItems().first?.readIssue != nil)
        try bytes.write(to: original)
        _ = try await repo.importSource(data: bytes, filename: "duplicate.txt", title: "Duplicate", originURL: nil)
        await #expect(throws: (any Error).self) { try await repo.restore(item) }
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func trashExpiresAfterFifteenDaysWithLegacyGraceAndDamagedProtection() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let external = folder.appendingPathComponent("linked.txt")
        let bytes = Data("Keep outside vault".utf8); try bytes.write(to: external)
        let linked = try await repo.linkSources(at: external, maximumFiles: 1)[0]
        let imported = try await repo.importSource(data: Data("Import".utf8), filename: "original.txt", title: "Import", originURL: nil)
        let page = try await repo.create(title: "Page", body: "Page")
        try await repo.deleteSource(linked); try await repo.deleteSource(imported); try await repo.trash(note: page)
        let legacy = folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/legacy.md")
        try Data("Legacy body".utf8).write(to: legacy)
        let damaged = folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/damaged.md")
        try Data("---\ntitle: Unclosed".utf8).write(to: damaged)
        let start = Date()
        #expect(try await repo.expireTrash(now: start).isEmpty)
        #expect(try await repo.expireTrash(now: start.addingTimeInterval(14 * 86400)).isEmpty)
        #expect(try await repo.trashItems().count == 5)
        let reopened = try FileVaultRepository.open(root: folder)
        #expect(try await reopened.expireTrash(now: start.addingTimeInterval(15 * 86400)).count == 1)
        #expect(try await reopened.trashItems().count == 1)
        #expect(FileManager.default.fileExists(atPath: damaged.path))
        #expect(try Data(contentsOf: external) == bytes)
    }
}
