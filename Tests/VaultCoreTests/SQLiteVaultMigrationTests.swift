import Foundation
import Testing
@testable import VaultCore

private func migrationFixture() throws -> (URL, Data, NoteRecord) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-migration-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let normalized = root.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: normalized.appendingPathComponent("Wiki"), withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: normalized.appendingPathComponent("Sources"), withIntermediateDirectories: false)
    let manifest = VaultManifest()
    try JSONEncoder().encode(manifest).write(to: normalized.appendingPathComponent("vault.json"))
    var metadata = BlockMetadata(); metadata.extra["future"] = "preserve"; metadata.semantic = "idea"
    var style = InlineStyle(); style.highlight = true; style.wikiTarget = "Target"
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("Rich text", style: style)], metadata: metadata)])
    let text = "---\nid: \(UUID().uuidString)\ntitle: Original\naliases: [Alias]\ntags: [tag]\ncreated_at: 2026-01-01\nupdated_at: 2026-01-02\nsources: [\(UUID().uuidString)]\nfuture_header: retained\n---\n" + BlockDocumentCodec.encode(document)
    let bytes = Data(text.utf8)
    try bytes.write(to: normalized.appendingPathComponent("Wiki/Original.md"))
    let note = try NoteCodec.decode(bytes, path: "Wiki/Original.md", vaultID: manifest.id)
    return (normalized, bytes, note)
}

@Test func sqliteMigrationPreservesOriginalsAndVerifiesBackup() async throws {
    let (root, bytes, note) = try migrationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceBytes = Data("source original".utf8)
    try sourceBytes.write(to: root.appendingPathComponent("Sources/original.txt"))
    let first = try await SQLiteVaultMigration.convert(unguardedTestingRoot: root)
    #expect(first.manifest.formatVersion == 2)
    #expect(first.manifest.storageMode == .sqliteBlocks)
    #expect(first.importedPageCount == 1)
    #expect(try Data(contentsOf: root.appendingPathComponent("Wiki/Original.md")) == bytes)
    let backup = try #require(first.backupPath)
    #expect(try Data(contentsOf: root.appendingPathComponent(backup + "/Wiki/Original.md")) == bytes)
    #expect(try Data(contentsOf: root.appendingPathComponent(backup + "/Sources/original.txt")) == sourceBytes)
    let database = try SQLiteBlockStore(unguardedTestingURL: root.appendingPathComponent(VaultManifest.sqliteDatabasePath))
    let restored = try await database.loadPage(pageID: note.id)
    var expected = note
    expected.body = restored.record.body; expected.contentHash = restored.record.contentHash
    #expect(restored.record == expected)
    #expect(restored.snapshot.document == BlockDocumentCodec.decode(note.body))
    try await database.close()
    let repeated = try await SQLiteVaultMigration.convert(unguardedTestingRoot: root)
    #expect(repeated.manifest.id == first.manifest.id)
    #expect(repeated.importedPageCount == 1)
    #expect(repeated.backupPath == nil)
}

@Test func sqliteMigrationRejectsFutureEnvelopeWithoutCutover() async throws {
    let (root, _, _) = try migrationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try Data(contentsOf: root.appendingPathComponent("vault.json"))
    let envelope = try JSONSerialization.data(withJSONObject: ["version": 99]).base64EncodedString()
    try Data("Content\n<!--noema:document:\(envelope)-->\n".utf8).write(to: root.appendingPathComponent("Wiki/Original.md"))
    await #expect(throws: (any Error).self) { try await SQLiteVaultMigration.convert(unguardedTestingRoot: root) }
    #expect(try Data(contentsOf: root.appendingPathComponent("vault.json")) == manifest)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("blocks.sqlite").path))
}

