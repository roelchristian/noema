import Foundation
import Testing
import VaultCore
@testable import noema

struct SidebarRecentItemsTests {
    @Test func mixedHistoryKeepsTypedIdentityAndAccessOrder() {
        let pageID = UUID(), sourceID = UUID(), blockID = UUID()
        let page = RecentItemID.page(pageID)
        let source = RecentItemID.source(sourceID)
        let block = RecentItemID.semanticBlock(pageID: pageID, blockID: blockID)
        var history = SidebarRecentHistory(ids: [])
        history.record(page)
        history.record(source)
        history.record(block)
        #expect(history.ids == [block, source, page])
        history.record(source)
        #expect(history.ids == [source, block, page])
        #expect(Set(history.ids).count == 3)
    }

    @Test func historyBoundsAndNormalizesPersistedOrder() {
        let ids = (0..<13).map { _ in RecentItemID.page(UUID()) }
        var history = SidebarRecentHistory(ids: [ids[0], ids[0]] + ids.dropFirst())
        #expect(history.ids == Array(ids.prefix(10)))
        history.record(ids[12])
        #expect(history.ids == [ids[12]] + Array(ids.prefix(9)))
        #expect(history.ids.count == 10)
    }

    @Test func pruningPreservesSurvivorOrderWithoutInventingHistory() {
        let page = RecentItemID.page(UUID()), source = RecentItemID.source(UUID())
        let block = RecentItemID.semanticBlock(pageID: UUID(), blockID: UUID())
        var history = SidebarRecentHistory(ids: [source, block, page])
        history.prune(keeping: [page, source])
        #expect(history.ids == [source, page])
        history.prune(keeping: [])
        #expect(history.ids.isEmpty)
        #expect(SidebarRecentHistory(ids: []).ids.isEmpty)
    }

    @Test func presentationKeepsSurvivorsStableWhileHistoryPromotesAndEvicts() {
        var ids = (0..<12).map { _ in RecentItemID.page(UUID()) }
        ids[2] = .source(UUID())
        ids[5] = .semanticBlock(pageID: UUID(), blockID: UUID())
        var history = SidebarRecentHistory(ids: Array(ids.prefix(10)))
        var presentation = SidebarRecentPresentation()
        presentation.reconcile(history.ids)
        for id in [ids[5], ids[2], ids[5]] {
            history.record(id)
            presentation.reconcile(history.ids)
            #expect(presentation.ids == Array(ids.prefix(10)))
            #expect(history.ids.first == id)
        }
        history.record(ids[10])
        presentation.reconcile(history.ids)
        #expect(presentation.ids == Array(ids.prefix(9)) + [ids[10]])
        history.prune(keeping: [ids[2], ids[5], ids[10]])
        presentation.reconcile(history.ids)
        #expect(presentation.ids == [ids[2], ids[5], ids[10]])
        var reopened = SidebarRecentPresentation()
        reopened.reconcile(history.ids)
        #expect(reopened.ids == [ids[10], ids[5], ids[2]])
    }

