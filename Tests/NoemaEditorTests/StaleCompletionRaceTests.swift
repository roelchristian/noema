import Foundation
import Synchronization
import Testing
@testable import VaultCore
@testable import noema

private final class ControlledSearchIndex: SearchIndex, Sendable {
    let base: SQLiteSearchIndex
    private let searchHook: (@Sendable (String, EntryKind, String?) async throws -> [SearchHit]?)?
    private let reconcileHook: (@Sendable (ScanBatch) async throws -> Void)?

    init(
        base: SQLiteSearchIndex,
        searchHook: (@Sendable (String, EntryKind, String?) async throws -> [SearchHit]?)? = nil,
        reconcileHook: (@Sendable (ScanBatch) async throws -> Void)? = nil
    ) {
        self.base = base
        self.searchHook = searchHook
        self.reconcileHook = reconcileHook
    }

    func cachedEntries() async throws -> ScanBatch { try await base.cachedEntries() }
    func reconcile(_ entries: ScanBatch) async throws {
        if let reconcileHook { try await reconcileHook(entries) }
        try await base.reconcile(entries)
    }
    func search(_ query: String, kind: EntryKind, tag: String?) async throws -> [SearchHit] {
        if let searchHook, let custom = try await searchHook(query, kind, tag) { return custom }
        return try await base.search(query, kind: kind, tag: tag)
    }
    func backlinks(to note: NoteRecord) async throws -> [UUID] { try await base.backlinks(to: note) }
}

