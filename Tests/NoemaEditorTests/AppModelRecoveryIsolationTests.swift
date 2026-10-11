import Foundation
import Testing
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct AppModelRecoveryIsolationTests {
    @Test @MainActor func corruptedDraftRemainsVisibleAndPeersRecoverAcrossLockUnlockAndReopening() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("noema-recovery-isolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        let local = base.appendingPathComponent("Local")
        let draftsDirectory = local.appendingPathComponent("KnowledgeVault/\(repository.manifest.id.uuidString)/Drafts")
        let fixture = try RecoveryStore(unguardedTestingDirectory: draftsDirectory)
        var drafts: [DraftRecord] = []
        for i in 0..<3 {
            let note = try await repository.create(title: "Page \(i)", body: "Canonical \(i)")
            let draft = DraftRecord(note: note, title: note.title, body: "Unsaved \(i)", tags: ["recovery"])
            try await fixture.store(draft)
            drafts.append(draft)
        }
        let corrupt = draftsDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let original = Data("{\"body\":\"Only partial unsaved work".utf8)
        try original.write(to: corrupt)

        let model = AppModel()
        model.localStorageRoot = local
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        #expect(model.isVaultAvailable)
        #expect(model.errorMessage == nil)
        #expect(Set(model.recoveredDrafts.map(\.id)) == Set(drafts.map(\.id)))
        #expect(model.damagedRecoveryEntries.first?.fileURL.resolvingSymlinksInPath().path == corrupt.resolvingSymlinksInPath().path)
        #expect(model.hasRecoveryEntries)

        #expect(await model.lockVault())
        #expect(model.recoveredDrafts.isEmpty)
        #expect(model.damagedRecoveryEntries.isEmpty)
        #expect(!model.hasRecoveryEntries)
        #expect(await model.unlockVault())
        #expect(model.recoveredDrafts.count == 3)
        #expect(model.damagedRecoveryEntries.count == 1)
        #expect(try Data(contentsOf: corrupt) == original)

        #expect(await model.closeVault())
        await model.open(root, create: false)
        #expect(model.isVaultAvailable)
        #expect(model.recoveredDrafts.count == 3)
        #expect(model.damagedRecoveryEntries.count == 1)

        for draft in drafts {
            model.saveDraftAsNewPage(draft)
            for _ in 0..<200 {
                if !model.recoveredDrafts.contains(where: { $0.id == draft.id }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!model.recoveredDrafts.contains { $0.id == draft.id })
            #expect(model.notes.contains { $0.title == draft.title + " (recovered)" && $0.body == draft.body && $0.tags == draft.tags })
            #expect(model.errorMessage == nil)
            #expect(model.damagedRecoveryEntries.count == 1)
            #expect(try Data(contentsOf: corrupt) == original)
        }
        // The menu and sidebar must remain available when only damaged entries are left.
        #expect(model.recoveredDrafts.isEmpty)
        #expect(model.hasRecoveryEntries)
        #expect(await model.closeVault())
        await model.open(root, create: false)
        #expect(model.recoveredDrafts.isEmpty)
        #expect(model.damagedRecoveryEntries.count == 1)
        #expect(model.hasRecoveryEntries)
        #expect(try Data(contentsOf: corrupt) == original)
        #expect(await model.closeVault())
    }
}
}
