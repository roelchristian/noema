import Foundation
import Synchronization
import Testing
@testable import VaultCore

struct VaultSaveQuiescenceTests {
    private func makeTempVaultAndRecovery() async throws -> (root: URL, recoveryDir: URL, recovery: RecoveryStore) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-quiescence-test-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        let recoveryDir = base.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await canonicalSchema5TestRepository(root: root, create: true)
        let recovery = try RecoveryStore(unguardedTestingDirectory: recoveryDir)
        return (root, recoveryDir, recovery)
    }

    @Test func inFlightSavesEnteringCommitWindowCompleteAndRemainRecognizedWhilePreCommitSavesPreserveRecoveryDraft() async throws {
        let (root, _, recovery) = try await makeTempVaultAndRecovery()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let manager = VaultSessionManager()
        let coordinator = manager.quiescenceCoordinator
        let (session, lease, repo) = try await manager.openRepository(root: root)

        let noteCommitted = try await repo.create(title: "Committed Page", body: "Initial committed body")
        let noteCancelled = try await repo.create(title: "PreCommit Page", body: "Initial pre-commit body")

        let commitEntered = AsyncStream.makeStream(of: Void.self)
        let releaseCommit = AsyncStream.makeStream(of: Void.self)
        let preCommitEntered = AsyncStream.makeStream(of: Void.self)

        // 1. Start an in-flight save that has already entered its durable commit window (`performDurableCommit`).
        let committingSaveTask = Task<NoteRecord, Error> {
            try await coordinator.runOperation(
                kind: .save,
                lease: lease,
                noteSnapshot: DraftRecord(
                    note: noteCommitted,
                    title: "Committed Page",
                    body: "Updated body inside commit window",
                    tags: ["committed"]
                )
            ) { context in
                try await recovery.store(context.noteSnapshot!)
                context.markDraftPreserved()
                return try await context.performDurableCommit {
                    commitEntered.continuation.yield(())
                    for await _ in releaseCommit.stream { break }
                    let saved = try await repo.save(
                        note: noteCommitted,
                        title: "Committed Page",
                        body: "Updated body inside commit window",
                        tags: ["committed"]
                    )
                    try? await recovery.remove(saved.id)
                    return saved
                }
            }
        }

        // 2. Start an in-flight autosave that is still in `.preCommit` when lock quiescence begins.
        let preCommitAutosaveTask = Task<NoteRecord, Error> {
            try await coordinator.performPageSave(
                kind: .autosave,
                note: noteCancelled,
                title: "PreCommit Page Edited",
                body: "Unsaved body cancelled before commit",
                tags: ["draft"],
                repository: repo,
                recovery: recovery,
                lease: lease
            ) { context in
                let cancelWait = AsyncStream.makeStream(of: Void.self)
                context.onPreCommitCancel {
                    cancelWait.continuation.yield(())
                }
                preCommitEntered.continuation.yield(())
                for await _ in cancelWait.stream { break }
            }
        }

        for await _ in commitEntered.stream { break }
        for await _ in preCommitEntered.stream { break }

        // Start lock with quiescence (`cancelPreCommitSaves: true` so the pre-commit autosave cancels & preserves its draft,
        // while the committing save cannot be cancelled and finishes its durable write).
        let lockTask = Task {
            try await manager.lockWithQuiescence(
                repository: repo,
                recovery: recovery,
                cancelPreCommitSaves: true
            )
        }

        // Give quiescence a moment to signal pre-commit cancellation, then release the committing save.
        try await Task.sleep(for: .milliseconds(30))
        releaseCommit.continuation.yield(())

        let committedResult = try await committingSaveTask.value
        #expect(canonicalTestReadableBody(committedResult.body) == "Updated body inside commit window")
        #expect(committedResult.tags == ["committed"])

        await #expect(throws: VaultOperationAdmissionError.cancelled(operation: "autosave")) {
            _ = try await preCommitAutosaveTask.value
        }

        let report = try #require(try await lockTask.value)
        #expect(await manager.state.phase == .locked)

        // Verify the committed write is recognized in the coordinator & on disk after unlocking,
        // and its temporary recovery draft was cleaned up.
        #expect(canonicalTestReadableBody(coordinator.committedNotes[noteCommitted.id]?.body) == "Updated body inside commit window")
        #expect(report.preservedDraftIDs == [noteCancelled.id])

        let draftsAfterLock = try await recovery.drafts()
        #expect(draftsAfterLock.count == 1)
        #expect(draftsAfterLock.first?.id == noteCancelled.id)
        #expect(draftsAfterLock.first?.title == "PreCommit Page Edited")
        #expect(draftsAfterLock.first?.body == "Unsaved body cancelled before commit")

        // Unlock and verify canonical storage state:
        let unlocked = try await manager.unlock()
        let unlockedRepo = try FileVaultRepository.open(
            root: root,
            sessionLease: unlocked.lease,
            accessGate: manager.accessGate
        )
        let scanned = try await unlockedRepo.scan()
        let diskCommitted = try #require(scanned.notes.first(where: { $0.id == noteCommitted.id }))
        let diskCancelled = try #require(scanned.notes.first(where: { $0.id == noteCancelled.id }))
        #expect(canonicalTestReadableBody(diskCommitted.body) == "Updated body inside commit window")
        #expect(canonicalTestReadableBody(diskCancelled.body) == "Initial pre-commit body")
        #expect(session.id != unlocked.id)
    }

    @Test func pendingDebouncedDirtyEditorAndLCCEditsAreFlushedOrPreservedInRecoveryBeforeLocked() async throws {
        let (root, _, recovery) = try await makeTempVaultAndRecovery()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let manager = VaultSessionManager()
        let (_, _, repo) = try await manager.openRepository(root: root)

        let note1 = try await repo.create(title: "Debounced Note", body: "Initial")
        let source1 = try await repo.importSource(
            data: Data("Source text content".utf8),
            filename: "source.txt",
            title: "Source 1",
            originURL: nil
        )

        // Case A: Pending dirty note + pending source LCC update flush cleanly during quiescence before reaching .locked.
        let pendingState = VaultPendingEditorState(
            dirtyNote: .init(
                note: note1,
                title: "Debounced Note Renamed",
                body: "Flushed during lock quiescence",
                tags: ["quiesced"],
                lcc: "QA76",
                preferDirectSave: true
            ),
            pendingPageLCC: nil,
            pendingSourceLCCs: [.init(source: source1, lcc: "QA76.73")]
        )

        let report = try #require(try await manager.lockWithQuiescence(
            repository: repo,
            recovery: recovery,
            pendingState: pendingState
        ))
        #expect(await manager.state.phase == .locked)
        #expect(report.preservedDraftIDs.isEmpty)
        #expect(try await recovery.drafts().isEmpty)

        // Unlock and verify both the note edit and the source LCC edit were durably committed before lock completed.
        let session2 = try await manager.unlock()
        let repo2 = try FileVaultRepository.open(
            root: root,
            sessionLease: session2.lease,
            accessGate: manager.accessGate
        )
        let scan2 = try await repo2.scan()
        let savedNote = try #require(scan2.notes.first(where: { $0.id == note1.id }))
        #expect(savedNote.title == "Debounced Note Renamed")
        #expect(canonicalTestReadableBody(savedNote.body) == "Flushed during lock quiescence")
        #expect(savedNote.tags == ["quiesced"])
        #expect(savedNote.lcc == "QA76")

        let savedSource = try #require(scan2.sources.first(where: { $0.id == source1.id }))
        #expect(savedSource.metadata.lcc == "QA76.73")

        // Case B: Simulate an external edit / conflict on disk so the direct repository save during quiescence
        // cannot overwrite the file; verify quiescence preserves both the conflict copy AND the user's draft in RecoveryStore!
        _ = try await repo2.save(note: savedNote, title: savedNote.title,
                                 body: "External concurrent modification on disk", tags: savedNote.tags)

        let conflictingPendingState = VaultPendingEditorState(
            dirtyNote: .init(
                note: savedNote, // stale contentHash relative to externalBytes
                title: savedNote.title,
                body: "User local unsaved edit before lock",
                tags: ["local"],
                lcc: "QA76",
                preferDirectSave: true
            )
        )

        let conflictReport = try #require(try await manager.lockWithQuiescence(
            repository: repo2,
            recovery: recovery,
            pendingState: conflictingPendingState
        ))
        #expect(await manager.state.phase == .locked)
        #expect(conflictReport.preservedDraftIDs == [savedNote.id])

        let preservedDrafts = try await recovery.drafts()
        #expect(preservedDrafts.count == 1)
        #expect(preservedDrafts.first?.id == savedNote.id)
        #expect(preservedDrafts.first?.body == "User local unsaved edit before lock")

        // Revision rejection preserves the user's draft without writing legacy conflict copies.
        #expect(preservedDrafts.first?.body == "User local unsaved edit before lock")

    }

    @Test func cancelledImportsCleanOnlyOwnedStagingAndPreserveUnknownCopiesAcrossLockAndReopen() async throws {
        let (root, _, recovery) = try await makeTempVaultAndRecovery()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let manager = VaultSessionManager()
        let coordinator = manager.quiescenceCoordinator
        let (_, lease, repo) = try await manager.openRepository(root: root)

        let interruptedImportID = UUID()
        let committedImportID = UUID()
        let downloadURL = root.deletingLastPathComponent().appendingPathComponent("cloud-sample.txt")
        try Data("Cloud payload".utf8).write(to: downloadURL)
        let pendingDownload = try await repo.beginSourceDownload(at: downloadURL, shouldImport: true)
        #expect((await repo.activeDownloadingSourceIDs).contains(pendingDownload.id))

        // Also create an orphaned `.import-<UUID>` staging directory in `Sources/` to simulate an interrupted staging step.
        let orphanStagingID = UUID()
        let orphanStagingRelPath = "Sources/.import-\(orphanStagingID.uuidString)"
        try repo.contentStore.createDirectory(at: orphanStagingRelPath)
        try repo.contentStore.write(Data("partial bytes".utf8), at: orphanStagingRelPath + "/original.txt", condition: .createOnly)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphanStagingRelPath).path))

        let fetchEntered = AsyncStream.makeStream(of: Void.self)
        let commitImportEntered = AsyncStream.makeStream(of: Void.self)
        let releaseCommitImport = AsyncStream.makeStream(of: Void.self)

        // 1. Start a source import still in `.preCommit` (e.g. fetching URL bytes) when lock is requested.
        let preCommitImportTask = Task<SourceRecord, Error> {
            try await coordinator.performSourceImport(
                kind: .sourceImport,
                sourceID: interruptedImportID,
                repository: repo,
                lease: lease,
                prepare: { context in
                    // Create a staging directory during pre-commit preparation to verify cleanup on cancellation.
                    let staging = "Sources/.import-\(interruptedImportID.uuidString)"
                    try repo.contentStore.createDirectory(at: staging)
                    try repo.contentStore.write(Data("staged pre-commit".utf8), at: staging + "/original.txt", condition: .createOnly)

                    let cancelStream = AsyncStream.makeStream(of: Void.self)
                    context.onPreCommitCancel {
                        cancelStream.continuation.yield(())
                    }
                    fetchEntered.continuation.yield(())
                    for await _ in cancelStream.stream { break }
                    try context.checkPreCommitCancellation()
                    return (Data("staged pre-commit".utf8), "article.txt", "Interrupted Import", "https://example.com/a.txt", true)
                }
            )
        }

        // 2. Start a second source import that has already entered its durable commit window.
        let committingImportTask = Task<SourceRecord, Error> {
            try await coordinator.runOperation(
                kind: .sourceImport,
                lease: lease,
                sourceImportID: committedImportID
            ) { context in
                try await context.performDurableCommit {
                    commitImportEntered.continuation.yield(())
                    for await _ in releaseCommitImport.stream { break }
                    return try await repo.importPreparedSource(
                        id: committedImportID,
                        data: Data("Committed source content".utf8),
                        filename: "committed.txt",
                        title: "Committed Source",
                        originURL: nil,
                        isURLSource: false
                    )
                }
            }
        }

        for await _ in fetchEntered.stream { break }
        for await _ in commitImportEntered.stream { break }

        let lockTask = Task {
            try await manager.lockWithQuiescence(
                repository: repo,
                recovery: recovery,
                pendingState: VaultPendingEditorState(activeDownloadSourceIDs: [pendingDownload.id])
            )
        }

        try await Task.sleep(for: .milliseconds(30))
        releaseCommitImport.continuation.yield(())

        let committedSource = try await committingImportTask.value
        #expect(committedSource.id == committedImportID)
        #expect(committedSource.title == "Committed Source")

        await #expect(throws: VaultOperationAdmissionError.cancelled(operation: "sourceImport")) {
            _ = try await preCommitImportTask.value
        }

        let report = try #require(try await lockTask.value)
        #expect(await manager.state.phase == .locked)
        #expect(report.cancelledSourceImportIDs.contains(interruptedImportID))
        #expect(report.cancelledSourceImportIDs.contains(pendingDownload.id))
        #expect(await repo.activeDownloadingSourceIDs.isEmpty)

        // Only tracked cancelled staging is disposable; orphan bytes may be unique.
        let sourcesDir = root.appendingPathComponent("Sources")
        let remainingEntries = try FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil)
        #expect(remainingEntries.filter { $0.lastPathComponent.hasPrefix(".import-") }.map(\.lastPathComponent) == [".import-" + orphanStagingID.uuidString])
        #expect(try Data(contentsOf: root.appendingPathComponent(orphanStagingRelPath + "/original.txt")) == Data("partial bytes".utf8))
        #expect(!report.cleanedStagingPaths.contains(orphanStagingRelPath))

        // Unlock and verify only the committed source exists in the vault.
        let unlocked = try await manager.unlock()
        let unlockedRepo = try FileVaultRepository.open(
            root: root,
            sessionLease: unlocked.lease,
            accessGate: manager.accessGate
        )
        let scanned = try await unlockedRepo.scan()
        #expect(try unlockedRepo.contentStore.read(at: orphanStagingRelPath + "/original.txt") == Data("partial bytes".utf8))
        #expect(scanned.sources.map(\.id) == [committedImportID])
        #expect(scanned.issues.isEmpty)
    }

    @Test func unrecoverableQuiescenceFailureReportsErrorAndAvoidsFalselyPublishingLocked() async throws {
        let (root, _, _) = try await makeTempVaultAndRecovery()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // Create a read-only file where the RecoveryStore directory should be, or point RecoveryStore to a removed/unwritable path
        // so `recovery.store(draft)` fails deterministically during quiescence.
        let brokenRecoveryDir = root.deletingLastPathComponent().appendingPathComponent("BrokenDrafts", isDirectory: true)
        let brokenRecovery = try RecoveryStore(unguardedTestingDirectory: brokenRecoveryDir)
        // Replace the directory with a regular file so atomic draft writes into `BrokenDrafts/<id>.json` fail!
        try FileManager.default.removeItem(at: brokenRecoveryDir)
        try Data("not a directory".utf8).write(to: brokenRecoveryDir)

        let manager = VaultSessionManager()
        let (session, _, repo) = try await manager.openRepository(root: root)
        let note = try await repo.create(title: "Critical Unsaved Page", body: "Initial")

        // Observe state transitions to verify `.locked` is NEVER emitted when quiescence fails.
        let observedStates = Mutex<[VaultSessionPhase]>([])
        let stream = await manager.observations()
        let observerTask = Task {
            for await state in stream {
                observedStates.withLock { $0.append(state.phase) }
            }
        }
        defer { observerTask.cancel() }
        try await Task.sleep(for: .milliseconds(20))

        // Attempt to lock with dirty edits while RecoveryStore is broken (`recovery.store` fails)
        // or when both save and recovery fail (`recovery: nil` and invalid empty title).
        let dirtyPending = VaultPendingEditorState(
            dirtyNote: .init(
                note: note,
                title: "Edited Title",
                body: "Critical unsaved text that cannot be journaled",
                tags: [],
                preferDirectSave: true
            )
        )

        await #expect(throws: VaultSessionError.self) {
            _ = try await manager.lockWithQuiescence(
                repository: repo,
                recovery: brokenRecovery,
                pendingState: dirtyPending
            )
        }

        // Session MUST have rolled back to `.open(session)` and NEVER published `.locked`!
        #expect(await manager.state == .open(session))
        #expect(manager.admissionBarrier.isOpen)

        // Also test when `recovery` is nil and the direct save fails (e.g., empty title):
        let failingSaveWithoutRecovery = VaultPendingEditorState(
            dirtyNote: .init(
                note: note,
                title: "   ", // invalid empty title causes repository.save to throw
                body: "Unsaved text with no recovery store",
                tags: [],
                preferDirectSave: true
            )
        )

        await #expect(throws: VaultSessionError.self) {
            _ = try await manager.lockWithQuiescence(
                repository: repo,
                recovery: nil,
                pendingState: failingSaveWithoutRecovery
            )
        }

        #expect(await manager.state == .open(session))
        try await Task.sleep(for: .milliseconds(20))
        let phases = observedStates.withLock { $0 }
        #expect(!phases.contains(.locked))
    }
}
