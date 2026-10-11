import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct AppModelSessionIntegrationTests {
    private func makeTempVault(name: String = "Vault") throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-d02-5-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try FileVaultRepository.open(root: root, create: true)
        return root
    }

    @MainActor
    private func waitUntil(timeoutMs: Int = 2000, condition: @MainActor () -> Bool) async {
        let iterations = max(1, timeoutMs / 20)
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test @MainActor func appModelObservesSessionStateAndPurgesAllContentEditorSearchAndPreviewStateOnLock() async throws {
        let root = try makeTempVault(name: "AtlasVault")
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            SourceReader.closeAll()
        }

        let repo = try FileVaultRepository.open(root: root)
        var blockDoc = BlockDocument()
        var metadata = BlockMetadata()
        metadata.semantic = "claim"
        blockDoc.blocks = [
            EditorBlock(id: UUID(), kind: .paragraph, runs: [RichRun("Key insight on topological invariants")], metadata: metadata)
        ]
        var createdNote = try await repo.create(
            title: "Topology Notes",
            body: BlockDocumentCodec.encode(blockDoc),
            lcc: "QA611"
        )
        createdNote = try await repo.save(
            note: createdNote,
            title: createdNote.title,
            body: createdNote.body,
            tags: ["math", "topology"]
        )
        _ = try await repo.create(
            title: "Backlink Source",
            body: "See [[Topology Notes]] for details."
        )
        let source = try await repo.importSource(
            data: Data("Original source text for reader window".utf8),
            filename: "paper.txt",
            title: "Topology Paper",
            originURL: "https://example.com/paper"
        )

        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false

        await model.open(root, create: false)
        #expect(model.isVaultAvailable)
        #expect(!model.isLocked)
        #expect(model.sessionPhase == .open)
        #expect(model.vaultName == "AtlasVault")
        #expect(model.notes.count == 2)
        #expect(model.sources.count == 1)

        // Select the note, populate editor buffer, preview, backlinks, search results, and sheets/inspectors.
        model.select(createdNote.id)
        await waitUntil {
            model.currentNote?.id == createdNote.id && !model.preview.isEmpty && !model.backlinks.isEmpty
        }
        #expect(model.currentNote?.id == createdNote.id)
        #expect(model.title == "Topology Notes")
        #expect(model.body.contains("Key insight on topological invariants"))
        #expect(model.tagInput.contains("math"))
        #expect(model.lccInput == "QA611")
        #expect(!model.preview.isEmpty)
        #expect(!model.backlinks.isEmpty)

        model.searchText = "Topology"
        await model.updateRows()
        #expect(!model.sidebarSearchResults.pages.isEmpty)
        #expect(!model.semanticRows.isEmpty)

        // Open a secondary SourceReader window and modal/inspector flags.
        model.openSource(source.id)
        await waitUntil { SourceReader.openReaderIDs.contains(source.id) }
        #expect(SourceReader.openReaderIDs.contains(source.id))

        model.showRecovery = true
        model.showIssues = true
        model.showURLSource = true
        model.showPasteSource = true
        model.showTopicPage = true
        model.ambiguousMatches = model.notes
        model.unresolvedTarget = "Missing Page"
        model.wikiQuery = "Top"

        // Mutate the editor buffer without saving yet so lockVault must coordinate draft/save preservation.
        model.reading = false
        model.body += "\n\nUnsaved paragraph added before lock."
        model.edited()
        #expect(model.dirty)

        // Lock the vault and verify unsaved edits are flushed and all published state is purged.
        #expect(await model.lockVault())
        #expect(model.isLocked)
        #expect(!model.isVaultAvailable)
        #expect(model.sessionPhase == .locked)
        #expect(model.root == nil)
        #expect(model.lockedVaultURL == root)
        #expect(model.vaultName == "AtlasVault")

        // Verify all note bodies, source details, selected document references, editor buffers,
        // search results, previews, sheets, and secondary windows are cleared.
        #expect(model.notes.isEmpty)
        #expect(model.sources.isEmpty)
        #expect(model.rows.isEmpty)
        #expect(model.semanticRows.isEmpty)
        #expect(model.trashedPages.isEmpty)
        #expect(model.recoveredDrafts.isEmpty)
        #expect(model.issues.isEmpty)
        #expect(model.tags.isEmpty)
        #expect(model.backlinks.isEmpty)
        #expect(model.preview.isEmpty)
        #expect(model.recentPageIDs.isEmpty)
        #expect(model.unseenRenamedPages.isEmpty)
        #expect(model.selectedID == nil)
        #expect(model.selectedSemanticID == nil)
        #expect(model.currentNote == nil)
        #expect(model.currentSource == nil)
        #expect(model.title.isEmpty)
        #expect(model.body.isEmpty)
        #expect(model.tagInput.isEmpty)
        #expect(model.lccInput.isEmpty)
        #expect(model.wordCount == 0)
        #expect(model.reading)
        #expect(model.searchText.isEmpty)
        #expect(model.sidebarSearchResults.isEmpty)
        #expect(!model.showRecovery && !model.showIssues && !model.showURLSource && !model.showPasteSource && !model.showTopicPage)
        #expect(model.ambiguousMatches.isEmpty && model.unresolvedTarget == nil && model.wikiQuery == nil)
        #expect(SourceReader.openReaderIDs.isEmpty)

        // Actions requiring an open vault are no-ops while locked.
        model.select(createdNote.id)
        model.changeScope(.sources)
        model.queryChanged()
        model.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.currentNote == nil && model.scope == .wiki && model.notes.isEmpty)

        // Unlock the vault and verify the saved edit and content are restored.
        #expect(await model.unlockVault())
        #expect(model.isVaultAvailable)
        #expect(!model.isLocked)
        #expect(model.sessionPhase == .open)
        #expect(model.root == root)
        let unlockedNote = try #require(model.notes.first(where: { $0.id == createdNote.id }))
        #expect(unlockedNote.body.contains("Unsaved paragraph added before lock."))
    }

    @Test @MainActor func centralSessionStateObservationClearsAppModelAndSecondaryWindowsOnDirectSessionTransitions() async throws {
        let root = try makeTempVault(name: "ObservedVault")
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            SourceReader.closeAll()
        }

        let repo = try FileVaultRepository.open(root: root)
        let note = try await repo.create(title: "Observed Page", body: "Observed body content")
        let source = try await repo.importSource(
            data: Data("Observed source bytes".utf8),
            filename: "observed.txt",
            title: "Observed Source",
            originURL: nil
        )

        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)

        model.select(source.id)
        await waitUntil { model.currentSource?.id == source.id }
        #expect(model.currentSource?.id == source.id)
        #expect(model.body == "Observed source bytes")

        model.openSource(source.id)
        await waitUntil { SourceReader.openReaderIDs.contains(source.id) }
        #expect(SourceReader.openReaderIDs.contains(source.id))

        // Trigger lock directly on the central VaultSessionManager; AppModel's observation stream must react.
        try await model.sessionManager.lock()
        await waitUntil { model.isLocked && model.sessionPhase == .locked }

        #expect(model.isLocked)
        #expect(!model.isVaultAvailable)
        #expect(model.sessionPhase == .locked)
        #expect(model.vaultName == "ObservedVault")
        #expect(model.notes.isEmpty && model.sources.isEmpty)
        #expect(model.currentNote == nil && model.currentSource == nil)
        #expect(model.title.isEmpty && model.body.isEmpty && model.preview.isEmpty)
        #expect(SourceReader.openReaderIDs.isEmpty)

        // Trigger close from locked state via closeVault() and verify transition to welcome (.closed) state.
        #expect(await model.closeVault())
        #expect(!model.isLocked)
        #expect(!model.isVaultAvailable)
        #expect(model.sessionPhase == .closed)
        #expect(model.root == nil && model.lockedVaultURL == nil)

        // Reopen existing vault and verify same-vault idempotent reopen does not duplicate or lose state.
        await model.open(root, create: false)
        #expect(model.isVaultAvailable && model.notes.contains(where: { $0.id == note.id }))
        await model.open(root, create: false)
        #expect(model.isVaultAvailable && model.notes.contains(where: { $0.id == note.id }))
    }

    @Test @MainActor func unlockReacquiresAccessAndHandlesMissingICloudOrPermissionErrors() async throws {
        let root = try makeTempVault(name: "UnlockResilienceVault")
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            SourceReader.closeAll()
        }

        let repo = try FileVaultRepository.open(root: root)
        let note = try await repo.create(title: "Resilient Note", body: "Content preserved across lock/unlock")

        let simulateICloudUnavailable = LockFlag(false)
        let simulatePermissionLost = LockFlag(false)
        let baseProvider = VaultStorageProvider.plaintext
        let provider = VaultStorageProvider { url in
            if simulateICloudUnavailable.get() {
                throw VaultContentStoreError.unavailable("vault.json")
            }
            return try baseProvider.makeStore(root: url)
        }

        let model = AppModel(storageProvider: provider)
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        model.requiresSecurityScopedAccess = true
        model.securityScopeAcquirer = { _ in !simulatePermissionLost.get() }

        await model.open(root, create: false)
        #expect(model.isVaultAvailable)
        #expect(model.notes.map(\.id) == [note.id])

        // Lock the vault.
        #expect(await model.lockVault())
        #expect(model.isLocked && !model.isVaultAvailable)

        // 1. Simulate lost security-scoped permission on unlock -> stays locked, sets needsPermissionReauthorization.
        simulatePermissionLost.set(true)
        #expect(!(await model.unlockVault()))
        #expect(model.isLocked && !model.isVaultAvailable && model.sessionPhase == .locked)
        #expect(model.needsPermissionReauthorization)
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("Reselect your vault folder") == true)
        #expect(model.notes.isEmpty)

        // 2. Restore permission, simulate iCloud metadata not downloaded -> stays locked with iCloud download notice.
        simulatePermissionLost.set(false)
        simulateICloudUnavailable.set(true)
        #expect(!(await model.unlockVault()))
        #expect(model.isLocked && !model.isVaultAvailable && model.sessionPhase == .locked)
        #expect(!model.needsPermissionReauthorization)
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("iCloud") == true)
        #expect(model.notes.isEmpty)

        // 3. Simulate missing vault folder on disk -> stays locked with missing folder error.
        simulateICloudUnavailable.set(false)
        let movedRoot = root.deletingLastPathComponent().appendingPathComponent("MovedVault", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: movedRoot)
        #expect(!(await model.unlockVault()))
        #expect(model.isLocked && !model.isVaultAvailable && model.sessionPhase == .locked)
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("could not be found") == true)
        #expect(model.notes.isEmpty)

        // 4. Move folder back and reselect same vault folder while locked (via open(_:create: false)) -> unlocks cleanly!
        try FileManager.default.moveItem(at: movedRoot, to: root)
        await model.open(root, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.sessionPhase == .open)
        #expect(model.errorMessage == nil && !model.needsPermissionReauthorization)
        #expect(model.notes.map(\.title) == ["Resilient Note"])
    }

    @Test @MainActor func reopenUnavailableVaultAndSwitchBetweenVaultsFromOpenAndLockedStatesWithoutCrossContamination() async throws {
        let rootA = try makeTempVault(name: "VaultAlpha")
        let rootB = try makeTempVault(name: "VaultBeta")
        let missingRoot = rootA.deletingLastPathComponent().appendingPathComponent("MissingVault", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: rootB.deletingLastPathComponent())
            SourceReader.closeAll()
        }

        let repoA = try FileVaultRepository.open(root: rootA)
        let noteA = try await repoA.create(title: "Alpha Only Page", body: "Alpha body")
        let sourceA = try await repoA.importSource(data: Data("Alpha source".utf8), filename: "alpha.txt", title: "Alpha Source", originURL: nil)

        let repoB = try FileVaultRepository.open(root: rootB)
        let noteB = try await repoB.create(title: "Beta Only Page", body: "Beta body")

        let model = AppModel()
        model.localStorageRoot = rootA.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false

        // Open Vault A and select note + reader window.
        await model.open(rootA, create: false)
        model.select(noteA.id)
        await waitUntil { model.currentNote?.id == noteA.id }
        model.openSource(sourceA.id)
        await waitUntil { SourceReader.openReaderIDs.contains(sourceA.id) }
        let staleTicketFromA = model.issueCompletionTicket(kind: .pageMutation, targetID: noteA.id)

        // Switch A -> B while open.
        await model.open(rootB, create: false)
        #expect(model.isVaultAvailable && !model.isLocked)
        #expect(model.root == rootB && model.vaultName == "VaultBeta")
        #expect(model.notes.map(\.id) == [noteB.id])
        #expect(model.sources.isEmpty)
        #expect(model.currentNote == nil && model.selectedID == nil)
        #expect(SourceReader.openReaderIDs.isEmpty)
        #expect(!model.isCompletionValid(staleTicketFromA, operation: "staleFromA"))

        // Lock Vault B, then switch directly from locked Vault B -> Vault A.
        #expect(await model.lockVault())
        #expect(model.isLocked && model.lockedVaultURL == rootB)
        await model.open(rootA, create: false)
        #expect(model.isVaultAvailable && !model.isLocked)
        #expect(model.root == rootA && model.vaultName == "VaultAlpha")
        #expect(model.notes.map(\.id) == [noteA.id])
        #expect(model.sources.map(\.id) == [sourceA.id])

        // Attempt to switch from open Vault A to an unavailable/non-existent vault -> rolls back to closed with error, no Vault A leakage.
        await model.open(missingRoot, create: false)
        #expect(!model.isVaultAvailable && !model.isLocked && model.sessionPhase == .closed)
        #expect(model.notes.isEmpty && model.sources.isEmpty && model.rows.isEmpty)
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("could not be found") == true)
    }
}
}

private final class LockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}
