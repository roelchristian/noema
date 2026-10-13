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

    @Test @MainActor func navigationCapturesDraftBeforeReturningAndPreservesFailureOnOriginalPage() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaOptimistic-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try await openCanonicalAppFixture(root: folder, create: true)
        let first = try await repo.create(title: "First", body: "Original")
        let second = try await repo.create(title: "Second", body: "Destination")
        try await repo.shutdownPageStorage()
        let model = try await openRichArticleFixtureVault(at: folder)
        model.select(first.id)
        model.body = "Captured before navigation"
        // Duplicate title forces a canonical save failure after recovery publication.
        model.title = second.title
        model.select(second.id)
        #expect(model.currentNote?.id == second.id)
        #expect(model.body == second.body)
        model.select(first.id)
        #expect(model.body == "Captured before navigation")
        model.select(second.id)
        for _ in 0..<100 {
            if model.pageSaveFailures[first.id] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pageSaveFailures[first.id] != nil)
        #expect(model.currentNote?.id == second.id)
        #expect(model.recoveredDrafts.contains { $0.id == first.id && BlockDocumentCodec.markdownBody($0.contentBody) == "Captured before navigation" })
        #expect(!(await model.closeVault()))
        _ = await model.closeVault(force: true)
    }

    @Test @MainActor func schemaFiveReopensInAppModelAndPersistsBlockEdits() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSQLiteUI-" + UUID().uuidString).resolvingSymlinksInPath()
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: folder, create: true)
        var metadata = BlockMetadata(); metadata.semantic = "question"; metadata.extra["future"] = "retained"
        let block = EditorBlock(runs: [RichRun("Stars question #astronomy")], metadata: metadata)
        let note = try await repository.create(title: "Stars", body: BlockDocumentCodec.encode(BlockDocument(blocks: [block])))
        let source = try await repository.importSource(data: Data("source text".utf8), filename: "stars.txt", title: "Source", originURL: nil)
        let referenced = try await repository.setSourceReference(note: note, sourceID: source.id, linked: true)
        try await repository.shutdownPageStorage()
        let model = try await openRichArticleFixtureVault(at: folder)
        #expect(model.notes.count == 1)
        #expect(model.notes.first?.id == referenced.id)
        #expect(model.notes.first?.linkedSourceIDs == [source.id])
        model.select(note.id, block: block.id)
        for _ in 0..<50 {
            if model.currentNote?.id == note.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let initial = BlockDocumentCodec.decode(model.body)
        #expect(initial.block(block.id)?.metadata.extra["future"] == "retained")
        var edited = initial
        _ = edited.update(block.id) { $0.runs = [RichRun("Edited stars #cosmos")] }
        model.body = BlockDocumentCodec.encode(edited)
        #expect(await model.saveCurrent())
        #expect(await model.closeVault())
        let reopened = try await openRichArticleFixtureVault(at: folder)
        let saved = try #require(reopened.notes.first)
        #expect(BlockDocumentCodec.decode(saved.body).block(block.id)?.text == "Edited stars #cosmos")
        #expect(saved.inlineTags.contains("cosmos"))
        #expect(saved.linkedSourceIDs == [source.id])
        #expect(await reopened.closeVault())
    }

    @Test @MainActor func sidebarSearchNavigationPreservesQueryAndScope() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSearchNavigation-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try await openCanonicalAppFixture(root: folder, create: true)
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
        let repo = try await openCanonicalAppFixture(root: folder, create: true)
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
        let repo = try await openCanonicalAppFixture(root: folder, create: true)
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
        let repo = try await openCanonicalAppFixture(root: folder, create: true)
        var note = try await repo.create(title: "Older", body: "Original")
        note = try await repo.setEditingLock(note: note, locked: initiallyLocked)
        let newer = try await repo.create(title: "Newer", body: "Other")
        let model = try await openRichArticleFixtureVault(at: folder)
        model.notes = [note, newer]
        model.currentNote = note; model.title = note.title; model.body = note.body
        let order = model.notes.sorted { (LibraryRow.date($0.updatedAt) ?? .distantPast) > (LibraryRow.date($1.updatedAt) ?? .distantPast) }.map(\.id)
        let recentOrder = model.recentItemIDs
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
        #expect(model.notes.sorted { (LibraryRow.date($0.updatedAt) ?? .distantPast) > (LibraryRow.date($1.updatedAt) ?? .distantPast) }.map(\.id) == order)
        #expect(model.recentItemIDs == recentOrder)
        #expect(try await repo.scan().notes.first(where: { $0.id == note.id })?.isEditingLocked == !initiallyLocked)
        _ = await model.closeVault()
    }

    @Test @MainActor func editingLockFailurePreservesStateAndAllowsRetry() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaLockFailure-" + UUID().uuidString)
        let folder = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try await openCanonicalAppFixture(root: folder, create: true)
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
        #expect(BlockDocumentCodec.markdownBody(try #require(try await repo.scan().notes.first).body) == "External edit")
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
        let repo = try await openCanonicalAppFixture(root: folder, create: true)
        let note = try await repo.create(title: "Page", body: "Original")
        // Ensure a distinct timestamp without mutating a retired Markdown file.
        try await Task.sleep(for: .milliseconds(1100))
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
        #expect(BlockDocumentCodec.markdownBody(saved.body) == "Pending edit")
        #expect(saved.updatedAt > scanned.updatedAt)
        #expect(model.currentNote?.updatedAt == saved.updatedAt)
        #expect(!model.dirty)
        _ = await model.closeVault()
    }
}
