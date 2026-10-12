import Foundation
import Testing
@testable import VaultCore

struct TrashAdapterTests {
    @Test func canonicalTrashRestoreAndPermanentDeletionPreserveIdentityAndRejectStaleRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-trash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await canonicalSchema5TestRepository(root: root, create: true)
        let note = try await repo.create(title: "Recoverable", body: "Preserved body")
        let saved = try await repo.save(note: note, title: note.title, body: "Current body", tags: [])
        await #expect(throws: (any Error).self) { try await repo.trash(note: note) }
        try await repo.trash(note: saved)
        #expect(try await repo.scan().notes.isEmpty)
        let item = try #require(try await repo.trashItems().first)
        let reopened = try await canonicalSchema5TestRepository(root: root)
        #expect(try await reopened.trashItems().count == 1)
        try await reopened.restore(item)
        let restored = try #require(try await reopened.scan().notes.first)
        #expect(restored.id == note.id && restored.body == saved.body)
        await #expect(throws: (any Error).self) { try await reopened.restore(item) }
        try await reopened.trash(note: restored)
        try await reopened.permanentlyDelete(#require(try await reopened.trashItems().first))
        #expect(try await reopened.trashItems().isEmpty)
    }
}
