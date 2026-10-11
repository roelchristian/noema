import Foundation
import Synchronization
import Testing
@testable import VaultCore

struct StorageProviderTests {
    @Test func selectedStoreIsSharedByRepositoryAndConsumers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let selections = Mutex(0)
        let provider = VaultStorageProvider { selected in
            #expect(selected == root)
            selections.withLock { $0 += 1 }
            return store
        }
        let repository = try FileVaultRepository.open(root: root, create: true, storageProvider: provider)
        let page = try await repository.create(title: "Shared", body: "Body")
        let bytes = Data([0, 1, 2, 255])
        let source = try await repository.importSource(data: bytes, filename: "test.bin", title: "Original", originURL: nil)
        store.state.withLock { $0.operations.removeAll() }
        #expect(FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repository.contentStore) == "Available")
        let data = try FileVaultRepository.readSourceOriginal(source, root: root, contentStore: repository.contentStore)
        let preview = try SourcePreviewSnapshot(data: data, filename: source.metadata.storedFilename)
        defer { preview.remove() }
        #expect(try Data(contentsOf: preview.url) == bytes)
        #expect(!preview.url.path.hasPrefix(root.path + "/"))
        let path = "Sources/" + source.id.uuidString.lowercased() + "/original.bin"
        #expect(store.state.withLock { $0.operations.filter { $0 == "read " + path }.count } == 2)
        _ = try await repository.save(note: page, title: "Shared", body: "Changed", tags: [])
        #expect(store.state.withLock { $0.operations.contains("write " + page.relativePath) })
        #expect(selections.withLock { $0 } == 1)
        preview.remove()
        #expect(!FileManager.default.fileExists(atPath: preview.url.path))
    }

    @Test func creationSelectsStagingAndPublishedRootsIndependently() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let stores = Mutex([(URL, SourceStoreProbe)]())
        let provider = VaultStorageProvider { root in
            let store = try SourceStoreProbe(root: root)
            stores.withLock { $0.append((root, store)) }
            return store
        }
        let root = try FileVaultRepository.createNewVault(parent: parent, name: "New", encryptionRequested: false, storageProvider: provider)
        let repo = try FileVaultRepository.open(root: root, storageProvider: provider)
        let selected = stores.withLock { $0 }
        #expect(selected.count == 2)
        #expect(selected[0].0.lastPathComponent.hasPrefix(".noema-create-"))
        #expect(selected[1].0 == root)
        #expect(selected[0].1.state.withLock { $0.operations.contains("write vault.json") })
        #expect(selected[1].1.state.withLock { $0.operations.contains("read vault.json") })
        #expect(repo.manifest.formatVersion == 1)
        #expect(try await repo.scan().notes.isEmpty)
    }
}
