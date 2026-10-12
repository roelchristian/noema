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

    @MainActor
    private func selectPage(_ page: NoteRecord, in model: AppModel, targets: [String]) async throws {
        model.select(page.id)
        for _ in 0..<100 {
            if model.currentNote?.id == page.id && model.outgoingLinkTargets == targets { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.currentNote?.id == page.id)
        try #require(model.outgoingLinkTargets == targets)
    }

    // Both initialization paths must discard the previous vault's links.
    @Test @MainActor
    func populatedInspectorLinksArePurgedAcrossLockUnlockVaultSwitchAndClose() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-inspector-session-\(UUID())", isDirectory: true)
        let rootA = base.appendingPathComponent("Vault A", isDirectory: true)
        let rootB = base.appendingPathComponent("Vault B", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            SourceReader.closeAll()
            try? FileManager.default.removeItem(at: base)
        }
        let repoA = try FileVaultRepository.open(root: rootA, create: true)
        let pageA = try await repoA.create(title: "Page A", body: "See [[Target A]].")
        let targetA = try await repoA.create(title: "Target A", body: "See [[Page A]].")
        let repoB = try FileVaultRepository.open(root: rootB, create: true)
        let pageB = try await repoB.create(title: "Page B", body: "See [[Only In B]].")

        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        await model.open(rootA, create: false)
        try #require(model.isVaultAvailable)
        try await selectPage(pageA, in: model, targets: ["target a"])
        #expect(model.backlinks.map(\.id) == [targetA.id])

        try #require(await model.lockVault())
        #expect(model.outgoingLinkTargets.isEmpty && model.backlinks.isEmpty)
        #expect(InspectorContext.resolve(model: model, librarySourceSelection: nil) == .none)

        try #require(await model.unlockVault())
        #expect(model.currentNote == nil)
        #expect(model.outgoingLinkTargets.isEmpty && model.backlinks.isEmpty)
        try await selectPage(pageA, in: model, targets: ["target a"])
        #expect(model.backlinks.map(\.id) == [targetA.id])

        await model.open(rootB, create: false)
        try #require(model.isVaultAvailable && model.root == rootB)
        #expect(model.currentNote == nil)
        #expect(model.outgoingLinkTargets.isEmpty && model.backlinks.isEmpty)
        try await selectPage(pageB, in: model, targets: ["only in b"])
        #expect(model.backlinks.isEmpty)

        try #require(await model.closeVault())
        #expect(model.outgoingLinkTargets.isEmpty && model.backlinks.isEmpty)
        #expect(InspectorContext.resolve(model: model, librarySourceSelection: nil) == .none)
    }

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
        await waitUntil(timeoutMs: 4000) {
            if !SourceReader.openReaderIDs.contains(source.id) {
                model.openSource(source.id)
            }
            return SourceReader.openReaderIDs.contains(source.id)
        }
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
        #expect(model.recentItemIDs.isEmpty)
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
        let invalidRoot = rootA.deletingLastPathComponent().appendingPathComponent("InvalidVault", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
        let unsupportedRoot = rootA.deletingLastPathComponent().appendingPathComponent("UnsupportedVault", isDirectory: true)
        try FileManager.default.createDirectory(at: unsupportedRoot, withIntermediateDirectories: true)
        try Data(#"{"id":"00000000-0000-0000-0000-000000000099","formatVersion":99,"createdAt":"2026-10-12T00:00:00Z"}"#.utf8)
            .write(to: unsupportedRoot.appendingPathComponent("vault.json"), options: .atomic)
        let missingRoot = rootA.deletingLastPathComponent().appendingPathComponent("MissingVault", isDirectory: true)
        let unhydratedRoot = try makeTempVault(name: "UnhydratedVault")
        defer {
            try? FileManager.default.removeItem(at: rootA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: rootB.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: unhydratedRoot.deletingLastPathComponent())
            SourceReader.closeAll()
        }

        let repoA = try FileVaultRepository.open(root: rootA)
        let noteA = try await repoA.create(title: "Alpha Only Page", body: "Alpha body")
        let sourceA = try await repoA.importSource(data: Data("Alpha source".utf8), filename: "alpha.txt", title: "Alpha Source", originURL: nil)

        let repoB = try FileVaultRepository.open(root: rootB)
        let noteB = try await repoB.create(title: "Beta Only Page", body: "Beta body")

        let normalizedUnhydrated = unhydratedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let baseProvider = VaultStorageProvider.plaintext
        let provider = VaultStorageProvider { url in
            if url.standardizedFileURL.resolvingSymlinksInPath() == normalizedUnhydrated {
                throw VaultContentStoreError.unavailable("vault.json")
            }
            return try baseProvider.makeStore(root: url)
        }

        let denyBetaScope = LockFlag(false)
        let model = AppModel(storageProvider: provider)
        model.localStorageRoot = rootA.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        model.requiresSecurityScopedAccess = true
        model.securityScopeAcquirer = { url in
            if denyBetaScope.get(), url.standardizedFileURL.resolvingSymlinksInPath() == rootB.standardizedFileURL.resolvingSymlinksInPath() {
                return false
            }
            return true
        }

        // Open Vault A and select note + reader window.
        await model.open(rootA, create: false)
        model.select(noteA.id)
        await waitUntil { model.currentNote?.id == noteA.id }
        await waitUntil(timeoutMs: 4000) {
            if !SourceReader.openReaderIDs.contains(sourceA.id) {
                model.openSource(sourceA.id)
            }
            return SourceReader.openReaderIDs.contains(sourceA.id)
        }
        let ticketFromA = model.issueCompletionTicket(kind: .pageMutation, targetID: noteA.id)
        let indexFromA = try #require(model.index)

        // 1. A -> invalid B (missing vault.json and unsupported formatVersion): preserves open Vault A, repository, index, editor, and reader window.
        await model.open(invalidRoot, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.sessionPhase == .open)
        #expect(model.root == rootA && model.vaultName == "VaultAlpha")
        #expect(model.notes.map(\.id) == [noteA.id] && model.sources.map(\.id) == [sourceA.id])
        #expect(model.currentNote?.id == noteA.id && SourceReader.openReaderIDs.contains(sourceA.id))
        #expect(model.isCompletionValid(ticketFromA, operation: "stillValidOnA"))
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("vault.json") == true)

        await model.open(unsupportedRoot, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.sessionPhase == .open && model.root == rootA)
        #expect(model.notes.map(\.id) == [noteA.id] && model.sources.map(\.id) == [sourceA.id])
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("unsupported format version") == true)

        // 2. A -> unavailable B (missing folder, unhydrated iCloud manifest, and denied security scope): preserves open Vault A.
        await model.open(missingRoot, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.sessionPhase == .open && model.root == rootA)
        #expect(model.notes.map(\.id) == [noteA.id] && model.sources.map(\.id) == [sourceA.id])
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("could not be found") == true)

        await model.open(unhydratedRoot, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.sessionPhase == .open && model.root == rootA)
        #expect(model.notes.map(\.id) == [noteA.id] && model.sources.map(\.id) == [sourceA.id])
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("iCloud") == true)

        denyBetaScope.set(true)
        await model.open(rootB, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.sessionPhase == .open && model.root == rootA)
        #expect(model.notes.map(\.id) == [noteA.id] && !model.needsPermissionReauthorization)
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("Reselect your vault folder") == true)
        denyBetaScope.set(false)
        #expect(try await indexFromA.cachedEntries().notes.map(\.id) == [noteA.id])

        // 3. A -> B success: tears down A and opens B without cross-vault content leakage.
        await model.open(rootB, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.sessionPhase == .open)
        #expect(model.root == rootB && model.vaultName == "VaultBeta")
        #expect(model.notes.map(\.id) == [noteB.id] && model.sources.isEmpty)
        #expect(model.currentNote == nil && model.selectedID == nil)
        #expect(SourceReader.openReaderIDs.isEmpty)
        #expect(!model.isCompletionValid(ticketFromA, operation: "staleFromA"))

        // Lock Vault B, verify locked B -> missing destination preserves locked B, then switch locked B -> Vault A.
        #expect(await model.lockVault())
        #expect(model.isLocked && model.lockedVaultURL == rootB)
        await model.open(missingRoot, create: false)
        #expect(model.isLocked && model.lockedVaultURL == rootB && model.sessionPhase == .locked)
        await model.open(rootA, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.root == rootA)
        #expect(model.notes.map(\.id) == [noteA.id] && model.sources.map(\.id) == [sourceA.id])

        // 4. Failure during B's index initialisation after transition begins:
        // Rolls back cleanly to documented recoverable .closed state with zero A or B content leakage.
        let failIndexInit = LockFlag(true)
        let defaultFactory = model.searchIndexFactory
        model.searchIndexFactory = { url, lease, gate in
            if failIndexInit.get() {
                throw VaultError.storage("Simulated SQLite index init failure for VaultBeta.")
            }
            return try defaultFactory(url, lease, gate)
        }
        await model.open(rootB, create: false)
        #expect(!model.isVaultAvailable && !model.isLocked && model.sessionPhase == .closed)
        #expect(await model.sessionManager.state == .closed)
        #expect(model.root == nil && model.lockedVaultURL == nil && model.vaultName == "Noema" && model.index == nil && !model.busy)
        #expect(model.notes.isEmpty && model.sources.isEmpty && model.rows.isEmpty && model.currentNote == nil)
        #expect(SourceReader.openReaderIDs.isEmpty)
        #expect(model.errorMessage?.localizedCaseInsensitiveContains("Simulated SQLite index init failure") == true)

        // Recover from .closed state by reopening Vault B.
        failIndexInit.set(false)
        await model.open(rootB, create: false)
        #expect(model.isVaultAvailable && !model.isLocked && model.root == rootB)
        #expect(model.notes.map(\.id) == [noteB.id] && model.errorMessage == nil)
    }

    @Test @MainActor func rejectedConcurrentCloseAndUnlockRetainOpenResourcesUntilLockCommits() async throws {
        let root = try makeTempVault(name: "RejectedTransitions")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        let note = try await repo.create(title: "Retained", body: "Recoverable content")
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        let retainedIndex = try #require(model.index as? SQLiteSearchIndex)
        let release = AsyncStream.makeStream(of: Void.self)
        let lock = Task {
            try await model.sessionManager.lock { _ in
                for await _ in release.stream { break }
            }
        }
        await waitUntil { model.sessionManager.accessGate.currentState.phase == .locking }
        #expect(!(await model.closeVault(force: true)))
        #expect(model.sessionTransitionErrors == [.transitionInProgress(current: .locking, requested: "close")])
        #expect(model.root == root && model.notes.map(\.id) == [note.id])
        #expect((model.index as? SQLiteSearchIndex) === retainedIndex)
        #expect(!(await model.unlockVault(using: root)))
        #expect(model.sessionTransitionErrors == [.transitionInProgress(current: .locking, requested: "unlock")])
        #expect(model.sessionPhase == .locking && model.root == root)
        release.continuation.yield(())
        release.continuation.finish()
        try await lock.value
        await waitUntil { model.sessionPhase == .locked }
        #expect(model.isLocked && model.root == nil && model.notes.isEmpty)
        #expect(await model.unlockVault())
        #expect(model.isVaultAvailable && model.notes.map(\.id) == [note.id])
    }

    @Test(arguments: [false, true]) @MainActor
    func cancelledCloseReportsTypedFailureAndRetainsResources(force: Bool) async throws {
        let root = try makeTempVault(name: "CancelledClose")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        let index = try #require(model.index as? SQLiteSearchIndex)
        let release = AsyncStream.makeStream(of: Void.self)
        let closing = Task { @MainActor in
            for await _ in release.stream { break }
            return await model.closeVault(force: force)
        }
        closing.cancel()
        release.continuation.finish()
        #expect(!(await closing.value))
        #expect(model.sessionTransitionErrors == [.cancelled(action: "close")])
        #expect(model.errorMessage != nil)
        #expect(model.isVaultAvailable && model.sessionPhase == .open && model.root == root)
        #expect((model.index as? SQLiteSearchIndex) === index)
        #expect(await model.closeVault(force: force))
        #expect(model.sessionPhase == .closed && model.root == nil && model.errorMessage == nil)
    }

    @Test @MainActor func overlappingModelLockCloseAndUnlockCannotReportFalseSuccess() async throws {
        let root = try makeTempVault(name: "OverlappingActions")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        let admission = try model.sessionManager.admitOperation("hold-lock")
        let locking = Task { await model.lockVault() }
        await waitUntil { model.sessionManager.accessGate.currentState.phase == .locking }
        #expect(!(await model.closeVault(force: true)))
        #expect(!(await model.unlockVault(using: root)))
        #expect(!(await model.lockVault()))
        #expect(model.sessionPhase == .locking && model.root == root)
        admission.complete()
        #expect(await locking.value)
        #expect(model.sessionPhase == .locked && model.isLocked && model.root == nil)
        #expect(await model.closeVault())
        #expect(model.sessionPhase == .closed && !model.isLocked)
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func initializationFailureReportsRejectedCleanupAndUsesOnlyCentralFallbackState(unlocking: Bool, concurrentLock: Bool) async throws {
        let root = try makeTempVault(name: "InitializationFailure")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        if unlocking {
            await model.open(root, create: false)
            #expect(await model.lockVault())
        }
        let entered = LockFlag(false)
        let releaseInitialization = AsyncStream.makeStream(of: Void.self)
        model.searchIndexFactory = { url, lease, gate in
            let base = try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate)
            return InitializationIndexProbe(base: base) {
                entered.set(true)
                for await _ in releaseInitialization.stream { break }
                throw VaultError.storage("Injected initialization failure")
            }
        }
        let initialization = Task {
            if unlocking { return await model.unlockVault() }
            await model.open(root, create: false)
            return model.isVaultAvailable
        }
        defer { releaseInitialization.continuation.finish() }
        await waitUntil { entered.get() || model.errorMessage != nil }
        try #require(entered.get(), "Initialization hook did not run: \(model.errorMessage ?? "no error")")
        let releaseLock = AsyncStream.makeStream(of: Void.self)
        let lockEntered = LockFlag(false)
        var lock: Task<Void, Error>?
        if concurrentLock {
            lock = Task {
                try await model.sessionManager.lock { _ in
                    lockEntered.set(true)
                    for await _ in releaseLock.stream { break }
                }
            }
            await waitUntil { lockEntered.get() }
            try #require(lockEntered.get(), "External lock did not reach teardown")
        }
        defer { releaseLock.continuation.finish() }
        releaseInitialization.continuation.finish()
        #expect(!(await initialization.value))
        #expect(model.root == nil && model.index == nil && model.notes.isEmpty)
        #expect(model.errorMessage?.contains("Injected initialization failure") == true)
        if concurrentLock {
            #expect(model.sessionTransitionErrors == [.transitionInProgress(current: .locking, requested: unlocking ? "lock" : "close")])
            #expect(model.errorMessage?.contains("Cleanup failed:") == true)
            #expect(model.sessionPhase == .locking && !model.isLocked)
            releaseLock.continuation.finish()
            try await lock?.value
            await waitUntil { model.sessionPhase == .locked }
        } else {
            #expect(model.sessionTransitionErrors.isEmpty)
            #expect(model.sessionPhase == (unlocking ? .locked : .closed))
            #expect(model.isLocked == unlocking)
        }
        #expect(await model.closeVault(force: true))
        #expect(model.sessionPhase == .closed && !model.isLocked)
    }

    @Test(arguments: [false, true]) @MainActor
    func failedDerivedIndexInitializationPreservesCanonicalBytesAndRetriesLifecycle(unlocking: Bool) async throws {
        let root = try makeTempVault(name: "IndexInitializationRetry")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        let note = try await repo.create(title: "Retained", body: "Canonical content survives derived failures")
        let manifestURL = root.appendingPathComponent("vault.json")
        let pageURL = root.appendingPathComponent(note.relativePath)
        let manifestBytes = try Data(contentsOf: manifestURL)
        let pageBytes = try Data(contentsOf: pageURL)
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        if unlocking {
            await model.open(root, create: false)
            try #require(await model.lockVault())
        }
        let factory = model.searchIndexFactory
        model.searchIndexFactory = { _, _, _ in throw VaultError.storage("Injected derived index initialization failure") }
        if unlocking { #expect(!(await model.unlockVault())) }
        else { await model.open(root, create: false) }
        #expect(model.sessionPhase == (unlocking ? .locked : .closed))
        #expect(model.sessionState == model.sessionManager.accessGate.currentState)
        #expect(model.root == nil && model.index == nil && model.notes.isEmpty)
        #expect(model.errorMessage?.contains("Injected derived index") == true)
        #expect(try Data(contentsOf: manifestURL) == manifestBytes)
        #expect(try Data(contentsOf: pageURL) == pageBytes)
        model.searchIndexFactory = factory
        if unlocking { try #require(await model.unlockVault()) }
        else { await model.open(root, create: false) }
        #expect(model.isVaultAvailable && model.sessionPhase == .open && model.errorMessage == nil)
        #expect(model.notes.contains { $0.id == note.id && $0.body == note.body })
        #expect(try Data(contentsOf: manifestURL) == manifestBytes)
        #expect(try Data(contentsOf: pageURL) == pageBytes)
        #expect(await model.closeVault())
    }

    @Test @MainActor func endToEndProtectedOperationEntryPointsAndRecoveryAndSourceReaderAreEnforcedAcrossSessionLifecycle() async throws {
        let root = try makeTempVault(name: "D027ReleaseGateVault")
        let linkedURL = root.deletingLastPathComponent().appendingPathComponent("external-linked.txt")
        try Data("Linked external source body".utf8).write(to: linkedURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            SourceReader.closeAll()
        }

        let repo = try FileVaultRepository.open(root: root)
        let note = try await repo.create(title: "Protected Page", body: "Sensitive page body for D02.7")
        let importedSource = try await repo.importSource(
            data: Data("Sensitive imported source body".utf8),
            filename: "imported.txt",
            title: "Imported Source",
            originURL: nil
        )

        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false

        await model.open(root, create: false)
        #expect(model.isVaultAvailable && !model.isLocked)

        // Retain actor/service references from the open generation (G1) to test direct-actor bypass prevention.
        let openSession = try #require(await model.sessionManager.currentSession)
        let gate = model.sessionManager.accessGate
        let leaseG1 = VaultSessionLease(session: openSession)
        let retainedRecovery = try RecoveryStore(
            directory: root.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true),
            sessionLease: leaseG1,
            accessGate: gate
        )
        let retainedIndex = try #require(model.index)
        let retainedStore = GatedVaultContentStore(
            base: try PlaintextVaultContentStore(root: root),
            root: root,
            vaultID: openSession.vaultID,
            gate: gate,
            lease: leaseG1
        )

        // While open, sourceSummaryContent and RecoveryStore work with valid G1 lease.
        let openSummaryContent = try await model.sourceSummaryContent(importedSource, root: root)
        #expect(openSummaryContent.contains("Sensitive imported source body"))
        #expect(try await retainedRecovery.drafts().isEmpty)

        // Lock the vault.
        #expect(await model.lockVault())
        #expect(model.isLocked && !model.isVaultAvailable && model.sessionPhase == .locked)

        // 1. RecoveryStore retained reference must reject drafts/remove while locked.
        await #expect(throws: VaultAccessError.self) {
            _ = try await retainedRecovery.drafts()
        }
        await #expect(throws: VaultAccessError.self) {
            try await retainedRecovery.remove(note.id)
        }

        // 2. SQLiteSearchIndex and GatedVaultContentStore retained references must reject access while locked.
        await #expect(throws: VaultAccessError.self) {
            _ = try await retainedIndex.cachedEntries()
        }
        #expect(throws: VaultAccessError.self) {
            try retainedStore.validateAccess(operation: "test.readPage")
        }

        // 3. SourceReader.open direct entry point (even without an AppModel isStillValid closure) must reject while locked.
        await #expect(throws: VaultAccessError.self) {
            try await SourceReader.open(importedSource, root: root, contentStore: retainedStore)
        }
        #expect(SourceReader.openReaderIDs.isEmpty)

        // 4. AppModel.sourceSummaryContent must reject even when SourceRecord.body is already populated in memory.
        await #expect(throws: (any Error).self) {
            _ = try await model.sourceSummaryContent(importedSource, root: root)
        }

        // 5. Protected AppModel entry points must no-op cleanly while locked without mutating disk or leaking state.
        model.newPage()
        _ = await model.createPageFromTopic("Locked Topic")
        model.createPageFromSource(importedSource)
        model.trashPage(note.id)
        model.deleteAISummary()
        model.summarizePage()
        model.refreshPageLCC()
        model.refreshSourceLCC(importedSource)
        model.generateSourceSummary(importedSource)
        model.openSource(importedSource.id)
        await model.addSourceFiles([linkedURL], shouldImport: true)
        _ = await model.addURLSources("https://example.com/locked-test")
        model.reloadDiskVersion()
        model.saveDraftAsNewPage()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(model.isLocked && !model.isVaultAvailable)
        #expect(model.notes.isEmpty && model.sources.isEmpty && model.rows.isEmpty)
        #expect(model.currentNote == nil && model.currentSource == nil)
        #expect(SourceReader.openReaderIDs.isEmpty)

        // Unlock into generation G2 and verify old G1 retained RecoveryStore reference is rejected as staleSessionGeneration.
        #expect(await model.unlockVault())
        #expect(model.isVaultAvailable && !model.isLocked && model.sessionPhase == .open)
        #expect(model.notes.map(\.id) == [note.id])
        #expect(model.sources.map(\.id) == [importedSource.id])

        await #expect(throws: VaultAccessError.self) {
            _ = try await retainedRecovery.drafts()
        }
    }
}
}

private final class InitializationIndexProbe: SearchIndex, Sendable {
    let base: SQLiteSearchIndex
    let initialize: @Sendable () async throws -> Void
    init(base: SQLiteSearchIndex, initialize: @escaping @Sendable () async throws -> Void) {
        self.base = base
        self.initialize = initialize
    }
    func cachedEntries() async throws -> ScanBatch {
        try await initialize()
        return try await base.cachedEntries()
    }
    func reconcile(_ entries: ScanBatch) async throws { try await base.reconcile(entries) }
    func search(_ query: String, kind: EntryKind, tag: String?) async throws -> [SearchHit] {
        try await base.search(query, kind: kind, tag: tag)
    }
    func backlinks(to note: NoteRecord) async throws -> [UUID] { try await base.backlinks(to: note) }
    // UI.R.REM01: Preserve the complete SearchIndex contract in initialization fixtures.
    func outgoingLinks(from pageID: UUID) async throws -> [String] {
        try await base.outgoingLinks(from: pageID)
    }
}

private final class LockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}
