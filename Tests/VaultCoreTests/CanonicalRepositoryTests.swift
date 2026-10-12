import Foundation
import Testing
@testable import VaultCore

struct CanonicalRepositoryTests {
    func fixture() async throws -> (URL, FileVaultRepository) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("noema-canonical-repo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await FileVaultRepository.initializeCanonicalStaging(root: root)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        return (root, repository)
    }

    @Test func canonicalSourceMetadataAndLifecycleNeverConsultJSON() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await repository.importSource(data: Data("Original".utf8), filename: "source.txt", title: "Source", originURL: nil)
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        // Obsolete preservation bytes cannot override canonical metadata.
        var forged = source.metadata; forged.title = "Forged"
        let forgedBytes = try JSONEncoder().encode(forged)
        try forgedBytes.write(to: root.appendingPathComponent(path))
        #expect(try await repository.loadSource(id: source.id).title == "Source")
        let renamed = try await repository.renameSource(source, title: "Renamed")
        #expect(renamed.title == "Renamed")
        await #expect(throws: VaultError.self) { _ = try await repository.renameSource(source, title: "Stale") }
        let note = try await repository.create(title: "Page", body: "Body", source: renamed)
        #expect(note.linkedSourceIDs == [source.id])
        try await repository.deleteSource(renamed)
        #expect(try await repository.scanSources().sources.isEmpty)
        let removed = try #require(try await repository.trashItems().first)
        try await repository.restore(removed)
        #expect(try await repository.loadSource(id: source.id).title == "Renamed")
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == forgedBytes)
    }

    @Test func canonicalTrashPurgeLeavesTombstoneAndOriginal() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await repository.importSource(data: Data("Preserve bytes".utf8), filename: "x.txt", title: "Source", originURL: nil)
        try await repository.deleteSource(source)
        let removed = try #require(try await repository.trashItems().first)
        try await repository.permanentlyDelete(removed)
        #expect(try await repository.trashItems().isEmpty)
        #expect(try await repository.sqliteBlockStore.tombstone(id: source.id, kind: .source) != nil)
        #expect(try FileVaultRepository.readSourceOriginal(source, root: root, contentStore: repository.contentStore) == Data("Preserve bytes".utf8))
    }

    @Test func mismatchedManifestCannotAdmitCanonicalDatabase() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await repository.shutdownPageStorage()
        var manifest = try FileVaultRepository.inspectManifest(at: root)
        manifest.id = UUID()
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("vault.json"))
        let manager = VaultSessionManager()
        await #expect(throws: VaultSessionError.self) { _ = try await manager.openRepository(root: root) }
    }
}
