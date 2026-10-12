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
        let repository = try FileVaultRepository.open(root: root, create: true)
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

    @Test @MainActor func historySurvivesLockAndReopenButDoesNotMixVaults() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-sidebar-lifecycle-" + UUID().uuidString)
        let root = base.appendingPathComponent("Alpha"), otherRoot = base.appendingPathComponent("Beta")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: base) }
        let repository = try FileVaultRepository.open(root: root, create: true)
        _ = try FileVaultRepository.open(root: otherRoot, create: true)
        let note = try await repository.create(title: "Original title", body: "Body")
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
        #expect(await model.lockVault())
        #expect(model.recentItemIDs.isEmpty && model.sidebarRecentItems.isEmpty)
        #expect(await model.unlockVault())
        #expect(model.recentItemIDs == [.page(note.id)])
        await model.open(otherRoot, create: false)
        #expect(model.recentItemIDs.isEmpty)
        await model.open(root, create: false)
        #expect(model.recentItemIDs == [.page(note.id)])
        let renamed = try await repository.save(note: note, title: "Current title", body: note.body, tags: [])
        await model.refresh()
        #expect(model.sidebarRecentItems.first?.title == renamed.title)
        #expect(await model.closeVault())
        await model.open(root, create: false)
        #expect(model.recentItemIDs == [.page(note.id)])
        #expect(await model.closeVault())
    }
}
}
