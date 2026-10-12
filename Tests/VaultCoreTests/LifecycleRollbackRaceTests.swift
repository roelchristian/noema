import Foundation
import Synchronization
import Testing
@testable import VaultCore

private struct RollbackRaceSignal: Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: Void.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func signal() { continuation.yield(()) }
    func finish() { continuation.finish() }

    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { return }
                throw RollbackRaceTimeout.signalEnded
            }
            group.addTask {
                // A watchdog bounds deadlocks; scheduling order comes only from signals.
                try await Task.sleep(for: .seconds(5))
                throw RollbackRaceTimeout.deadline
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private enum RollbackRaceTimeout: Error { case deadline, signalEnded }

struct LifecycleRollbackRaceTests {
    private func fixture() throws -> (base: URL, root: URL, drafts: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-rollback-race-\(UUID())", isDirectory: true)
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root, base.appendingPathComponent("Drafts", isDirectory: true))
    }

    @Test
    func cancelledLockDuringAdmittedPreCommitSavePreservesCanonicalBytesDraftAndReleasesRegistrations() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let manager = VaultSessionManager()
        let (session, lease, repo) = try await manager.openRepository(root: fixture.root, create: true)
        let recovery = try RecoveryStore(directory: fixture.drafts, sessionLease: lease, accessGate: manager.accessGate)
        let note = try await repo.create(title: "Canonical", body: "Original durable body")
        let canonicalURL = fixture.root.appendingPathComponent(note.relativePath)
        let canonicalBytes = try await canonicalTestNoteBytes(root: fixture.root, id: note.id)
        let unsavedBody = "Only unsaved draft; cancellation must not write this to canonical storage"
        let entered = RollbackRaceSignal()
        let cancelRequested = RollbackRaceSignal()
        let releaseSave = RollbackRaceSignal()
        let saveFinished = RollbackRaceSignal()
        let lockFinished = RollbackRaceSignal()
        let contextBox = Mutex<VaultQuiescentOperationContext?>(nil)
        let save = Task<NoteRecord, Error> {
            defer { saveFinished.signal() }
            return try await manager.quiescenceCoordinator.performPageSave(
                kind: .autosave, note: note, title: note.title, body: unsavedBody,
                tags: ["dirty"], repository: repo, recovery: recovery, lease: lease
            ) { context in
                contextBox.withLock { $0 = context }
                context.onPreCommitCancel { cancelRequested.signal() }
                entered.signal()
                for await _ in releaseSave.stream { break }
            }
        }
        defer { save.cancel(); releaseSave.finish() }
        try await entered.wait()
        #expect(manager.admissionBarrier.snapshot().activeCount == 1)
        let locking = Task {
            defer { lockFinished.signal() }
            return try await manager.lockWithQuiescence(repository: repo, recovery: recovery, cancelPreCommitSaves: true)
        }
        defer { locking.cancel() }
        try await cancelRequested.wait()
        #expect(await manager.state == .locking(session))
        #expect(manager.admissionBarrier.snapshot().activeCount == 1)
        locking.cancel()
        try await lockFinished.wait()
        await #expect(throws: VaultSessionError.cancelled(action: "lock")) { _ = try await locking.value }
        #expect(await manager.state == .open(session))
        #expect(manager.admissionBarrier.isOpen)
        #expect(try await canonicalTestNoteBytes(root: fixture.root, id: note.id) == canonicalBytes)
        #expect(try await recovery.drafts().first?.body == unsavedBody)
        #expect(contextBox.withLock { $0?.noteSnapshot?.body } == unsavedBody)

        releaseSave.signal()
        try await saveFinished.wait()
        await #expect(throws: VaultOperationAdmissionError.cancelled(operation: "autosave")) { _ = try await save.value }
        let registry = manager.admissionBarrier.snapshot()
        #expect(registry.activeCount == 0 && registry.totalCancelledCount == 1 && registry.totalAbandonedCount == 0)
        #expect(manager.quiescenceCoordinator.activeContexts.isEmpty)
        #expect(await manager.inFlightWaiterCount == 0)
        #expect(try await canonicalTestNoteBytes(root: fixture.root, id: note.id) == canonicalBytes)
        #expect(try await recovery.drafts().first?.body == unsavedBody)
        let report = try #require(try await manager.lockWithQuiescence(repository: repo, recovery: recovery))
        #expect(report.preservedDraftIDs == [note.id])
        #expect(await manager.state.phase == .locked)
        #expect(manager.admissionBarrier.snapshot().activeCount == 0)
        #expect(try await canonicalTestNoteBytes(root: fixture.root, id: note.id) == canonicalBytes)
    }

    @Test
    func failedRecoveryAfterAdmittedSaveCancellationRollsBackAndRetriesRetainedDirtySnapshot() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let manager = VaultSessionManager()
        let (session, lease, repo) = try await manager.openRepository(root: fixture.root, create: true)
        let recovery = try RecoveryStore(directory: fixture.drafts, sessionLease: lease, accessGate: manager.accessGate)
        let note = try await repo.create(title: "Canonical", body: "Durable content before recovery failure")
        let canonicalURL = fixture.root.appendingPathComponent(note.relativePath)
        let canonicalBytes = try await canonicalTestNoteBytes(root: fixture.root, id: note.id)
        let draft = DraftRecord(note: note, title: "Unsaved title", body: "Unsaved buffer retained across rollback", tags: ["dirty"])
        let entered = RollbackRaceSignal()
        let cancelRequested = RollbackRaceSignal()
        let releaseSave = RollbackRaceSignal()
        let saveFinished = RollbackRaceSignal()
        let lockFinished = RollbackRaceSignal()
        let contextBox = Mutex<VaultQuiescentOperationContext?>(nil)
        let save = Task<NoteRecord, Error> {
            defer { saveFinished.signal() }
            return try await manager.quiescenceCoordinator.runOperation(kind: .autosave, lease: lease, noteSnapshot: draft) { context in
                contextBox.withLock { $0 = context }
                context.onPreCommitCancel { cancelRequested.signal() }
                entered.signal()
                for await _ in releaseSave.stream { break }
                try context.checkPreCommitCancellation()
                throw VaultError.storage("Cancelled save unexpectedly passed its admission barrier")
            }
        }
        defer { save.cancel(); releaseSave.finish() }
        try await entered.wait()
        let locking = Task {
            defer { lockFinished.signal() }
            return try await manager.lockWithQuiescence(repository: repo, recovery: recovery, cancelPreCommitSaves: true)
        }
        defer { locking.cancel() }
        try await cancelRequested.wait()
        #expect(await manager.state == .locking(session))
        #expect(manager.admissionBarrier.snapshot().activeCount == 1)
        // The operation remains admitted while the journal path is replaced deterministically.
        try FileManager.default.removeItem(at: fixture.drafts)
        let blockerBytes = Data("Injected recovery journal failure".utf8)
        try blockerBytes.write(to: fixture.drafts)
        releaseSave.signal()
        try await saveFinished.wait()
        await #expect(throws: VaultOperationAdmissionError.cancelled(operation: "autosave")) { _ = try await save.value }
        try await lockFinished.wait()
        do {
            _ = try await locking.value
            Issue.record("A recovery journal failure after cancellation must abort locking")
        } catch let error as VaultSessionError {
            guard case .lockAborted(let root, let message) = error else {
                Issue.record("Unexpected transition error: \(error)")
                return
            }
            #expect(root == session.root && message.contains("preserve unsaved draft"))
        }
        #expect(await manager.state == .open(session))
        #expect(manager.admissionBarrier.isOpen)
        #expect(manager.admissionBarrier.snapshot().activeCount == 0)
        #expect(manager.admissionBarrier.snapshot().totalCancelledCount == 1)
        #expect(manager.admissionBarrier.snapshot().totalAbandonedCount == 0)
        #expect(manager.quiescenceCoordinator.activeContexts.isEmpty)
        #expect(await manager.inFlightWaiterCount == 0)
        #expect(try await canonicalTestNoteBytes(root: fixture.root, id: note.id) == canonicalBytes)
        #expect(try Data(contentsOf: fixture.drafts) == blockerBytes)
        #expect(contextBox.withLock { $0?.noteSnapshot?.body } == draft.body)
        #expect(contextBox.withLock { $0?.isDraftPreserved } == false)

        try FileManager.default.removeItem(at: fixture.drafts)
        try FileManager.default.createDirectory(at: fixture.drafts, withIntermediateDirectories: true)
        let report = try #require(try await manager.lockWithQuiescence(
            repository: repo, recovery: recovery,
            pendingState: VaultPendingEditorState(dirtyNote: .init(
                note: note, title: draft.title, body: draft.body, tags: draft.tags, preferDirectSave: false
            ))
        ))
        #expect(report.preservedDraftIDs == [note.id])
        #expect(await manager.state.phase == .locked)
        #expect(manager.admissionBarrier.snapshot().activeCount == 0)
        #expect(try await canonicalTestNoteBytes(root: fixture.root, id: note.id) == canonicalBytes)
        let unlocked = try await manager.unlock()
        let freshRecovery = try RecoveryStore(directory: fixture.drafts, sessionLease: unlocked.lease, accessGate: manager.accessGate)
        let recovered = try #require(try await freshRecovery.drafts().first)
        #expect(recovered.id == note.id && recovered.body == draft.body && recovered.title == draft.title && recovered.tags == draft.tags)
        #expect(try await canonicalTestNoteBytes(root: fixture.root, id: note.id) == canonicalBytes)
    }
}
