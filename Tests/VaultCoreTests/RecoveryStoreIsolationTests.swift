import Foundation
import Testing
@testable import VaultCore

struct RecoveryStoreIsolationTests {
    @Test func oneCorruptEntryDoesNotBlockSeveralValidDraftsAndOriginalBytesSurviveReopening() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recovery-isolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        let directory = root.appendingPathComponent("Drafts")
        let recovery = try RecoveryStore(unguardedTestingDirectory: directory)
        var drafts: [DraftRecord] = []
        for i in 0..<3 {
            let note = try await repository.create(title: "Page \(i)", body: "Canonical \(i)")
            var draft = DraftRecord(note: note, title: note.title, body: "Only unsaved copy \(i)", tags: ["unsaved"])
            draft.capturedAt = "2026-10-12T00:00:0\(i)Z"
            try await recovery.store(draft)
            drafts.append(draft)
        }
        let corrupt = directory.appendingPathComponent(UUID().uuidString + ".json")
        let original = Data([0x7b, 0x22, 0x62, 0x6f, 0x64, 0x79, 0x22, 0x3a, 0xff])
        try original.write(to: corrupt)

        for store in [recovery, try RecoveryStore(unguardedTestingDirectory: directory)] {
            let listing = try await store.listing()
            #expect(listing.drafts.map(\.id) == drafts.reversed().map(\.id))
            #expect(listing.damagedEntries.count == 1)
            let issue = try #require(listing.damagedEntries.first)
            #expect(issue.fileURL.resolvingSymlinksInPath().path == corrupt.resolvingSymlinksInPath().path)
            #expect(issue.failure == .decoding)
            #expect(!issue.message.isEmpty)
            #expect(try await store.drafts().count == 3)
            #expect(try Data(contentsOf: corrupt) == original)
        }

