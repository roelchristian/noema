import Foundation
import Synchronization
import Testing
@testable import VaultCore
@testable import noema

private final class SearchTestIndex: SearchIndex, Sendable {
    let base: SQLiteSearchIndex
    let hook: @Sendable (String, EntryKind) async throws -> [SearchHit]?
    init(base: SQLiteSearchIndex, hook: @escaping @Sendable (String, EntryKind) async throws -> [SearchHit]?) {
        self.base = base; self.hook = hook
    }
    func cachedEntries() async throws -> ScanBatch { try await base.cachedEntries() }
    func reconcile(_ entries: ScanBatch) async throws { try await base.reconcile(entries) }
    func search(_ query: String, kind: EntryKind, tag: String?) async throws -> [SearchHit] {
        if let hits = try await hook(query, kind) { return hits }
        return try await base.search(query, kind: kind, tag: tag)
    }
    func backlinks(to note: NoteRecord) async throws -> [UUID] { try await base.backlinks(to: note) }
    func outgoingLinks(from pageID: UUID) async throws -> [String] { try await base.outgoingLinks(from: pageID) }
}

extension VaultUIIntegrationTests {
struct SearchModelTests {
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoemaSearchModel-" + UUID().uuidString)
            .appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try FileVaultRepository.open(root: root, create: true)
        return root
    }

    @MainActor private func open(_ root: URL) async -> AppModel {
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        return model
    }