struct StaleCompletionRaceTests {
    private func makeTempVault(name: String = "Vault") throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-stale-race-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try FileVaultRepository.open(root: root, create: true)
        return root
    }

    @Test func staleResultGuardValidatesSessionIdentityEpochAndTokens() async throws {
        let rootA = try makeTempVault(name: "VaultA")
        let rootB = try makeTempVault(name: "VaultB")
        defer {
            try? FileManager.default.removeItem(at: rootA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: rootB.deletingLastPathComponent())
        }

        let manager = VaultSessionManager()
        let guardService = manager.staleResultGuard
        let (sessionA1, leaseA1, _) = try await manager.openRepository(root: rootA)
        let token1 = UUID(), noteID = UUID()
        let ticketA1 = manager.issueCompletionTicket(kind: .search, lease: leaseA1, token: token1, targetID: noteID, capturedText: "q1")

        #expect(try guardService.requireValid(ticketA1, expectedToken: token1, expectedTargetID: noteID, checkTargetID: true, currentText: "q1") == sessionA1)
        #expect(throws: VaultStaleCompletionError.self) { _ = try guardService.requireValid(ticketA1, expectedToken: UUID()) }
        #expect(throws: VaultStaleCompletionError.self) { _ = try guardService.requireValid(ticketA1, expectedToken: token1, expectedTargetID: UUID(), checkTargetID: true) }
        #expect(throws: VaultStaleCompletionError.self) { _ = try guardService.requireValid(ticketA1, expectedToken: token1, currentText: "q2") }

        try await manager.lock()
        #expect(throws: VaultStaleCompletionError.rejected(kind: .search, operation: "locked", reason: .sessionLocked(vaultID: sessionA1.vaultID, root: sessionA1.root, generation: 1))) {
            _ = try guardService.requireValid(ticketA1, expectedToken: token1, operation: "locked")
        }

        let sessionA2 = try await manager.unlock()
        #expect(throws: VaultStaleCompletionError.rejected(kind: .search, operation: "epoch", reason: .staleEpoch(ticketGeneration: 1, activeGeneration: 2))) {
            _ = try guardService.requireValid(ticketA1, expectedToken: token1, operation: "epoch")
        }

        let ticketA2 = manager.issueCompletionTicket(kind: .aiProcessing, lease: sessionA2.lease, token: token1)
        try await manager.close()
        #expect(throws: VaultStaleCompletionError.rejected(kind: .aiProcessing, operation: "closed", reason: .sessionClosed)) {
            _ = try guardService.requireValid(ticketA2, expectedToken: token1, operation: "closed")
        }

        let (sessionB, _, _) = try await manager.openRepository(root: rootB)
        #expect(throws: VaultStaleCompletionError.rejected(kind: .aiProcessing, operation: "switch", reason: .wrongVault(ticketVaultID: sessionA2.vaultID, ticketRoot: sessionA2.root, activeVaultID: sessionB.vaultID, activeRoot: sessionB.root))) {
            _ = try guardService.requireValid(ticketA2, expectedToken: token1, operation: "switch")
        }
    }

    @Test @MainActor func delayedSearchPreviewSourceIndexingAndAICannotPublishAfterLockCloseOrVaultSwitch() async throws {
        let rootA = try makeTempVault(name: "VaultA")
        let rootB = try makeTempVault(name: "VaultB")
        defer {
            try? FileManager.default.removeItem(at: rootA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: rootB.deletingLastPathComponent())
            SourceReader.closeAll()
        }

        let prevAI = UserDefaults.standard.object(forKey: EditorPreferences.aiSummariesKey)
        UserDefaults.standard.set(true, forKey: EditorPreferences.aiSummariesKey)
        defer {
            if let prevAI { UserDefaults.standard.set(prevAI, forKey: EditorPreferences.aiSummariesKey) }
            else { UserDefaults.standard.removeObject(forKey: EditorPreferences.aiSummariesKey) }
        }

        do {
            let repoA = try FileVaultRepository.open(root: rootA)
            _ = try await repoA.create(title: "Vault A Secret", body: "Confidential body in Vault A")
            _ = try await repoA.importSource(data: Data("Source A text".utf8), filename: "a.txt", title: "Source A", originURL: nil)
            let repoB = try FileVaultRepository.open(root: rootB)
            _ = try await repoB.create(title: "Vault B Public", body: "Public body in Vault B")
        }

        final class Gate: Sendable {
            let entered = AsyncStream.makeStream(of: Void.self)
            let release = AsyncStream.makeStream(of: Void.self)
            let pause = Mutex(false)
        }
        let searchGate = Gate()
        let previewGate = Gate()
        let aiGate = Gate()
        let availGate = Gate()
        let indexGate = Gate()

        let model = AppModel()
        model.localStorageRoot = rootA.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        model.searchIndexFactory = { url, lease, gate in
            let base = try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate)
            return ControlledSearchIndex(
                base: base,
                searchHook: { query, kind, _ in
                    guard kind == .wiki, query == "Shared", searchGate.pause.withLock({ if $0 { $0 = false; return true }; return false }) else { return nil }
                    searchGate.entered.continuation.yield(())
                    for await _ in searchGate.release.stream { break }
                    return [SearchHit(id: UUID(), kind: .wiki, excerpt: "Stale hit")]
                },
                reconcileHook: { _ in
                    guard indexGate.pause.withLock({ if $0 { $0 = false; return true }; return false }) else { return }
                    indexGate.entered.continuation.yield(())
                    for await _ in indexGate.release.stream { break }
                }
            )
        }
        model.previewRenderer = { text in
            if previewGate.pause.withLock({ if $0 { $0 = false; return true }; return false }) {
                previewGate.entered.continuation.yield(())
                for await _ in previewGate.release.stream { break }
                return (MarkdownService.preview("LEAKED: \(text)"), 777)
            }
            return (MarkdownService.preview(text), 3)
        }
        model.aiClient = AppModel.AIProcessingClient(
            unavailabilityReason: { nil },
            summarize: { _ in
                if aiGate.pause.withLock({ if $0 { $0 = false; return true }; return false }) {
                    aiGate.entered.continuation.yield(())
                    for await _ in aiGate.release.stream { break }
                }
                return "STALE AI SUMMARY"
            },
            inferLCC: { _ in "QA76" },
            lccCode: { _ in "QA76" },
            pageTitle: { _ in "Stale Title" },
            pageFromTopic: { _, _ in "Stale Topic" },
            pageFromSource: { _ in "Stale Source" },
            researchTopic: { _ in [] }
        )
        model.sourceAvailabilityChecker = { _, _, _ in
            if availGate.pause.withLock({ if $0 { $0 = false; return true }; return false }) {
                availGate.entered.continuation.yield(())
                for await _ in availGate.release.stream { break }
            }
            return "STALE AVAILABILITY"
        }

        await model.open(rootA, create: false)
        let noteA = try #require(model.notes.first)
        let sourceA = try #require(model.sources.first)
        model.select(noteA.id)
        try await Task.sleep(for: .milliseconds(30))

        // Start delayed search, preview, AI summary, source availability, and index reconcile on Vault A.
        previewGate.pause.withLock { $0 = true }; model.generatePreview()
        for await _ in previewGate.entered.stream { break }

        searchGate.pause.withLock { $0 = true }; model.searchText = "Shared"
        let searchTask = Task { @MainActor in await model.updateRows() }
        for await _ in searchGate.entered.stream { break }

        aiGate.pause.withLock { $0 = true }; model.summarizePage()
        for await _ in aiGate.entered.stream { break }

        availGate.pause.withLock { $0 = true }; model.checkSourceAvailability([sourceA])
        for await _ in availGate.entered.stream { break }

        indexGate.pause.withLock { $0 = true }
        let refreshTask = Task { @MainActor in await model.refresh() }
        for await _ in indexGate.entered.stream { break }

        // Lock Vault A while all 5 async tasks are in flight.
        #expect(await model.lockVault())
        #expect(model.isLocked && model.notes.isEmpty && model.preview.isEmpty && model.sidebarSearchResults.isEmpty)

        // Switch to Vault B with identical searchText, then release all delayed Vault A completions (ignoring cancellation).
        await model.open(rootB, create: false)
        model.searchText = "Shared"
        previewGate.release.continuation.yield(())
        searchGate.release.continuation.yield(())
        aiGate.release.continuation.yield(())
        availGate.release.continuation.yield(())
        indexGate.release.continuation.yield(())
        await searchTask.value; await refreshTask.value
        try await Task.sleep(for: .milliseconds(40))

        #expect(model.notes.map(\.title) == ["Vault B Public"])
        #expect(!model.body.contains("STALE AI SUMMARY"))
        #expect(model.wordCount != 777)
        #expect(model.sourceAvailability[sourceA.id] == nil)
        let rejectedKinds = Set(model.staleResultGuard.rejectedRecords.map(\.kind))
        #expect(rejectedKinds.isSuperset(of: [.search, .preview, .aiProcessing, .sourceLoading, .indexing]))
    }

    @Test @MainActor func rapidLockUnlockCyclesRemainSafe() async throws {
        let root = try makeTempVault(name: "RapidVault")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let repo = try FileVaultRepository.open(root: root)
        _ = try await repo.create(title: "Note", body: "Body")

        let model = AppModel()
        model.localStorageRoot = root.deletingLastPathComponent()
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        for i in 1...4 {
            model.searchText = "q\(i)"; model.queryChanged(); model.generatePreview()
            #expect(await model.lockVault())
            #expect(model.isLocked && model.notes.isEmpty && model.preview.isEmpty)
            #expect(await model.unlockVault())
            #expect(!model.isLocked && model.notes.count == 1)
        }
        await model.closeVault()
        #expect(await model.sessionManager.state == .closed && model.notes.isEmpty)
    }
}
