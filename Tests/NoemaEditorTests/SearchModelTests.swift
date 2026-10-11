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
        let model = await open(root)
        model.errorMessage = "Existing document error"
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
                    return [SearchHit(id: old.id, kind: .wiki, excerpt: "old")]
                }
                return [SearchHit(id: newer.id, kind: .wiki, excerpt: "new")]
            }
        }
        await model.open(root, create: false)
        var entered = gate.entered.stream.makeAsyncIterator()
        // Each delayed operation ignores cooperative cancellation. In particular,
        // the query returns to A before old A completes, requiring a revision check.
        for transition in 0..<4 {
            model.setSearchMode(.vault); model.setSearchScope(.all); model.searchText = "A"
            gate.pause.withLock { $0 = true }
            let pending = Task { @MainActor in await model.updateRows() }
            _ = await entered.next()
            switch transition {
            case 0: model.searchText = "B"; model.searchText = "A"
            case 1: model.searchMode = .quickOpen; model.searchMode = .vault
            case 2: model.searchScope = .pages; model.searchScope = .all
            default: model.selectedID = old.id; model.selectedID = newer.id
            }
            await model.updateRows()
            #expect(model.visibleSearchResults.pages.map(\.id) == [newer.id])
            gate.release.continuation.yield(())
            await pending.value
            #expect(model.visibleSearchResults.pages.map(\.id) == [newer.id])
        }
        #expect(await model.closeVault())
    }
}
}
