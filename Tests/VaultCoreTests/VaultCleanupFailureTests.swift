import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class CleanupFailureStore: VaultContentStore {
    struct State {
        var recoveryDirectoryToProtect: URL?
        var failStagingDeletion = false
    }
    let base: PlaintextVaultContentStore
    let state = Mutex(State())

    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data { try base.read(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        try base.move(from: source, to: destination, expected: expected)
    }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        try base.write(data, at: path, condition: condition)
        if path.hasPrefix("Wiki/"), case .replace = condition,
           let directory = state.withLock({ $0.recoveryDirectoryToProtect }) {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws {
        if path.hasPrefix("Sources/.import-"), state.withLock({ $0.failStagingDeletion }) {
            throw VaultContentStoreError.io(
                domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                message: "Injected staging cleanup failure"
            )
        }
        try base.delete(at: path, expected: expected)
    }
}

struct VaultCleanupFailureTests {
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func committedSaveReportsRecoveryCleanupFailureAndAbortsLockWithoutLosingCommit() async throws {
        let root = try fixtureRoot()
        let directory = root.appendingPathComponent("Drafts")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let manager = VaultSessionManager()
        let (session, lease, repo) = try await manager.openRepository(root: root, create: true)
        let recovery = try RecoveryStore(directory: directory, sessionLease: lease, accessGate: manager.accessGate)
        let note = try await repo.create(title: "Committed", body: "Before")
        do {
            _ = try await manager.quiescenceCoordinator.performPageSave(
                note: note, title: note.title, body: "Durably saved", tags: [], repository: repo,
                recovery: recovery
            ) { context in
                #expect(context.isDraftPreserved)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            }
            Issue.record("Recovery cleanup failure must reach the save caller")
        } catch let error as VaultQuiescenceError {
            guard case .recoveryCleanupFailed(let id, let message) = error else {
                Issue.record("Unexpected quiescence error: \(error)")
                return
            }
            #expect(id == note.id && !message.isEmpty)
        }
        #expect(manager.quiescenceCoordinator.committedNotes[note.id]?.body == "Durably saved")
        #expect(try await repo.scan().notes.first?.body == "Durably saved")
        #expect(try await recovery.drafts().first?.body == "Durably saved")
        do {
            _ = try await manager.lockWithQuiescence(repository: repo, recovery: recovery)
            Issue.record("A recorded recovery cleanup failure must abort locking")
        } catch let error as VaultSessionError {
            guard case .lockAborted(_, let message) = error else {
                Issue.record("Unexpected session error: \(error)")
                return
            }
            #expect(message.contains("recovery draft could not be removed"))
        }
        #expect(await manager.state == .open(session))
        #expect(try await repo.scan().notes.first?.body == "Durably saved")
    }

    @Test func pendingDirectSaveCleanupFailureAbortsLockInsteadOfReportingSuccessfulPreservation() async throws {
        let root = try fixtureRoot()
        let directory = root.appendingPathComponent("Drafts")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = try CleanupFailureStore(root: root)
        let manager = VaultSessionManager()
        let (session, lease, repo) = try await manager.openRepository(
            root: root, create: true, storageProvider: VaultStorageProvider { _ in store }
        )
        let recovery = try RecoveryStore(directory: directory, sessionLease: lease, accessGate: manager.accessGate)
        let note = try await repo.create(title: "Pending", body: "Before")
        store.state.withLock { $0.recoveryDirectoryToProtect = directory }
        do {
            _ = try await manager.lockWithQuiescence(
                repository: repo, recovery: recovery,
                pendingState: VaultPendingEditorState(dirtyNote: .init(
                    note: note, title: note.title, body: "Pending committed body", tags: []
                ))
            )
            Issue.record("Post-save cleanup failure must abort the pending-state lock")
        } catch let error as VaultSessionError {
            guard case .lockAborted(_, let message) = error else {
                Issue.record("Unexpected session error: \(error)")
                return
            }
            #expect(message.contains("recovery draft could not be removed"))
        }
        #expect(await manager.state == .open(session))
        #expect(manager.quiescenceCoordinator.committedNotes[note.id]?.body == "Pending committed body")
        #expect(try await repo.scan().notes.first?.body == "Pending committed body")
        #expect(try await recovery.drafts().first?.body == "Pending committed body")
    }

    @Test func cancelledImportReportsCleanupFailureAndRetainsStagedContent() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CleanupFailureStore(root: root)
        let manager = VaultSessionManager()
        let (session, _, repo) = try await manager.openRepository(
            root: root, create: true, storageProvider: VaultStorageProvider { _ in store }
        )
        let sourceID = UUID()
        let staging = "Sources/.import-\(sourceID.uuidString)"
        let bytes = Data("Recoverable interrupted import".utf8)
        store.state.withLock { $0.failStagingDeletion = true }
        do {
            _ = try await manager.quiescenceCoordinator.performSourceImport(
                sourceID: sourceID, repository: repo
            ) { context in
                try repo.contentStore.createDirectory(at: staging)
                try repo.contentStore.write(bytes, at: staging + "/original.txt", condition: .createOnly)
                context.requestPreCommitCancellation()
                try context.checkPreCommitCancellation()
                return (bytes, "original.txt", "Cancelled", nil, false)
            }
            Issue.record("Both source import and cleanup failures must reach the caller")
        } catch let error as VaultQuiescenceError {
            guard case .sourceImportCleanupFailed(let id, let operationMessage, let cleanupMessage) = error else {
                Issue.record("Unexpected quiescence error: \(error)")
                return
            }
            #expect(id == sourceID)
            #expect(operationMessage.contains("cancel"))
            #expect(cleanupMessage.contains("Injected staging cleanup failure"))
        }
        #expect(try store.base.snapshot(at: staging) == .directory(["original.txt": bytes]))
        #expect(try await repo.scan().sources.isEmpty)
        // Remove the injector: the recorded error must still reach lock rather than silently succeeding.
        store.state.withLock { $0.failStagingDeletion = false }
        do {
            _ = try await manager.lockWithQuiescence(repository: repo, recovery: nil)
            Issue.record("A recorded import cleanup failure must abort locking")
        } catch let error as VaultSessionError {
            guard case .lockAborted(_, let message) = error else {
                Issue.record("Unexpected session error: \(error)")
                return
            }
            #expect(message.contains("cancel"))
            #expect(message.contains("Injected staging cleanup failure"))
        }
        #expect(await manager.state == .open(session))
        #expect(try store.base.read(at: staging + "/original.txt") == bytes)
    }

    @Test(arguments: [false, true])
    func failedImportPreservesStagingAcrossLockRetryAndReopen(publicationFailure: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = VaultSessionManager()
        let (_, _, repo) = try await manager.openRepository(root: root, create: true)
        let sourceID = UUID()
        let staging = "Sources/.import-\(sourceID.uuidString)"
        let bytes = Data("Only captured import copy".utf8)
        if publicationFailure {
            try repo.contentStore.createDirectory(at: "Sources/" + sourceID.uuidString.lowercased())
        }
        await #expect(throws: (any Error).self) {
            _ = try await manager.quiescenceCoordinator.performSourceImport(sourceID: sourceID, repository: repo) { _ in
                if !publicationFailure {
                    try repo.contentStore.createDirectory(at: staging)
                    try repo.contentStore.write(bytes, at: staging + "/original.txt", condition: .createOnly)
                    throw VaultError.storage("Injected preparation failure")
                }
                return (bytes, "original.txt", "Captured", nil, true)
            }
        }
        #expect(try repo.contentStore.read(at: staging + "/original.txt") == bytes)
        await #expect(throws: VaultSessionError.self) {
            _ = try await manager.lockWithQuiescence(repository: repo, recovery: nil,
                pendingState: VaultPendingEditorState(activeDownloadSourceIDs: [sourceID]))
        }
        #expect(await manager.state.phase == .open)
        #expect(try repo.contentStore.read(at: staging + "/original.txt") == bytes)
        _ = try await manager.lockWithQuiescence(repository: repo, recovery: nil,
                pendingState: VaultPendingEditorState(activeDownloadSourceIDs: [sourceID]))
        let (_, _, reopened) = try await manager.unlockRepository(root: root)
        #expect(try reopened.contentStore.read(at: staging + "/original.txt") == bytes)
    }
}