private struct FailingMigrationBackupStore: VaultContentStore {
    let base: any VaultContentStore
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data {
        if path.contains("/backup/") { return Data("corrupt verification".utf8) }
        return try base.read(at: path)
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws { try base.write(data, at: path, condition: condition) }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

@Test func sqliteMigrationFailedBackupVerificationPreservesMarkdownAuthority() async throws {
    let (root, bytes, _) = try migrationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try Data(contentsOf: root.appendingPathComponent("vault.json"))
    let provider = VaultStorageProvider { root in
        FailingMigrationBackupStore(base: try VaultStorageProvider.plaintext.makeStore(root: root))
    }
    await #expect(throws: (any Error).self) { try await SQLiteVaultMigration.convert(unguardedTestingRoot: root, storageProvider: provider) }
    #expect(try Data(contentsOf: root.appendingPathComponent("vault.json")) == manifest)
    #expect(try Data(contentsOf: root.appendingPathComponent("Wiki/Original.md")) == bytes)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("blocks.sqlite").path))
}

@Test func vaultManifestRequiresMatchingFormatAndStorageMode() throws {
    var manifest = VaultManifest()
    #expect(manifest.isSupported)
    manifest.formatVersion = 2
    #expect(!manifest.isSupported)
    manifest.storageMode = .sqliteBlocks
    #expect(manifest.isSupported)
    manifest.formatVersion = 1
    #expect(!manifest.isSupported)
    let old = Data("{\"formatVersion\":1,\"id\":\"\(UUID().uuidString)\"}".utf8)
    #expect(try JSONDecoder().decode(VaultManifest.self, from: old).storageMode == .markdown)
}

@Test(arguments: ["CloudStorage", "Mobile Documents", "Dropbox", "OneDrive - Personal", "Google Drive", "Box"])
func sqliteMigrationRejectsCloudNamedAncestor(provider: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-cloud-\(UUID())/\(provider)/vault")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
    await #expect(throws: (any Error).self) { try await SQLiteVaultMigration.convert(unguardedTestingRoot: root.resolvingSymlinksInPath()) }
}

enum MigrationPublicationFault: Sendable, Equatable {
    case manifestWrite, interruptedAfterDatabaseMove, originalChangedDuringMove
}

private struct PublicationFaultMigrationStore: VaultContentStore {
    let base: any VaultContentStore
    let fault: MigrationPublicationFault
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data { try base.read(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        if path == "vault.json", fault == .manifestWrite { throw VaultError.storage("Injected manifest publication failure") }
        try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        try base.move(from: source, to: destination, expected: expected)
        if destination == VaultManifest.sqliteDatabasePath {
            if fault == .interruptedAfterDatabaseMove { throw VaultError.storage("Injected interruption after database publication") }
            if fault == .originalChangedDuringMove {
                let original = try base.read(at: "Wiki/Original.md")
                let changed = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "title: Original", with: "title: Edited during publication").utf8)
                try base.write(changed, at: "Wiki/Original.md", condition: .replace(expected: original))
            }
        }
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

@Test(arguments: [MigrationPublicationFault.manifestWrite, .interruptedAfterDatabaseMove])
func sqliteMigrationFailedPublicationCanRetryWithoutModifyingOriginals(fault: MigrationPublicationFault) async throws {
    let (root, bytes, note) = try migrationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try Data(contentsOf: root.appendingPathComponent("vault.json"))
    let provider = VaultStorageProvider { root in
        PublicationFaultMigrationStore(base: try VaultStorageProvider.plaintext.makeStore(root: root), fault: fault)
    }
    await #expect(throws: (any Error).self) {
        try await SQLiteVaultMigration.convert(unguardedTestingRoot: root, storageProvider: provider)
    }
    #expect(try Data(contentsOf: root.appendingPathComponent("vault.json")) == manifest)
    #expect(try Data(contentsOf: root.appendingPathComponent("Wiki/Original.md")) == bytes)
    let interruptedDatabase = try Data(contentsOf: root.appendingPathComponent(VaultManifest.sqliteDatabasePath))
    let result = try await SQLiteVaultMigration.convert(unguardedTestingRoot: root)
    #expect(result.manifest.storageMode == .sqliteBlocks)
    #expect(result.importedPageCount == 1)
    #expect(try Data(contentsOf: root.appendingPathComponent("Wiki/Original.md")) == bytes)
    let runs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".noema-migrations"), includingPropertiesForKeys: nil)
    let preserved = try runs.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        .filter { $0.lastPathComponent.hasPrefix("interrupted-") }
    #expect(preserved.count == 1)
    #expect(try Data(contentsOf: #require(preserved.first)) == interruptedDatabase)
    let database = try SQLiteBlockStore(unguardedTestingURL: root.appendingPathComponent(VaultManifest.sqliteDatabasePath))
    #expect(try await database.loadPage(pageID: note.id).record.id == note.id)
    try await database.close()
}

