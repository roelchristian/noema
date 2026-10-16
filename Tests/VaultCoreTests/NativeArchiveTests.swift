import Foundation
import Synchronization
import SQLite3
import Testing
@testable import VaultCore

private func nativeArchiveParent() throws -> URL {
    let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/NativeArchiveTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return parent
}

private struct ArchiveHookStore: VaultContentStore {
    let base: any VaultContentStore
    let afterRead: @Sendable (String) -> Void
    let afterWrite: @Sendable (String) -> Void
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data {
        let bytes = try base.read(at: path); afterRead(path); return bytes
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        try base.write(data, at: path, condition: condition); afterWrite(path)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        try base.move(from: source, to: destination, expected: expected)
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

struct NativeArchiveTests {
    @Test func committedArchiveRoundTripIncludesOriginalsAndExcludesUnsavedDrafts() async throws {
        let parent = try nativeArchiveParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        let original = Data("Immutable original".utf8)
        let source = try await repository.importSource(data: original, filename: "original.txt", title: "Source", originURL: nil)
        let page = try await repository.create(title: "Page", body: "Committed body", source: source)
        let organisation = repository.sqliteBlockStore
        let collection = try await organisation.createContainer(kind: .collection, name: "Reading", parentID: nil,
            expectedVaultRevision: organisation.canonicalVaultRevision(), operationID: UUID())
        let pageReference = OrganisationItemReference(kind: .page, itemID: page.id)
        let sourceReference = OrganisationItemReference(kind: .source, itemID: source.id)
        _ = try await organisation.addMembership(containerID: collection.value.id, reference: sourceReference,
            expectedVaultRevision: organisation.canonicalVaultRevision(), operationID: UUID())
        _ = try await organisation.setFavourite(pageReference, favourite: true,
            expectedVaultRevision: organisation.canonicalVaultRevision(), operationID: UUID())
        let organisationBefore = try await organisation.organisationSnapshot(includingHidden: true)
        let drafts = parent.appendingPathComponent("Drafts")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: false)
        let draftBytes = Data("Unsaved preservation data".utf8)
        try draftBytes.write(to: drafts.appendingPathComponent("draft.json"))
        let archive = parent.appendingPathComponent("Archive")
        let index = try await repository.archive(to: archive)
        #expect(!index.recoveryDraftsIncluded)
        #expect(!index.files.keys.contains { $0.hasPrefix("Drafts/") })
        let destination = parent.appendingPathComponent("Restored")
        let session = VaultSession(vaultID: repository.manifest.id, root: destination, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        #expect(try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored", sessionLease: session.lease, accessGate: gate).path == destination.path)
        let restoredManager = VaultSessionManager()
        let (_, _, restored) = try await restoredManager.openRepository(root: destination)
        #expect(restored.manifest.storage?.schemaVersion == SQLiteBlockStore.templateSchemaVersion)
        #expect(try await restored.sqliteBlockStore.organisationSnapshot(includingHidden: true) == organisationBefore)
        #expect(try await restored.scan().notes.contains { $0.id == page.id && $0.body.contains("Committed body") })
        let sourcePath = "Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)"
        #expect(try Data(contentsOf: destination.appendingPathComponent(sourcePath)) == original)
        #expect(try Data(contentsOf: drafts.appendingPathComponent("draft.json")) == draftBytes)
        await #expect(throws: (any Error).self) {
            try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored", sessionLease: session.lease, accessGate: gate)
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent(sourcePath)) == original)
        try await restored.sqliteBlockStore.close(); try await restoredManager.close()
        try await repository.sqliteBlockStore.close(); try await manager.close()
    }

