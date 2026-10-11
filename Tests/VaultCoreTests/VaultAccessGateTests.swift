import Foundation
import Synchronization
import Testing
@testable import VaultCore

struct VaultAccessGateTests {
    private func makeTempVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-gate-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try FileVaultRepository.open(root: root, create: true)
        return root
    }

    @Test func readsAndWritesAreDeniedWhileLockedAndManifestInspectionRemainsOutsideProtectedAPI() async throws {
        let root = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = VaultSessionManager()
        let (session, lease, repo) = try await manager.openRepository(root: root)
        #expect(session.generation == 1)

        let note = try await repo.create(title: "Protected Page", body: "Initial secret content")
        let sourceData = Data("Original source payload".utf8)
        let source = try await repo.importSource(
            data: sourceData,
            filename: "doc.txt",
            title: "Protected Source",
            originURL: nil
        )
        let noteToTrash = try await repo.create(title: "Trash Candidate", body: "To trash")
        try await repo.trash(note: noteToTrash)
        let trashedBeforeLock = try await repo.trashedPages()
        #expect(trashedBeforeLock.count == 1)

        // Lock the session.
        try await manager.lock()
        #expect(await manager.state.phase == .locked)

        // Manifest inspection remains permitted outside the protected content API while locked or closed.
        let gatedProvider = VaultStorageProvider.plaintext.gated(by: manager.accessGate, lease: lease, vaultID: session.vaultID)
        let inspectedWhileLocked = try FileVaultRepository.inspectManifest(at: root, storageProvider: gatedProvider)
        #expect(inspectedWhileLocked.id == session.vaultID)

        // Direct protected VaultContentStore reads and writes are denied while locked.
        let gatedStore = try #require(repo.contentStore as? GatedVaultContentStore)
        #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "read Wiki/Protected Page.md")) {
            _ = try gatedStore.read(at: note.relativePath)
        }
        #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "read vault.json")) {
            _ = try gatedStore.read(at: "vault.json")
        }
        #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "write Wiki/LockedWrite.md")) {
            try gatedStore.write(Data("blocked".utf8), at: "Wiki/LockedWrite.md", condition: .createOnly)
        }
        #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "snapshot Sources/\(source.id.uuidString.lowercased())")) {
            _ = try gatedStore.snapshot(at: "Sources/\(source.id.uuidString.lowercased())")
        }

        // Repository protected reads and writes are denied while locked (including cached scan paths).
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "scan")) {
            _ = try await repo.scan()
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "create")) {
            _ = try await repo.create(title: "Blocked Create", body: "No")
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "save")) {
            _ = try await repo.save(note: note, title: note.title, body: "Mutated while locked", tags: [])
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "setEditingLock")) {
            _ = try await repo.setEditingLock(note: note, locked: true)
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "trashedPages")) {
            _ = try await repo.trashedPages()
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "restore")) {
            try await repo.restore(trashedBeforeLock[0])
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "permanentlyDelete")) {
            try await repo.permanentlyDelete(trashedBeforeLock[0])
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "importSource")) {
            _ = try await repo.importSource(data: Data("new".utf8), filename: "a.txt", title: "A", originURL: nil)
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "renameSource")) {
            _ = try await repo.renameSource(source, title: "Renamed While Locked")
        }
        await #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "deleteSource")) {
            try await repo.deleteSource(source)
        }
        #expect(throws: VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "readSourceOriginal")) {
            _ = try FileVaultRepository.readSourceOriginal(source, root: root, contentStore: repo.contentStore)
        }
        let availabilityWhileLocked = FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repo.contentStore)
        #expect(availabilityWhileLocked.contains("locked"))
    }

    @Test func staleSessionTokensAreRejectedAfterUnlockAndVaultSwitch() async throws {
        let rootA = try makeTempVault()
        let rootB = try makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let manager = VaultSessionManager()
        let (session1, lease1, repoGen1) = try await manager.openRepository(root: rootA)
        #expect(lease1.generation == 1)
        let page = try await repoGen1.create(title: "Gen 1 Note", body: "Body v1")

        // Lock and unlock Vault A -> advances generation to 2.
        try await manager.lock()
        let unlockedSession2 = try await manager.unlock()
        #expect(unlockedSession2.generation == 2)
        let lease2 = try await manager.issueLease(for: rootA, vaultID: session1.vaultID)
        let repoGen2 = try FileVaultRepository.open(
            root: rootA,
            sessionLease: lease2,
            accessGate: manager.accessGate
        )

        // Stale lease (generation 1) and repository bound to generation 1 are rejected while generation 2 is active.
        await #expect(throws: VaultAccessError.staleLease(leaseGeneration: 1, activeGeneration: 2, operation: "scan")) {
            _ = try await repoGen1.scan()
        }
        await #expect(throws: VaultAccessError.staleLease(leaseGeneration: 1, activeGeneration: 2, operation: "save")) {
            _ = try await repoGen1.save(note: page, title: page.title, body: "Stale write", tags: [])
        }
        #expect(throws: VaultAccessError.staleLease(leaseGeneration: 1, activeGeneration: 2, operation: "open")) {
            _ = try FileVaultRepository.open(root: rootA, sessionLease: lease1, accessGate: manager.accessGate)
        }

        // Fresh generation 2 repository succeeds.
        let updatedPage = try await repoGen2.save(note: page, title: page.title, body: "Body v2", tags: [])
        #expect(updatedPage.body == "Body v2")

        // Switch from Vault A (generation 2) to Vault B (generation 3).
        try await manager.close()
        let (sessionB, _, repoB) = try await manager.openRepository(root: rootB)
        #expect(sessionB.generation == 3)

        // Stale work on Vault A's generation 2 repository is rejected by generation mismatch.
        await #expect(throws: VaultAccessError.staleLease(leaseGeneration: 2, activeGeneration: 3, operation: "save")) {
            _ = try await repoGen2.save(note: updatedPage, title: updatedPage.title, body: "Stale cross-switch write", tags: [])
        }
        #expect(try await repoB.scan().notes.isEmpty)
    }

    @Test func queuedAndSuspendedOperationsCrossingLockBoundariesAreRejectedWhenIOExecutes() async throws {
        let root = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = VaultSessionManager()
        let firstReadEntered = AsyncStream.makeStream(of: Void.self)
        let releaseFirstRead = AsyncStream.makeStream(of: Void.self)
        let shouldBlockFirstNoteRead = Mutex(true)

        let (_, _, repo) = try await manager.openRepository(root: root) { operation in
            if operation.hasPrefix("read Wiki/"), shouldBlockFirstNoteRead.withLock({
                if $0 { $0 = false; return true }
                return false
            }) {
                firstReadEntered.continuation.yield(())
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    for await _ in releaseFirstRead.stream {
                        semaphore.signal()
                        break
                    }
                }
                semaphore.wait()
            }
        }

        // Create initial note while open ( disable blocking until after creation ).
        shouldBlockFirstNoteRead.withLock { $0 = false }
        let note = try await repo.create(title: "Boundary Page", body: "Original")
        shouldBlockFirstNoteRead.withLock { $0 = true }

        // 1. Start a repository save that enters actor execution while `.open`, then pauses right before reading the note.
        // 2. Queue a second repository operation (`create`) behind it while `.open`.
        let inFlightSave = Task {
            try await repo.save(note: note, title: note.title, body: "In-flight save crossing lock", tags: [])
        }

        for await _ in firstReadEntered.stream { break }

        // Queue another operation while the actor is busy, then lock the session before releasing I/O.
        let queuedCreate = Task {
            try await repo.create(title: "Queued Page", body: "Should be denied after lock")
        }

        try await manager.lock()
        #expect(await manager.state.phase == .locked)

        // Release the blocked I/O: both the in-flight operation and the queued operation must fail revalidation!
        releaseFirstRead.continuation.yield(())

        await #expect(throws: VaultAccessError.self) {
            _ = try await inFlightSave.value
        }
        await #expect(throws: VaultAccessError.self) {
            _ = try await queuedCreate.value
        }

        // Also test async network fetch suspension (`importURLSource`) crossing a lock boundary:
        let unlocked = try await manager.unlock()
        let unlockedRepo = try FileVaultRepository.open(
            root: root,
            sessionLease: unlocked.lease,
            accessGate: manager.accessGate
        )

        let fetchStarted = AsyncStream.makeStream(of: Void.self)
        let releaseFetch = AsyncStream.makeStream(of: Void.self)

        let suspendedImport = Task {
            try await unlockedRepo.importURLSource("https://example.com/article.txt") { _ in
                fetchStarted.continuation.yield(())
                for await _ in releaseFetch.stream { break }
                return WebSourceFetch(data: Data("fetched text".utf8), filename: "article.txt")
            }
        }

        for await _ in fetchStarted.stream { break }
        // Lock while the async fetch is in flight (after initial request validation passed).
        try await manager.lock()
        releaseFetch.continuation.yield(())

        await #expect(throws: VaultAccessError.sessionLocked(vaultID: unlocked.vaultID, root: unlocked.root, operation: "importURLSource")) {
            _ = try await suspendedImport.value
        }

        // Unlock and verify disk contents were never mutated by any of the operations that crossed the lock boundary.
        let finalSession = try await manager.unlock()
        let finalRepo = try FileVaultRepository.open(
            root: root,
            sessionLease: finalSession.lease,
            accessGate: manager.accessGate
        )
        let finalScan = try await finalRepo.scan()
        #expect(finalScan.notes.count == 1)
        #expect(finalScan.notes.first?.body == "Original")
        #expect(finalScan.sources.isEmpty)
    }

    @Test func wrongVaultAccessIsRejectedAcrossRepositoriesStoresAndLeases() async throws {
        let rootA = try makeTempVault()
        let rootB = try makeTempVault()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let manager = VaultSessionManager()
        let (sessionA, leaseA, repoA) = try await manager.openRepository(root: rootA)
        let sourceInA = try await repoA.importSource(
            data: Data("Vault A source".utf8),
            filename: "a.txt",
            title: "Source A",
            originURL: nil
        )
        let manifestB = try FileVaultRepository.inspectManifest(at: rootB)

        // 1. Attempting to open Vault B using Vault A's active lease is rejected as wrongVault.
        #expect(throws: VaultAccessError.wrongVault(
            expectedVaultID: nil,
            expectedRoot: rootB.standardizedFileURL.resolvingSymlinksInPath(),
            actualVaultID: sessionA.vaultID,
            actualRoot: sessionA.root,
            operation: "open"
        )) {
            _ = try FileVaultRepository.open(root: rootB, sessionLease: leaseA, accessGate: manager.accessGate)
        }

        // 2. Attempting to issue a lease for Vault B while Vault A is open is rejected as wrongVault.
        await #expect(throws: VaultAccessError.wrongVault(
            expectedVaultID: manifestB.id,
            expectedRoot: rootB.standardizedFileURL.resolvingSymlinksInPath(),
            actualVaultID: sessionA.vaultID,
            actualRoot: sessionA.root,
            operation: "issueLease"
        )) {
            _ = try await manager.issueLease(for: rootB, vaultID: manifestB.id)
        }

        // 3. Forging a lease with Vault B's root/ID but current generation while Vault A is open in the gate is rejected.
        let forgedLeaseForB = VaultSessionLease(
            sessionID: sessionA.id,
            vaultID: manifestB.id,
            root: rootB,
            generation: sessionA.generation
        )
        #expect(throws: VaultAccessError.wrongVault(
            expectedVaultID: manifestB.id,
            expectedRoot: rootB.standardizedFileURL.resolvingSymlinksInPath(),
            actualVaultID: sessionA.vaultID,
            actualRoot: sessionA.root,
            operation: "open"
        )) {
            _ = try FileVaultRepository.open(root: rootB, sessionLease: forgedLeaseForB, accessGate: manager.accessGate)
        }

        // 4. Using Vault A's gated contentStore to read a source with Vault B's root URL is rejected as wrongVault.
        #expect(throws: VaultAccessError.wrongVault(
            expectedVaultID: sessionA.vaultID,
            expectedRoot: sessionA.root,
            actualVaultID: nil,
            actualRoot: rootB.standardizedFileURL.resolvingSymlinksInPath(),
            operation: "readSourceOriginal"
        )) {
            _ = try FileVaultRepository.readSourceOriginal(sourceInA, root: rootB, contentStore: repoA.contentStore)
        }
    }
}
