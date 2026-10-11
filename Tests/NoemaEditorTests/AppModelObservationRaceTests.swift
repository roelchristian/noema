import Foundation
import Testing
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct AppModelObservationRaceTests {
    private func temporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-observation-race-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @MainActor
    private func delayedModel(repository: FileVaultRepository, note: NoteRecord, manager: VaultSessionManager, localStorageRoot: URL) -> AppModel {
        // Restore the resources still held by a MainActor consumer that has not yet processed
        // the intermediate revocation emissions. No suspension occurs before manual delivery.
        let model = AppModel(repository: repository, sessionManager: manager)
        model.localStorageRoot = localStorageRoot
        model.persistSecurityScopedBookmark = false
        model.root = repository.root
        model.notes = [note]
        model.currentNote = note
        model.title = note.title
        model.body = note.body
        model.searchText = note.title
        return model
    }

    @Test @MainActor
    func rapidDirectLockUnlockPurgesOldResourcesWhenIntermediateObservationsAreStale() async throws {
        let base = try temporaryDirectory()
        defer {
            SourceReader.closeAll()
            try? FileManager.default.removeItem(at: base)
        }
        let manager = VaultSessionManager()
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (oldSession, _, oldRepository) = try await manager.openRepository(root: root, create: true)
        let note = try await oldRepository.create(title: "Retained page", body: "Canonical content survives lock and unlock")
        try await manager.lock()
        let oldLocked = await manager.state
        let newSession = try await manager.unlock()
        #expect(newSession.generation > oldSession.generation)

        let model = delayedModel(repository: oldRepository, note: note, manager: manager, localStorageRoot: base)
        model.applyObservedSessionState(.open(oldSession))
        model.applyObservedSessionState(oldLocked)
        #expect(model.root == oldSession.root && model.notes.map(\.id) == [note.id])
        model.applyObservedSessionState(.open(newSession))
        #expect(model.sessionPhase == .open && !model.isLocked)
        #expect(!model.isVaultAvailable && model.root == nil && model.index == nil)
        #expect(model.notes.isEmpty && model.currentNote == nil && model.body.isEmpty && model.searchText.isEmpty)
        await #expect(throws: VaultAccessError.self) { _ = try await oldRepository.scan() }

        await model.open(root, create: false)
        #expect(model.isVaultAvailable && model.notes.map(\.id) == [note.id])
        #expect(model.notes.first?.body == note.body)
        #expect(await model.closeVault(force: true))
    }

    @Test @MainActor
    func rapidDirectCloseOpenDifferentVaultPurgesOldResourcesBeforePublishingNewSession() async throws {
        let base = try temporaryDirectory()
        defer {
            SourceReader.closeAll()
            try? FileManager.default.removeItem(at: base)
        }
        let manager = VaultSessionManager()
        let rootA = base.appendingPathComponent("Vault A")
        let rootB = base.appendingPathComponent("Vault B")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let (sessionA, _, repositoryA) = try await manager.openRepository(root: rootA, create: true)
        let noteA = try await repositoryA.create(title: "Private A", body: "A content must not appear in B")
        try await manager.close()
        let (sessionB, _, repositoryB) = try await manager.openRepository(root: rootB, create: true)
        let noteB = try await repositoryB.create(title: "Private B", body: "B canonical content")

        let model = delayedModel(repository: repositoryA, note: noteA, manager: manager, localStorageRoot: base)
        model.applyObservedSessionState(.open(sessionA))
        model.applyObservedSessionState(.closed)
        #expect(model.root == sessionA.root && model.notes.map(\.id) == [noteA.id])
        model.applyObservedSessionState(.open(sessionB))
        #expect(model.sessionState == .open(sessionB) && model.vaultName == "Vault B")
        #expect(!model.isVaultAvailable && !model.isLocked && model.root == nil && model.index == nil)
        #expect(model.notes.isEmpty && model.currentNote == nil && model.body.isEmpty && model.searchText.isEmpty)
        await #expect(throws: VaultAccessError.self) { _ = try await repositoryA.scan() }

        await model.open(rootB, create: false)
        #expect(model.isVaultAvailable && model.notes.map(\.id) == [noteB.id])
        #expect(model.notes.first?.body == noteB.body)
        #expect(!model.notes.contains { $0.id == noteA.id || $0.body == noteA.body })
        #expect(await model.closeVault(force: true))
    }
}
}