@Test func sqliteMigrationOriginalChangedDuringPublicationPreventsCutoverAndRetryImportsLatest() async throws {
    let (root, _, note) = try migrationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = try Data(contentsOf: root.appendingPathComponent("vault.json"))
    let provider = VaultStorageProvider { root in
        PublicationFaultMigrationStore(base: try VaultStorageProvider.plaintext.makeStore(root: root), fault: .originalChangedDuringMove)
    }
    await #expect(throws: VaultContentStoreError.stale("Wiki/Original.md")) {
        try await SQLiteVaultMigration.convert(unguardedTestingRoot: root, storageProvider: provider)
    }
    #expect(try Data(contentsOf: root.appendingPathComponent("vault.json")) == manifest)
    let changed = try Data(contentsOf: root.appendingPathComponent("Wiki/Original.md"))
    #expect(String(decoding: changed, as: UTF8.self).contains("Edited during publication"))
    _ = try await SQLiteVaultMigration.convert(unguardedTestingRoot: root)
    #expect(try Data(contentsOf: root.appendingPathComponent("Wiki/Original.md")) == changed)
    let database = try SQLiteBlockStore(unguardedTestingURL: root.appendingPathComponent(VaultManifest.sqliteDatabasePath))
    #expect(try await database.loadPage(pageID: note.id).record.title == "Edited during publication")
    try await database.close()
}

@Test func sqliteMigrationRefusesUnownedOccupiedDatabase() async throws {
    let (root, bytes, _) = try migrationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let unrelated = Data("unrelated database preservation data".utf8)
    try unrelated.write(to: root.appendingPathComponent(VaultManifest.sqliteDatabasePath))
    let manifest = try Data(contentsOf: root.appendingPathComponent("vault.json"))
    await #expect(throws: VaultContentStoreError.alreadyExists(VaultManifest.sqliteDatabasePath)) {
        try await SQLiteVaultMigration.convert(unguardedTestingRoot: root)
    }
    #expect(try Data(contentsOf: root.appendingPathComponent(VaultManifest.sqliteDatabasePath)) == unrelated)
    #expect(try Data(contentsOf: root.appendingPathComponent("vault.json")) == manifest)
    #expect(try Data(contentsOf: root.appendingPathComponent("Wiki/Original.md")) == bytes)
}

@Test func sqliteMigrationRepeatRejectsSymlinkDatabaseAndMissingDatabaseWithoutCreation() async throws {
    let (root, _, _) = try migrationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await SQLiteVaultMigration.convert(unguardedTestingRoot: root)
    let database = root.appendingPathComponent(VaultManifest.sqliteDatabasePath)
    let retained = root.appendingPathComponent("retained.sqlite")
    try FileManager.default.moveItem(at: database, to: retained)
    await #expect(throws: VaultContentStoreError.missing(VaultManifest.sqliteDatabasePath)) {
        try await SQLiteVaultMigration.convert(unguardedTestingRoot: root)
    }
    #expect(!FileManager.default.fileExists(atPath: database.path))
    try FileManager.default.createSymbolicLink(at: database, withDestinationURL: retained)
    await #expect(throws: VaultContentStoreError.unsafePath(VaultManifest.sqliteDatabasePath)) {
        try await SQLiteVaultMigration.convert(unguardedTestingRoot: root)
    }
}

@Test func sqliteMigrationRejectsManifestIdentityChangedAfterAdmission() async throws {
    let (root, bytes, _) = try migrationFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = VaultSessionManager()
    let (_, lease, _) = try await manager.openRepository(root: root)
    let replacement = try JSONEncoder().encode(VaultManifest())
    try replacement.write(to: root.appendingPathComponent("vault.json"))
    await #expect(throws: VaultAccessError.self) {
        try await SQLiteVaultMigration.convert(root: root, sessionLease: lease, accessGate: manager.accessGate)
    }
    #expect(try Data(contentsOf: root.appendingPathComponent("vault.json")) == replacement)
    #expect(try Data(contentsOf: root.appendingPathComponent("Wiki/Original.md")) == bytes)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(VaultManifest.sqliteDatabasePath).path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".noema-migrations").path))
}