    @Test @MainActor func populatedVaultScopesPreserveQueryLibraryAndDocumentAndKeepExcerpts() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        var metadata = BlockMetadata(); metadata.semantic = "claim"
        let block = EditorBlock(runs: [RichRun("Nebula evidence")], metadata: metadata)
        let page = try await repo.create(title: "Nebula page", body: BlockDocumentCodec.encode(BlockDocument(blocks: [block])))
        let source = try await repo.importSource(data: Data("Nebula original evidence".utf8), filename: "paper.txt", title: "Nebula source", originURL: nil)
        let model = await open(root)
        model.scope = .sources; model.currentNote = page; model.selectedID = page.id
        model.title = page.title; model.body = page.body
        model.searchText = "Nebula"
        await model.updateRows()
        #expect(model.searchStatus == .results)
        #expect(model.visibleSearchResults.totalCount == 3)
        #expect(model.sidebarSearchResults.pageExcerpts[page.id]?.isEmpty == false)
        #expect(model.sidebarSearchResults.sourceExcerpts[source.id]?.isEmpty == false)
        for scope in VaultSearchScope.allCases {
            model.setSearchScope(scope)
            await model.updateRows()
            #expect(model.searchText == "Nebula")
            #expect(model.scope == .sources && model.selectedID == page.id && model.currentNote?.id == page.id)
            #expect(model.visibleSearchResults.totalCount == (scope == .all ? 3 : 1))
        }
        model.setSearchScope(.all)
        let replacement = EditorBlock(id: block.id, runs: [RichRun("Nebula replacement evidence")], metadata: metadata)
        model.body = BlockDocumentCodec.encode(BlockDocument(blocks: [replacement]))
        await model.updateRows()
        #expect(model.visibleSearchResults.blocks.first?.preview == "Nebula replacement evidence")
        #expect(model.semanticRows.first?.preview == "Nebula replacement evidence")
        model.searchText = "no-match-token"
        await model.updateRows()
        #expect(model.searchStatus == .results && model.visibleSearchResults.isEmpty)
        model.searchText = "   "
        await model.updateRows()
        #expect(model.searchStatus == .idle && model.visibleSearchResults.isEmpty)
        #expect(await model.closeVault())
    }

    @Test @MainActor func quickOpenMatchesTitlesAndAliasesButNeverBodiesOrBlocksAndClearsAtLifecycle() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        let page = try await repo.create(title: "Nebula title", body: "Bodyonly nebula text")
        _ = try await repo.create(title: "Other", body: "Nebula body match")
        _ = try await repo.importSource(data: Data("Nebula body match".utf8), filename: "source.txt", title: "Nebula source", originURL: nil)
        let model = await open(root)
        model.searchText = "Nebula"; model.scope = .sources
        model.setSearchMode(.quickOpen)
        await model.updateRows()
        #expect(model.visibleSearchResults.pages.map(\.id) == [page.id])
        #expect(model.visibleSearchResults.sources.count == 1 && model.visibleSearchResults.blocks.isEmpty)
        #expect(model.scope == .sources && model.searchText == "Nebula")
        model.searchText = "Bodyonly"
        await model.updateRows()
        #expect(model.visibleSearchResults.isEmpty)
        model.searchText = ""
        await model.updateRows()
        #expect(model.searchStatus == .results && model.visibleSearchResults.totalCount == 3)
        var aliased = page; aliased.aliases = ["Starlight"]
        #expect(SidebarSearchResults.quickOpen("Starlight", notes: [aliased], sources: []).pages.map(\.id) == [page.id])
        model.setSearchScope(.pages)
        #expect(await model.lockVault())
        #expect(model.searchMode == .vault && model.searchScope == .all && model.searchStatus == .idle)
        #expect(model.searchText.isEmpty && model.visibleSearchResults.isEmpty)
        #expect(await model.unlockVault())
        model.setSearchMode(.quickOpen); await model.updateRows()
        #expect(await model.closeVault())
        #expect(model.searchMode == .vault && model.searchScope == .all && model.searchStatus == .idle)
        #expect(model.visibleSearchResults.isEmpty)
    }

    @Test @MainActor func failedSearchHasItsOwnStateAndDoesNotReplaceDocumentError() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        let page = try await repo.create(title: "Nebula", body: "A searchable page")
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent(); model.persistSecurityScopedBookmark = false
        model.searchIndexFactory = { url, lease, gate in
            SearchTestIndex(base: try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate)) { query, _ in
                if query == "failure" { throw VaultError.storage("Injected search failure") }
                return nil
            }
        }
        await model.open(root, create: false)
        model.errorMessage = "Existing document error"
        model.searchText = "failure"
        await model.updateRows()
        #expect(model.searchStatus == .failed("Injected search failure"))
        #expect(model.visibleSearchResults.isEmpty && model.errorMessage == "Existing document error")
        model.searchText = "Nebula"
        await model.updateRows()
        #expect(model.searchStatus == .results && model.visibleSearchResults.pages.map(\.id) == [page.id])
        model.index = nil; model.searchText = "Nebula"
        await model.updateRows()
        #expect(model.searchStatus == .failed("The vault search index is unavailable."))
        #expect(model.visibleSearchResults.isEmpty && model.errorMessage == "Existing document error")
        #expect(await model.closeVault())
    }

    @Test @MainActor func supersededQueryModeScopeAndSelectionCannotPublishEvenWhenTextReturnsToSameValue() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        let old = try await repo.create(title: "Old", body: "Old body")
        let newer = try await repo.create(title: "Newer", body: "Newer body")
        final class Gate: Sendable {
            let entered = AsyncStream.makeStream(of: Void.self)
            let release = AsyncStream.makeStream(of: Void.self)
            let pause = Mutex(false)
            let fail = Mutex(false)
        }
        let gate = Gate()
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent(); model.persistSecurityScopedBookmark = false
        model.searchIndexFactory = { url, lease, accessGate in
            SearchTestIndex(base: try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: accessGate)) { query, kind in
                guard query == "A", kind == .wiki else { return nil }
                if gate.pause.withLock({ if $0 { $0 = false; return true }; return false }) {
                    gate.entered.continuation.yield(())
                    for await _ in gate.release.stream { break }
                    if gate.fail.withLock({ $0 }) { throw VaultError.storage("Old search failed") }
                    return [SearchHit(id: old.id, kind: .wiki, excerpt: "old")]
                }
                return [SearchHit(id: newer.id, kind: .wiki, excerpt: "new")]
            }
        }
        await model.open(root, create: false)
        var entered = gate.entered.stream.makeAsyncIterator()
        // Each delayed operation ignores cooperative cancellation. In particular,
        // the query returns to A before old A completes, requiring a revision check.
        for transition in 0..<5 {
            model.setSearchMode(.vault); model.setSearchScope(.all); model.searchText = "A"
            gate.pause.withLock { $0 = true }
            gate.fail.withLock { $0 = transition == 4 }
            let pending = Task { @MainActor in await model.updateRows() }
            _ = await entered.next()
            switch transition {
            case 0: model.searchText = "B"; model.searchText = "A"
            case 1: model.searchMode = .quickOpen; model.searchMode = .vault
            case 2: model.searchScope = .pages; model.searchScope = .all
            case 3: model.selectedID = old.id; model.selectedID = newer.id
            default: model.queryChanged()
            }
            await model.updateRows()
            #expect(model.visibleSearchResults.pages.map(\.id) == [newer.id])
            gate.release.continuation.yield(())
            await pending.value
            #expect(model.visibleSearchResults.pages.map(\.id) == [newer.id])
            #expect(model.searchStatus == .results)
        }
        #expect(await model.closeVault())
    }

    @Test(arguments: [0, 1, 2]) @MainActor
    func catalogAndEditorChangesRejectSuspendedResultsBeforeViewRefresh(change: Int) async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        let page = try await repo.create(title: "Snapshot Page", body: "Snapshot original content")
        final class Gate: Sendable {
            let entered = AsyncStream.makeStream(of: Void.self)
            let release = AsyncStream.makeStream(of: Void.self)
            let pause = Mutex(true)
        }
        let gate = Gate()
        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        model.searchIndexFactory = { url, lease, accessGate in
            SearchTestIndex(base: try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: accessGate)) { query, kind in
                guard query == "Snapshot", kind == .wiki,
                      gate.pause.withLock({ if $0 { $0 = false; return true }; return false }) else { return nil }
                gate.entered.continuation.yield(())
                for await _ in gate.release.stream { break }
                return [SearchHit(id: page.id, kind: .wiki, excerpt: "Superseded snapshot")]
            }
        }
        await model.open(root, create: false)
        model.currentNote = page; model.selectedID = page.id
        model.title = page.title; model.body = page.body
        model.searchText = "Snapshot"
        let pending = Task { @MainActor in await model.updateRows() }
        for await _ in gate.entered.stream { break }
        switch change {
        case 0:
            var fresh = page; fresh.body = "Snapshot refreshed catalog"
            model.notes = [fresh]
        case 1: model.body = "Snapshot edited content"
        default: model.title = "Snapshot edited title"
        }
        // No queryChanged()/view refresh runs between the mutation and release.
        gate.release.continuation.yield(())
        await pending.value
        #expect(model.visibleSearchResults.isEmpty)
        #expect(model.searchStatus == .searching)
        await model.updateRows()
        #expect(model.searchStatus == .results)
        #expect(model.visibleSearchResults.pages.map(\.id) == [page.id])
        #expect(await model.closeVault())
    }

    @Test @MainActor func activeSearchKeepsCompleteLibraryRowsFreshAcrossScopeAndContentChanges() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        let match = try await repo.create(title: "Match", body: "Original body")
        let other = try await repo.create(title: "Other", body: "Unrelated content")
        let source = try await repo.importSource(data: Data("Source text".utf8), filename: "source.txt", title: "Unrelated source", originURL: nil)
        let model = await open(root)
        model.searchText = "Match"
        await model.updateRows()
        #expect(Set(model.rows.map(\.id)) == Set([match.id, other.id]))
        #expect(model.visibleSearchResults.pages.map(\.id) == [match.id])
        // A body update can arrive with identical metadata, such as an external
        // edit discovered in the same timestamp interval. Cached excerpts must
        // follow the new catalog snapshot even while a query is active.
        let position = try #require(model.notes.firstIndex { $0.id == match.id })
        model.notes[position].body = "Replacement body"
        await model.updateRows()
        #expect(model.rows.first { $0.id == match.id }?.excerpt == "Replacement body")
        model.currentNote = model.notes[position]; model.selectedID = match.id
        model.title = match.title; model.body = "Unsaved editor body"
        await model.updateRows()
        #expect(model.rows.first { $0.id == match.id }?.excerpt == "Unsaved editor body")
        model.body = "A further editor change"
        await model.updateRows()
        #expect(model.rows.first { $0.id == match.id }?.excerpt == "A further editor change")
        model.scope = .sources
        await model.updateRows()
        #expect(model.rows.map(\.id) == [source.id])
        model.sources[0].metadata.title = "Renamed source"
        await model.updateRows()
        #expect(model.rows.first?.title == "Renamed source")
        model.scope = .tag("missing")
        await model.updateRows()
        #expect(model.rows.isEmpty && model.searchText == "Match")
        model.scope = .wiki
        model.setSearchMode(.quickOpen)
        await model.updateRows()
        #expect(Set(model.rows.map(\.id)) == Set([match.id, other.id]))
        #expect(await model.closeVault())
    }
}
}