    @Test func persistenceRoundTripContainsOnlyTypedIdentifiers() throws {
        let ids: [RecentItemID] = [.page(UUID()), .source(UUID()), .semanticBlock(pageID: UUID(), blockID: UUID())]
        let data = try JSONEncoder().encode(ids)
        #expect(try JSONDecoder().decode([RecentItemID].self, from: data) == ids)
        let payload = try #require(String(data: data, encoding: .utf8))
        #expect(!payload.contains("title") && !payload.contains("body") && !payload.contains("path"))
    }
}

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct SidebarRecentItemsNavigationTests {
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test @MainActor func semanticNavigationRecordsOnlyResolvedBlockAndMetadataFocusIsNotAccess() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-sidebar-navigation-" + UUID().uuidString)
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        var metadata = BlockMetadata(); metadata.semantic = "definition"
        let block = EditorBlock(runs: [RichRun("A focused semantic definition")], metadata: metadata)
        let note = try await repository.create(title: "Parent page", body: BlockDocumentCodec.encode(BlockDocument(blocks: [block])))
        let source = try await repository.importSource(data: Data("Source body".utf8), filename: "source.txt", title: "Source", originURL: nil)
        let suite = "SidebarRecentItems-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(aiDefaults: defaults)
        model.sidebarRecentDefaults = defaults
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        #expect(model.recentItemIDs.isEmpty)
        model.sources = try await repository.scanSources().sources
        model.changeScope(.sources)
        model.setLibrarySourceSelection(source.id)
        #expect(model.librarySourceSelection == source.id)
        #expect(model.currentSource == nil)
        #expect(model.recentItemIDs.isEmpty)
        model.openSidebarRecentItem(.source(source.id))
        await waitUntil { model.recentItemIDs == [.source(source.id)] }
        #expect(model.currentSource?.contentState == .loaded)
        #expect(SourceReader.openReaderIDs.contains(source.id))
        let target = RecentItemID.semanticBlock(pageID: note.id, blockID: block.id)
        model.select(note.id, scope: .wiki, block: block.id)
        await waitUntil { model.selectedSemanticID == "\(note.id):\(block.id)" }
        #expect(model.currentNote?.id == note.id)
        #expect(model.editorAction?.operation == .block(block.id))
        #expect(model.recentItemIDs == [target, .source(source.id)])
        model.select(note.id, scope: .wiki, block: UUID())
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.recentItemIDs.contains(.page(note.id)))
        _ = try await repository.save(note: note, title: note.title, body: "The block was removed", tags: [])
        await model.refresh()
        #expect(!model.recentItemIDs.contains(target))
        #expect(!model.sidebarRecentItems.contains { $0.id == target })
        try await repository.deleteSource(source)
        await model.refresh()
        #expect(model.recentItemIDs.isEmpty)
        #expect(await model.closeVault())
    }

    @Test @MainActor func samePageAndBlockSelectionsKeepRowIdentityAndOrder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-sidebar-identity-" + UUID().uuidString)
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        var metadata = BlockMetadata(); metadata.semantic = "definition"
        let block = EditorBlock(runs: [RichRun("Definition")], metadata: metadata)
        let note = try await repository.create(title: "Page", body: BlockDocumentCodec.encode(BlockDocument(blocks: [block])))
        let suite = "SidebarRecentItems-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(aiDefaults: defaults)
        model.localStorageRoot = base; model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(note.id, scope: .wiki)
        let page = RecentItemID.page(note.id), target = RecentItemID.semanticBlock(pageID: note.id, blockID: block.id)
        for id in [target, page, target, target, page] {
            model.openSidebarRecentItem(id)
            #expect(model.selectedSidebarRecentItemID == id)
            #expect(model.currentNote?.id == note.id)
            #expect(model.sidebarRecentItems.map(\.id) == [page, target])
        }
        #expect(model.selectedSemanticID == nil)
        #expect(model.recentItemIDs == [page, target])
        let source = try await repository.importSource(data: Data("Source body".utf8), filename: "source.txt", title: "Source", originURL: nil)
        model.sources = [source]
        model.select(source.id, scope: .sources)
        await waitUntil { model.recentItemIDs.first == .source(source.id) }
        let visible: [RecentItemID] = [page, target, .source(source.id)]
        #expect(model.sidebarRecentItems.map(\.id) == visible)
        model.openSidebarRecentItem(page)
        model.select(source.id, scope: .sources)
        await waitUntil { model.selectedSidebarRecentItemID == .source(source.id) }
        #expect(model.sidebarRecentItems.map(\.id) == visible)
        #expect(await model.closeVault())
        await model.open(root, create: false)
        #expect(model.sidebarRecentItems.map(\.id) == [.source(source.id), page, target])
        #expect(await model.closeVault())
    }

    @Test @MainActor func historySurvivesLockAndReopenButDoesNotMixVaults() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-sidebar-lifecycle-" + UUID().uuidString)
        let root = base.appendingPathComponent("Alpha"), otherRoot = base.appendingPathComponent("Beta")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        _ = try await openCanonicalAppFixture(root: otherRoot, create: true)
        let note = try await repository.create(title: "Original title", body: "Body")
        let second = try await repository.create(title: "Second page", body: "Second body")
        let suite = "SidebarRecentItems-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(aiDefaults: defaults)
        model.sidebarRecentDefaults = defaults
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(note.id, scope: .wiki)
        await waitUntil { model.recentItemIDs == [.page(note.id)] }
        model.openSidebarRecentItem(.page(second.id))
        await waitUntil { model.currentNote?.id == second.id }
        for id in [note.id, second.id, note.id] {
            model.openSidebarRecentItem(.page(id))
            #expect(model.selectedSidebarRecentItemID == .page(id))
            #expect(model.sidebarRecentItems.map(\.id) == [.page(note.id), .page(second.id)])
        }
        #expect(model.recentItemIDs == [.page(note.id), .page(second.id)])
        #expect(await model.lockVault())
        #expect(model.recentItemIDs.isEmpty && model.sidebarRecentItems.isEmpty)
        #expect(await model.unlockVault())
        #expect(model.recentItemIDs == [.page(note.id), .page(second.id)])
        await model.open(otherRoot, create: false)
        #expect(model.recentItemIDs.isEmpty)
        await model.open(root, create: false)
        #expect(model.recentItemIDs == [.page(note.id), .page(second.id)])
        let renamed = try await repository.save(note: note, title: "Current title", body: note.body, tags: [])
        await model.refresh()
        #expect(model.sidebarRecentItems.first?.title == renamed.title)
        #expect(model.sidebarRecentItems.map(\.id) == [.page(note.id), .page(second.id)])
        model.openSidebarRecentItem(.page(second.id))
        #expect(model.sidebarRecentItems.map(\.id) == [.page(note.id), .page(second.id)])
        #expect(await model.closeVault())
        await model.open(root, create: false)
        #expect(model.recentItemIDs == [.page(second.id), .page(note.id)])
        #expect(model.sidebarRecentItems.map(\.id) == model.recentItemIDs)
        #expect(await model.closeVault())
    }
}
}