    @Test(arguments: [3, 4, 5])
    func restoreRejectsHistoricalAuthorityBeforeWriting(schemaVersion: Int) async throws {
        let parent = try nativeArchiveParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let archive = parent.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        var manifest = VaultManifest()
        var declaration = VaultCanonicalStorageDeclaration()
        declaration.schemaVersion = schemaVersion
        declaration.requiredCapabilities = schemaVersion == 3 ? ["canonicalMetadataV1"]
            : schemaVersion == 4 ? SQLiteBlockStore.knowledgeRequiredCapabilities : SQLiteBlockStore.semanticRequiredCapabilities
        manifest.storage = declaration
        let databaseURL = archive.appendingPathComponent(VaultManifest.sqliteDatabasePath)
        let database = try SQLiteBlockStore(canonicalStagingURL: databaseURL, vaultID: manifest.id,
            requiredCapabilities: declaration.requiredCapabilities, schemaVersion: schemaVersion)
        try await database.checkpoint()
        try await database.close()
        let manifestBytes = try JSONEncoder().encode(manifest)
        try manifestBytes.write(to: archive.appendingPathComponent("vault.json"))
        let databaseBytes = try Data(contentsOf: databaseURL)
        let files = ["vault.json": manifestBytes, VaultManifest.sqliteDatabasePath: databaseBytes]
        let index = NativeVaultArchive.Index(version: 1, vaultID: manifest.id, capturedAt: Date(),
            recoveryDraftsIncluded: false, externalSourceIDs: [],
            files: files.mapValues { .init(size: $0.count, sha256: digest($0)) })
        let indexBytes = try JSONEncoder().encode(index)
        try indexBytes.write(to: archive.appendingPathComponent(NativeVaultArchive.indexPath))
        let entriesBefore = try FileManager.default.contentsOfDirectory(atPath: archive.path)
        let destination = parent.appendingPathComponent("Restored")
        let session = VaultSession(vaultID: manifest.id, root: destination, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        await #expect(throws: VaultError.self) {
            try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored",
                sessionLease: session.lease, accessGate: gate)
        }
        #expect(throws: VaultError.self) { try FileVaultRepository.inspectManifest(at: archive) }
        #expect(throws: VaultError.self) {
            try VaultStorageProvider.plaintext.makeDeclaredStagingStore(url: databaseURL,
                vaultID: manifest.id, declaration: declaration)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["Archive"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: archive.path)) == Set(entriesBefore))
        for (path, bytes) in files { #expect(try Data(contentsOf: archive.appendingPathComponent(path)) == bytes) }
        #expect(try Data(contentsOf: archive.appendingPathComponent(NativeVaultArchive.indexPath)) == indexBytes)
    }

    @Test(arguments: [false, true])
    func archiveRejectsCorruptOrOmittedOriginal(omitted: Bool) async throws {
        let parent = try nativeArchiveParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        let source = try await repository.importSource(data: Data("Original".utf8), filename: "original.txt", title: "Source", originURL: nil)
        let archive = parent.appendingPathComponent("Archive")
        let index = try await repository.archive(to: archive)
        let path = "Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)"
        if omitted {
            let altered = NativeVaultArchive.Index(version: index.version, vaultID: index.vaultID, capturedAt: index.capturedAt,
                recoveryDraftsIncluded: false, externalSourceIDs: index.externalSourceIDs,
                files: index.files.filter { $0.key != path })
            try JSONEncoder().encode(altered).write(to: archive.appendingPathComponent(NativeVaultArchive.indexPath))
        } else { try Data("Corrupt".utf8).write(to: archive.appendingPathComponent(path)) }
        let destination = parent.appendingPathComponent("Restored")
        let session = VaultSession(vaultID: repository.manifest.id, root: destination, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        await #expect(throws: (any Error).self) {
            try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored", sessionLease: session.lease, accessGate: gate)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".noema-restore-") })
        try await repository.sqliteBlockStore.close(); try await manager.close()
    }

    @Test func captureStopsCopyingWhenOriginalLeaseIsRevokedAfterBackup() async throws {
        let parent = try nativeArchiveParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        _ = try await repository.create(title: "Page", body: "Committed")
        let archive = parent.appendingPathComponent("Archive")
        let writes = Mutex<[String]>([])
        let gate = manager.accessGate
        let provider = VaultStorageProvider { selectedRoot in
            let base = try VaultStorageProvider.plaintext.makeStore(root: selectedRoot)
            guard selectedRoot == archive else { return base }
            return ArchiveHookStore(base: base, afterRead: { _ in }, afterWrite: { path in
                writes.withLock { $0.append(path) }; gate.updateState(.closed)
            })
        }
        await #expect(throws: VaultAccessError.self) { try await repository.archive(to: archive, storageProvider: provider) }
        #expect(writes.withLock { $0.count } == 1)
        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("blocks.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: archive.appendingPathComponent(NativeVaultArchive.indexPath).path))
        try await repository.sqliteBlockStore.close()
    }

    @Test func restoreStopsBeforeMutationWhenLeaseRevokedAfterInputRead() async throws {
        let parent = try nativeArchiveParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        let archive = parent.appendingPathComponent("Archive")
        _ = try await repository.archive(to: archive)
        let destination = parent.appendingPathComponent("Restored")
        let session = VaultSession(vaultID: repository.manifest.id, root: destination, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let provider = VaultStorageProvider { selectedRoot in
            let base = try VaultStorageProvider.plaintext.makeStore(root: selectedRoot)
            guard selectedRoot == archive else { return base }
            return ArchiveHookStore(base: base, afterRead: { _ in gate.updateState(.closed) }, afterWrite: { _ in })
        }
        await #expect(throws: VaultAccessError.self) {
            try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored", sessionLease: session.lease, accessGate: gate, storageProvider: provider)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!((try FileManager.default.contentsOfDirectory(atPath: parent.path)).contains { $0.hasPrefix(".noema-restore-") }))
        try await repository.sqliteBlockStore.close(); try await manager.close()
    }
    @Test(arguments: [false, true])
    func captureRevocationDuringStagingValidationOrIndexPublication(publishing: Bool) async throws {
        let parent = try nativeArchiveParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        let original = Data("Retained original".utf8)
        let source = try await repository.importSource(data: original, filename: "original.txt", title: "Source", originURL: nil)
        let originalPath = "Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)"
        let archive = parent.appendingPathComponent("Archive")
        let gate = manager.accessGate
        let provider = VaultStorageProvider { selectedRoot in
            let base = try VaultStorageProvider.plaintext.makeStore(root: selectedRoot)
            guard selectedRoot == archive else { return base }
            return ArchiveHookStore(base: base, afterRead: { path in
                if path == (publishing ? VaultManifest.sqliteDatabasePath : originalPath) { gate.updateState(.closed) }
            }, afterWrite: { _ in })
        }
        await #expect(throws: VaultAccessError.self) { try await repository.archive(to: archive, storageProvider: provider) }
        #expect(!FileManager.default.fileExists(atPath: archive.appendingPathComponent(NativeVaultArchive.indexPath).path))
        #expect(try Data(contentsOf: archive.appendingPathComponent(originalPath)) == original)
        #expect(try Data(contentsOf: root.appendingPathComponent(originalPath)) == original)
        try await repository.sqliteBlockStore.close()
    }

    @Test func optionalKnowledgeRegistrySurvivesNativeArchiveAndRestore() async throws {
        let parent = try nativeArchiveParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
        // There is no registry mutation API yet. A supported future descriptor is
        // a fixture insert; admission must preserve it through native archives.
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("blocks.sqlite").path, &database) == SQLITE_OK)
        let db = try #require(database)
        let sql = "INSERT INTO knowledge_entity_types VALUES('organization',1,'{\"key\":\"organization\",\"version\":1,\"metadata\":{\"version\":1,\"requiredFeatures\":[],\"properties\":{\"optional\":\"retained\"}}}')"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        let archive = parent.appendingPathComponent("Archive")
        _ = try await repository.archive(to: archive)
        let destination = parent.appendingPathComponent("Restored")
        let session = VaultSession(vaultID: repository.manifest.id, root: destination, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        _ = try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored", sessionLease: session.lease, accessGate: gate)
        let restoredManager = VaultSessionManager()
        let (_, _, restored) = try await restoredManager.openRepository(root: destination)
        try await restored.sqliteBlockStore.validateCanonicalLogicalIntegrity()
        var restoredDatabase: OpaquePointer?
        #expect(sqlite3_open(destination.appendingPathComponent("blocks.sqlite").path, &restoredDatabase) == SQLITE_OK)
        let restoredDB = try #require(restoredDatabase)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(restoredDB, "SELECT descriptor FROM knowledge_entity_types WHERE key='organization'", -1, &statement, nil) == SQLITE_OK)
        let query = try #require(statement)
        #expect(sqlite3_step(query) == SQLITE_ROW)
        let descriptor = String(cString: try #require(sqlite3_column_text(query, 0)))
        #expect(descriptor.contains("retained"))
        sqlite3_finalize(query); sqlite3_close(restoredDB)
        try await restored.sqliteBlockStore.close(); try await restoredManager.close()
        try await repository.sqliteBlockStore.close(); try await manager.close()
    }

}