        let restored = try await repository.create(title: "Recovered", body: drafts[0].body)
        #expect(restored.body == "Only unsaved copy 0")
        try await recovery.remove(drafts[0].id)
        #expect(try await recovery.listing().drafts.count == 2)
        #expect(try Data(contentsOf: corrupt) == original)
    }

    @Test func damagedEntryAndValidDraftsRemainAvailableAfterLockUnlockAndFreshSession() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recovery-isolation-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = VaultSessionManager()
        let (_, lease, repository) = try await manager.openRepository(root: root, create: true)
        let directory = root.appendingPathComponent("Drafts")
        let recovery = try RecoveryStore(directory: directory, sessionLease: lease, accessGate: manager.accessGate)
        var ids: Set<UUID> = []
        for i in 0..<3 {
            let note = try await repository.create(title: "Page \(i)", body: "Original")
            ids.insert(note.id)
            try await recovery.store(DraftRecord(note: note, title: note.title, body: "Recover \(i)", tags: []))
        }
        let damagedID = UUID()
        let corrupt = directory.appendingPathComponent(damagedID.uuidString + ".json")
        let original = Data("{\"note\": null}".utf8)
        try original.write(to: corrupt)
        #expect(try await recovery.listing().damagedEntries.count == 1)
        await #expect(throws: VaultError.self) { try await recovery.remove(damagedID) }

        try await manager.lock()
        await #expect(throws: VaultAccessError.self) { _ = try await recovery.listing() }
        let (_, unlockedLease, _) = try await manager.unlockRepository(root: root)
        await #expect(throws: VaultAccessError.self) { _ = try await recovery.listing() }
        let unlocked = try RecoveryStore(directory: directory, sessionLease: unlockedLease, accessGate: manager.accessGate)
        #expect(Set(try await unlocked.listing().drafts.map(\.id)) == ids)
        #expect(try await unlocked.listing().damagedEntries.count == 1)

        try await manager.close()
        await #expect(throws: VaultAccessError.self) { _ = try await unlocked.listing() }
        let (_, reopenedLease, _) = try await manager.openRepository(root: root, create: false)
        let reopened = try RecoveryStore(directory: directory, sessionLease: reopenedLease, accessGate: manager.accessGate)
        #expect(Set(try await reopened.drafts().map(\.id)) == ids)
        #expect(try await reopened.listing().damagedEntries.count == 1)
        #expect(try Data(contentsOf: corrupt) == original)
    }

    @Test(arguments: [false, true]) func savingSamePagePreservesDamagedBytesInVisibleSeparateEntry(identityMismatch: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recovery-collision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        let note = try await repository.create(title: "Page", body: "Original")
        let directory = root.appendingPathComponent("Drafts")
        let recovery = try RecoveryStore(unguardedTestingDirectory: directory)
        var foreignDraft = DraftRecord(note: note, title: "Other page", body: "Only foreign unsaved copy", tags: [])
        foreignDraft.note.id = UUID()
        let original = identityMismatch ? try JSONEncoder().encode(foreignDraft) : Data("{truncated unsaved work".utf8)
        try original.write(to: directory.appendingPathComponent(note.id.uuidString + ".json"))
        // Both damaged JSON and a valid draft for a different page are preservation data.
        await #expect(throws: VaultError.self) { try await recovery.remove(note.id) }
        #expect(try Data(contentsOf: directory.appendingPathComponent(note.id.uuidString + ".json")) == original)
        try await recovery.store(DraftRecord(note: note, title: note.title, body: "New unsaved work", tags: []))
        let listing = try await recovery.listing()
        #expect(listing.drafts.first?.body == "New unsaved work")
        #expect(listing.damagedEntries.count == 1)
        let preserved = try #require(listing.damagedEntries.first)
        #expect(preserved.fileName.contains(".damaged-"))
        #expect(try Data(contentsOf: preserved.fileURL) == original)
        try await recovery.remove(note.id)
        let reopened = try RecoveryStore(unguardedTestingDirectory: directory)
        #expect(try await reopened.drafts().isEmpty)
        #expect(try await reopened.listing().damagedEntries.count == 1)
        #expect(try Data(contentsOf: preserved.fileURL) == original)
    }

    @Test func identityMismatchAndUnreadableEntryAreReportedWithoutBlockingPeers() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("recovery-entry-errors-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        let note = try await repository.create(title: "Page", body: "Original")
        let directory = root.appendingPathComponent("Drafts")
        let recovery = try RecoveryStore(unguardedTestingDirectory: directory)
        let draft = DraftRecord(note: note, title: note.title, body: "Unsaved", tags: [])
        try await recovery.store(draft)
        let mismatch = directory.appendingPathComponent(UUID().uuidString + ".json")
        let original = try JSONEncoder().encode(draft)
        try original.write(to: mismatch)
        // store/remove use the canonical uppercase UUID filename. A different spelling must
        // remain visible as damaged rather than appearing recoverable but never being removed.
        var differentlyNamedDraft = draft
        differentlyNamedDraft.note.id = try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let differentlyNamed = directory.appendingPathComponent(differentlyNamedDraft.id.uuidString.lowercased() + ".json")
        let differentlyNamedBytes = try JSONEncoder().encode(differentlyNamedDraft)
        try differentlyNamedBytes.write(to: differentlyNamed)
        let unreadable = directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        let listing = try await recovery.listing()
        #expect(listing.drafts.count == 1)
        #expect(listing.damagedEntries.count == 3)
        #expect(listing.damagedEntries.contains { $0.fileURL.resolvingSymlinksInPath().path == mismatch.resolvingSymlinksInPath().path && $0.failure == .identityMismatch })
        #expect(listing.damagedEntries.contains { $0.fileURL.resolvingSymlinksInPath().path == differentlyNamed.resolvingSymlinksInPath().path && $0.failure == .identityMismatch })
        #expect(listing.damagedEntries.contains { $0.fileURL.resolvingSymlinksInPath().path == unreadable.resolvingSymlinksInPath().path && $0.failure == .unreadable })
        #expect(try Data(contentsOf: mismatch) == original)
        #expect(try Data(contentsOf: differentlyNamed) == differentlyNamedBytes)
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
    }
}
