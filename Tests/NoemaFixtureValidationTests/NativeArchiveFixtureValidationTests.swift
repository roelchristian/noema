import Foundation
import Testing
import VaultCore

struct NativeArchiveFixtureValidationTests {
    @Test func canonicalArchiveRestoresAndRejectsCorruptionOrOverwrite() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("noema-archive-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try await FileVaultRepository.initializeCanonicalStaging(root: root)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        let source = try await repository.importSource(data: Data("Immutable original".utf8), filename: "source.txt", title: "Source", originURL: nil)
        let page = try await repository.create(title: "Page", body: "Canonical body", source: source)
        let archive = parent.appendingPathComponent("Archive")
        let index = try await repository.archive(to: archive)
        #expect(index.version == 1 && !index.recoveryDraftsIncluded)
        let target = parent.appendingPathComponent("Restored")
        let session = VaultSession(vaultID: repository.manifest.id, root: target, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        _ = try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored", sessionLease: session.lease, accessGate: gate)
        let restoredManager = VaultSessionManager()
        let (_, _, restored) = try await restoredManager.openRepository(root: target)
        #expect(try await restored.scan().notes.contains { $0.id == page.id })
        await #expect(throws: (any Error).self) {
            _ = try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Restored", sessionLease: session.lease, accessGate: gate)
        }
        let sourcePath = "Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename
        try Data("Corrupted".utf8).write(to: archive.appendingPathComponent(sourcePath))
        let badTarget = parent.appendingPathComponent("Corrupted")
        let badSession = VaultSession(vaultID: repository.manifest.id, root: badTarget, generation: 2)
        let badGate = VaultAccessGate(initialState: .open(badSession))
        await #expect(throws: (any Error).self) {
            _ = try await NativeVaultArchive.restore(from: archive, parent: parent, name: "Corrupted", sessionLease: badSession.lease, accessGate: badGate)
        }
        #expect(!FileManager.default.fileExists(atPath: badTarget.path))
    }
}
