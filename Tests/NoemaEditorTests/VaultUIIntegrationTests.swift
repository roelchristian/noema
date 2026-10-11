import Foundation
import Testing
import VaultCore
@testable import noema

// Vault sessions close process-wide SourceReader windows. Serialize only the tests that
// share that lifecycle, including their nested suites, while unrelated tests stay parallel.
@Suite(.serialized)
struct VaultUIIntegrationTests {
    @MainActor private func openRichArticleFixtureVault(at root: URL) async throws -> AppModel {
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent().appendingPathComponent("TestLocalStorage", isDirectory: true)
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        _ = try #require(model.isVaultAvailable)
        return model
    }

    @Test @MainActor func sidebarSearchNavigationPreservesQueryAndScope() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSearchNavigation-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        var metadata = BlockMetadata(); metadata.semantic = "question"
        let block = EditorBlock(runs: [RichRun("Stars question")], metadata: metadata)
        let note = try await repo.create(title: "Stars", body: BlockDocumentCodec.encode(BlockDocument(blocks: [block])))
        let model = try await openRichArticleFixtureVault(at: folder)
        model.scope = .sources; model.searchText = "stars"
        #expect(model.isSearching)
        model.select(note.id, block: block.id)
        for _ in 0..<50 {
            if model.selectedSemanticID != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.currentNote?.id == note.id)
        #expect(model.selectedSemanticID == "\(note.id):\(block.id)")
        #expect(model.scope == .sources)
        #expect(model.searchText == "stars")
        model.searchText = "  \n "
        #expect(!model.isSearching)
        model.searchText = ""
        #expect(!model.isSearching)
        _ = await model.closeVault()
    }

    @Test @MainActor func trashNavigationClearsGlobalSearchAndSelectedDocument() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaTrashNavigation-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Stars", body: "# Stars")
        let model = try await openRichArticleFixtureVault(at: folder)
        model.currentNote = note; model.selectedID = note.id
        model.title = note.title; model.body = note.body; model.tagInput = note.tags.joined(separator: ", ")
        model.searchText = "stars"
        model.changeScope(.trash)
        #expect(model.scope == .trash)
        #expect(!model.isSearching)
        #expect(model.currentNote == nil && model.currentSource == nil && model.selectedID == nil)
        _ = await model.closeVault()
    }

    @Test @MainActor func openingReferencedPageLeavesSourcesAndClearsSearch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaReferencedNavigation-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Referenced", body: "Page body")
        let model = try await openRichArticleFixtureVault(at: folder)
        model.scope = .sources; model.searchText = "unrelated filter"
        model.select(note.id, scope: .wiki)
        for _ in 0..<50 {
            if model.currentNote?.id == note.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.scope == .wiki)
        #expect(model.searchText.isEmpty)
        #expect(model.currentNote?.id == note.id)
        #expect(model.body == note.body)
        _ = await model.closeVault()
    }

    @Test(arguments: [false, true]) @MainActor func editingLockPersistsOnceDuringRapidActions(initiallyLocked: Bool) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaLock-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        var note = try await repo.create(title: "Older", body: "Original")
        note = try await repo.setEditingLock(note: note, locked: initiallyLocked)
        let newer = try await repo.create(title: "Newer", body: "Other")
        let model = try await openRichArticleFixtureVault(at: folder)
        model.notes = [note, newer]
        model.currentNote = note; model.title = note.title; model.body = note.body
        let order = model.allPagesByUpdated.map(\.id)
        let recentOrder = model.recentPages.map(\.id)
        for _ in 0..<20 { model.toggleEditingLock(note.id) }
        #expect(model.editingLockOperations.contains(note.id))
        #expect(model.currentNote?.isEditingLocked == initiallyLocked)
        for _ in 0..<200 {
            if model.editingLockOperations.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.editingLockOperations.isEmpty)
        #expect(model.currentNote?.isEditingLocked == !initiallyLocked)
        #expect(model.currentNote?.updatedAt == note.updatedAt)
        #expect(model.allPagesByUpdated.map(\.id) == order)
        #expect(model.recentPages.map(\.id) == recentOrder)
        #expect(try await repo.scan().notes.first(where: { $0.id == note.id })?.isEditingLocked == !initiallyLocked)
        _ = await model.closeVault()
    }

    @Test @MainActor func editingLockFailurePreservesStateAndAllowsRetry() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaLockFailure-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Page", body: "Original")
        let changed = try await repo.save(note: note, title: note.title, body: "External edit", tags: [])
        let model = try await openRichArticleFixtureVault(at: folder)
        // Keep the editor's original snapshot stale without racing a watcher-triggered refresh.
        model.notes = [note]
        model.currentNote = note; model.title = note.title; model.body = note.body
        model.toggleEditingLock(note.id)
        for _ in 0..<200 {
            if model.editingLockOperations.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.editingLockOperations.contains(note.id))
        #expect(model.currentNote?.isEditingLocked == false)
        #expect(model.notes.first?.contentHash == note.contentHash)
        #expect(model.errorMessage?.contains("Could not change editing lock") == true)
        #expect(try await repo.scan().notes.first?.body == "External edit")
        model.notes = [changed]; model.currentNote = changed; model.body = changed.body
        model.toggleEditingLock(note.id)
        for _ in 0..<200 {
            if model.editingLockOperations.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.currentNote?.isEditingLocked == true)
        _ = await model.closeVault()
    }

    @Test @MainActor func lockingSavesPendingContentBeforePreservingItsTimestamp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaPendingLock-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let note = try await repo.create(title: "Page", body: "Original")
        var old = note; old.updatedAt = "2020-01-01T00:00:00Z"
        try NoteCodec.encode(old).write(to: folder.appendingPathComponent(note.relativePath), options: .atomic)
        let scanned = try #require(try await repo.scan().notes.first)
        let model = try await openRichArticleFixtureVault(at: folder)
        model.notes = [scanned]; model.currentNote = scanned; model.title = scanned.title; model.body = "Pending edit"
        model.toggleEditingLock(note.id)
        for _ in 0..<200 {
            if model.editingLockOperations.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try #require(try await repo.scan().notes.first)
        #expect(saved.isEditingLocked)
        #expect(saved.body == "Pending edit")
        #expect(saved.updatedAt > scanned.updatedAt)
        #expect(model.currentNote?.updatedAt == saved.updatedAt)
        #expect(!model.dirty)
        _ = await model.closeVault()
    }
}
