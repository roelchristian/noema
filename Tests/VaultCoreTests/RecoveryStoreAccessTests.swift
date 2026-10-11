import Foundation
import Testing
@testable import VaultCore

struct RecoveryStoreAccessTests {
    @Test func constructionRejectsMissingExpiredAndWrongVaultLeasesBeforeCreatingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-access-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = VaultSessionManager()
        let session = try await manager.open(root: directory.appendingPathComponent("Vault")) { _ in UUID() }
        let gate = manager.accessGate
        #expect(throws: VaultAccessError.missingLease(operation: "recoveryStore.open")) {
            _ = try RecoveryStore(directory: directory, sessionLease: nil, accessGate: gate)
        }
        let wrong = VaultSessionLease(sessionID: session.id, vaultID: UUID(), root: session.root, generation: session.generation)
        #expect(throws: VaultAccessError.wrongVault(
            expectedVaultID: wrong.vaultID, expectedRoot: wrong.root,
            actualVaultID: session.vaultID, actualRoot: session.root, operation: "recoveryStore.open"
        )) {
            _ = try RecoveryStore(directory: directory, sessionLease: wrong, accessGate: gate)
        }
        try await manager.lock()
        _ = try await manager.unlock { _ in session.vaultID }
        #expect(throws: VaultAccessError.staleLease(leaseGeneration: 1, activeGeneration: 2, operation: "recoveryStore.open")) {
            _ = try RecoveryStore(directory: directory, sessionLease: session.lease, accessGate: gate)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func retainedRecoveryReadsWritesAndDeletesRejectRevokedAndWrongVaultSessionsWithoutChangingDraftBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-revocation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = VaultSessionManager()
        let (session, lease, repo) = try await manager.openRepository(root: root, create: true)
        let note = try await repo.create(title: "Recovery", body: "Canonical body")
        let draft = DraftRecord(note: note, title: note.title, body: "Only unsaved copy", tags: [])
        let directory = root.appendingPathComponent("Drafts")
        let recovery = try RecoveryStore(directory: directory, sessionLease: lease, accessGate: manager.accessGate)
        try await recovery.store(draft)
        let file = directory.appendingPathComponent(draft.id.uuidString + ".json")
        let original = try Data(contentsOf: file)

        try await manager.lock()
        await #expect(throws: VaultAccessError.self) { _ = try await recovery.drafts() }
        await #expect(throws: VaultAccessError.self) { try await recovery.store(draft) }
        await #expect(throws: VaultAccessError.self) { try await recovery.remove(draft.id) }

        _ = try await manager.unlock()
        await #expect(throws: VaultAccessError.staleLease(leaseGeneration: 1, activeGeneration: 2, operation: "recoveryStore.drafts")) {
            _ = try await recovery.drafts()
        }
        await #expect(throws: VaultAccessError.self) { try await recovery.store(draft) }
        await #expect(throws: VaultAccessError.self) { try await recovery.remove(draft.id) }

        // Same generation with another vault isolates identity validation from stale-generation checks.
        manager.accessGate.updateState(.open(VaultSession(vaultID: UUID(), root: root.appendingPathComponent("Other"), generation: session.generation)))
        await #expect(throws: VaultAccessError.self) { _ = try await recovery.drafts() }
        await #expect(throws: VaultAccessError.self) { try await recovery.store(draft) }
        await #expect(throws: VaultAccessError.self) { try await recovery.remove(draft.id) }
        #expect(try Data(contentsOf: file) == original)
    }
}
