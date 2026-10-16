import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class CreationStoreProbe: VaultContentStore {
    let base: PlaintextVaultContentStore
    let operations = Mutex([String]())
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func synchronize(at path: String) throws { try base.synchronize(at: path) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data {
        operations.withLock { $0.append("read " + path) }; return try base.read(at: path)
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        operations.withLock { $0.append("write " + path) }; try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        try base.move(from: source, to: destination, expected: expected)
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.publishCanonicalOriginal(data, metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalOriginal(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalLinked(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
}

struct StorageProviderTests {
    @Test func selectedStoreIsSharedByRepositoryAndConsumers() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
        let store = try CreationStoreProbe(root: root)
        let selections = Mutex(0)
        let provider = VaultStorageProvider { selected in
            #expect(selected == root); selections.withLock { $0 += 1 }; return store
        }
        let manifest = try FileVaultRepository.inspectManifest(at: root)
        let session = VaultSession(vaultID: manifest.id, root: root, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let repository = try FileVaultRepository.open(root: root, storageProvider: provider, sessionLease: session.lease, accessGate: gate)
        let page = try await repository.create(title: "Shared", body: "Body")
        let bytes = Data([0, 1, 2, 255])
        let source = try await repository.importSource(data: bytes, filename: "test.bin", title: "Original", originURL: nil)
        store.operations.withLock { $0.removeAll() }
        let data = try FileVaultRepository.readSourceOriginal(source, root: root, contentStore: repository.contentStore)
        #expect(data == bytes)
        let path = "Sources/" + source.id.uuidString.lowercased() + "/original.bin"
        #expect(store.operations.withLock { $0.contains("read " + path) })
        _ = try await repository.save(note: page, title: "Shared", body: "Changed", tags: [])
        #expect(store.operations.withLock { !$0.contains("write " + page.relativePath) })
        #expect(selections.withLock { $0 } == 1)
        try await repository.sqliteBlockStore.close()
    }

    @Test func creationSelectsStagingAndPublishedRootsIndependently() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let stores = Mutex([(URL, CreationStoreProbe)]())
        let provider = VaultStorageProvider { root in
            let store = try CreationStoreProbe(root: root); stores.withLock { $0.append((root, store)) }; return store
        }
        let root = try await FileVaultRepository.createNewVault(parent: parent, name: "New", encryptionRequested: false, storageProvider: provider)
        let manifest = try FileVaultRepository.inspectManifest(at: root)
        let session = VaultSession(vaultID: manifest.id, root: root, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let repo = try FileVaultRepository.open(root: root, storageProvider: provider, sessionLease: session.lease, accessGate: gate)
        let selected = stores.withLock { $0 }
        #expect(selected.count == 2)
        #expect(selected[0].0.lastPathComponent.hasPrefix(".noema-create-"))
        #expect(selected[1].0 == root)
        #expect(selected[0].1.operations.withLock { $0.contains("write vault.json") })
        #expect(selected[1].1.operations.withLock { $0.contains("read vault.json") })
        #expect(repo.manifest.storage?.schemaVersion == SQLiteBlockStore.associationSchemaVersion)
        #expect(try await repo.scan().notes.isEmpty)
        try await repo.sqliteBlockStore.close()
    }
}
