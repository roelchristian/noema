import Foundation
import Synchronization
import Testing
@testable import VaultCore
@testable import noema

private enum ReconstructionRaceError: Error { case deadline, signalEnded, injectedIndexFailure }
private enum RefreshOutcome: CaseIterable, Sendable { case cancellation, cancelledTask, failure }

private struct ReconstructionSignal: Sendable {
    private let pair = AsyncStream.makeStream(of: Void.self)
    func signal() { pair.continuation.yield(()) }
    func finish() { pair.continuation.finish() }
    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in pair.stream { return }
                throw ReconstructionRaceError.signalEnded
            }
            group.addTask {
                // Only a deadlock watchdog: signals determine all race ordering.
                try await Task.sleep(for: .seconds(5))
                throw ReconstructionRaceError.deadline
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private final class ReconstructionIndex: SearchIndex, Sendable {
    let base: SQLiteSearchIndex
    let afterCache: (@Sendable () async throws -> Void)?
    let afterCommit: (@Sendable () async throws -> Void)?
    init(base: SQLiteSearchIndex, afterCache: (@Sendable () async throws -> Void)? = nil,
         afterCommit: (@Sendable () async throws -> Void)? = nil) {
        self.base = base; self.afterCache = afterCache; self.afterCommit = afterCommit
    }
    func cachedEntries() async throws -> ScanBatch {
        let entries = try await base.cachedEntries()
        try await afterCache?()
        return entries
    }
    func reconcile(_ entries: ScanBatch) async throws {
        try await base.reconcile(entries)
        // Hold a successful durable result, rather than delaying a write that the gate rejects.
        try await afterCommit?()
    }
    func search(_ query: String, kind: EntryKind, tag: String?) async throws -> [SearchHit] {
        try await base.search(query, kind: kind, tag: tag)
    }
    func backlinks(to note: NoteRecord) async throws -> [UUID] { try await base.backlinks(to: note) }
    func outgoingLinks(from pageID: UUID) async throws -> [String] {
        try await base.outgoingLinks(from: pageID)
    }
}

private final class DelayedOriginalStore: VaultContentStore, Sendable {
    let base: PlaintextVaultContentStore
    let path: String
    let entered = ReconstructionSignal()
    let release = DispatchSemaphore(value: 0)
    let mutations = Mutex(0)
    init(root: URL, path: String) throws { base = try PlaintextVaultContentStore(root: root); self.path = path }
    func read(at path: String) throws -> Data {
        let bytes = try base.read(at: path)
        if path == self.path {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw ReconstructionRaceError.deadline }
        }
        return bytes
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func changeToken(at path: String) throws -> VaultContentChangeToken? { try base.changeToken(at: path) }
    func createDirectory(at path: String) throws {
        mutations.withLock { $0 += 1 }; try base.createDirectory(at: path)
    }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        mutations.withLock { $0 += 1 }; try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        mutations.withLock { $0 += 1 }; try base.move(from: source, to: destination, expected: expected)
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws {
        mutations.withLock { $0 += 1 }; try base.delete(at: path, expected: expected)
    }
}

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct LifecycleReconstructionRaceTests {
    private func fixture() async throws -> (base: URL, root: URL, repository: FileVaultRepository) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reconstruction-race-\(UUID())")
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root, try await openCanonicalAppFixture(root: root, create: true))
    }

    @MainActor private func model(base: URL) -> AppModel {
        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        return model
    }

    @Test @MainActor
    func supersededScheduledRefreshDoesNotPresentAnError() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try await fixture.repository.create(title: "Existing page", body: "Content")
        let model = model(base: fixture.base)
        let phase = Mutex(0)
        let entered = ReconstructionSignal(), release = ReconstructionSignal(), replacement = ReconstructionSignal()
        defer { release.finish() }
        model.searchIndexFactory = { url, lease, gate in
            ReconstructionIndex(base: try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate), afterCommit: {
                let step = phase.withLock { value in
                    let step = value
                    if value > 0 { value += 1 }
                    return step
                }
                if step == 1 {
                    entered.signal()
                    try await release.wait()
                } else if step == 2 {
                    replacement.signal()
                }
            })
        }
        await model.open(fixture.root, create: false)
        #expect(model.errorMessage == nil)
        phase.withLock { $0 = 1 }
        model.scheduleRefresh()
        try await entered.wait()
        // A second file notification cancels the running scheduled refresh.
        model.scheduleRefresh()
        try await replacement.wait()
        #expect(model.errorMessage == nil)
        #expect(model.notes.count == 1)
        #expect(await model.closeVault(force: true))
    }

    @Test(arguments: RefreshOutcome.allCases) @MainActor
    private func semanticEditSurvivesCancelledRefreshAndNavigation(outcome: RefreshOutcome) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let block = EditorBlock(runs: [RichRun("Existing block")])
        let original = BlockDocument(blocks: [block])
        let note = try await fixture.repository.create(title: "Tagged page", body: BlockDocumentCodec.encode(original))
        let other = try await fixture.repository.create(title: "Other page", body: "Other content")
        let model = model(base: fixture.base)
        let armed = Mutex(false)
        model.searchIndexFactory = { url, lease, gate in
            ReconstructionIndex(base: try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate), afterCommit: {
                guard armed.withLock({ if $0 { $0 = false; return true }; return false }) else { return }
                switch outcome {
                case .cancellation: throw CancellationError()
                case .cancelledTask:
                    // Some operations ignore cancellation and return successfully.
                    withUnsafeCurrentTask { $0?.cancel() }
                case .failure: throw ReconstructionRaceError.injectedIndexFailure
                }
            })
        }
        await model.open(fixture.root, create: false)
        model.currentNote = note; model.selectedID = note.id
        model.title = note.title; model.body = note.body
        var tagged = original
        tagged.blocks[0].metadata.semantic = "claim"
        model.body = BlockDocumentCodec.encode(tagged)
        #expect(await model.saveCurrent())
        #expect(model.saveStatus == "Saved locally")
        armed.withLock { $0 = true }
        let refresh = Task { @MainActor in await model.refresh() }
        await refresh.value
        if outcome == .failure {
            #expect(model.errorMessage == ReconstructionRaceError.injectedIndexFailure.localizedDescription)
        } else {
            #expect(model.errorMessage == nil)
        }
        #expect(!model.dirty)
        #expect(model.saveStatus == "Saved locally")
        let persisted = try #require(try await fixture.repository.scan().notes.first { $0.id == note.id })
        #expect(BlockDocumentCodec.decode(persisted.body).block(block.id)?.metadata.semantic == "claim")
        for target in [other.id, note.id] {
            model.select(target)
            for _ in 0..<200 {
                if model.currentNote?.id == target { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.currentNote?.id == target)
        }
        #expect(BlockDocumentCodec.decode(model.body).block(block.id)?.metadata.semantic == "claim")
        #expect(model.errorMessage == nil)
        // A subsequent refresh still succeeds after the canceled operation.
        await model.refresh()
        #expect(model.errorMessage == nil)
        #expect(await model.closeVault(force: true))
    }

    @Test @MainActor
    func delayedCommittedIndexResultCannotPublishIntoReopenedSession() async throws {
        let fixture = try await fixture()
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: fixture.base) }
        // Finish fixture writes before installing the live watcher, so it cannot race
        // the explicit refresh to claim the publication barrier.
        let changed = try await fixture.repository.create(title: "Committed index result", body: "Canonical content")
        let model = model(base: fixture.base)
        let armed = Mutex(false)
        let entered = ReconstructionSignal(), release = ReconstructionSignal(), finished = ReconstructionSignal()
        defer { release.finish() }
        model.searchIndexFactory = { url, lease, gate in
            ReconstructionIndex(base: try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate), afterCommit: {
                guard armed.withLock({ if $0 { $0 = false; return true }; return false }) else { return }
                entered.signal()
                try await release.wait()
            })
        }
        await model.open(fixture.root, create: false)
        let oldSession = try #require(await model.sessionManager.currentSession)
        let canonicalBytes = try await canonicalAppPageSnapshot(fixture.repository, id: changed.id)
        armed.withLock { $0 = true }
        let refresh = Task { @MainActor in defer { finished.signal() }; await model.refresh() }
        defer { refresh.cancel() }
        try await entered.wait()
        #expect(model.notes.first?.title == changed.title)
        #expect(await model.lockVault())
        #expect(model.notes.isEmpty && model.rows.isEmpty)
        #expect(await model.unlockVault())
        let reopened = try #require(await model.sessionManager.currentSession)
        #expect(reopened.generation > oldSession.generation)
        let rowsBeforeCompletion = model.rows.map(\.id)
        release.signal()
        try await finished.wait()
        await refresh.value
        #expect(model.isVaultAvailable && model.sessionState == .open(reopened))
        #expect(model.notes.map(\.id) == [changed.id] && model.notes.first?.body == changed.body)
        #expect(model.rows.map(\.id) == rowsBeforeCompletion)
        #expect(model.staleResultGuard.rejectedRecords.contains { $0.kind == .indexing && $0.operation == "refresh.reconcile" })
        #expect(try await canonicalAppPageSnapshot(fixture.repository, id: changed.id) == canonicalBytes)
        #expect(model.sessionManager.operationRegistrySnapshot().activeCount == 0)
        #expect(await model.sessionManager.inFlightWaiterCount == 0)
        #expect(await model.closeVault(force: true))
    }

    @Test(arguments: [false, true], ["txt", "html", "pdf"]) @MainActor
    func importedReaderCannotPresentAfterFinalPredicateRevokesLease(reopen: Bool, extensionName: String) async throws {
        let fixture = try await fixture()
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: fixture.base) }
        let source = try await fixture.repository.importSource(data: Data("%PDF-1.4\nsynthetic private preview".utf8),
            filename: "private." + extensionName, title: "Private preview", originURL: nil)
        let session = VaultSession(vaultID: UUID(), root: fixture.root, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let store = GatedVaultContentStore(base: try PlaintextVaultContentStore(root: fixture.root), root: fixture.root,
            vaultID: session.vaultID, gate: gate, lease: session.lease)
        let checks = Mutex(0)
        await #expect(throws: VaultAccessError.self) {
            try await SourceReader.open(source, root: fixture.root, contentStore: store, isStillValid: {
                let count = checks.withLock { $0 += 1; return $0 }
                if count == (extensionName == "pdf" ? 3 : 2) {
                    // This predicate intentionally returns true: caller state is not authority.
                    if reopen { gate.updateState(.open(VaultSession(vaultID: session.vaultID, root: session.root, generation: 2))) }
                    else { gate.updateState(.locking(session)) }
                }
                return true
            })
        }
        #expect(checks.withLock { $0 } == (extensionName == "pdf" ? 3 : 2))
        #expect(SourceReader.openReaderIDs.isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor
    func delayedOriginalReadCannotPresentReaderAfterLockOrUnlock(reopen: Bool) async throws {
        let fixture = try await fixture()
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: fixture.base) }
        let original = Data("Private original read before revocation".utf8)
        let source = try await fixture.repository.importSource(data: original, filename: "private.txt", title: "Private", originURL: nil)
        let model = model(base: fixture.base)
        await model.open(fixture.root, create: false)
        let session = try #require(await model.sessionManager.currentSession)
        let path = "Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)"
        let probe = try DelayedOriginalStore(root: fixture.root, path: path)
        defer { probe.release.signal() }
        let store = GatedVaultContentStore(base: probe, root: fixture.root, vaultID: session.vaultID,
                                           gate: model.sessionManager.accessGate, lease: session.lease)
        let finished = ReconstructionSignal()
        let reader = Task { @MainActor in
            defer { finished.signal() }
            try await SourceReader.open(source, root: fixture.root, contentStore: store)
        }
        defer { reader.cancel() }
        try await probe.entered.wait()
        #expect(SourceReader.openReaderIDs.isEmpty)
        #expect(await model.lockVault())
        if reopen { #expect(await model.unlockVault()) }
        probe.release.signal()
        try await finished.wait()
        await #expect(throws: VaultAccessError.self) { try await reader.value }
        #expect(SourceReader.openReaderIDs.isEmpty)
        #expect(model.sessionPhase == (reopen ? .open : .locked))
        #expect(model.sessionManager.accessGate.currentState == model.sessionState)
        #expect(model.sessionManager.operationRegistrySnapshot().activeCount == 0)
        #expect(await model.sessionManager.inFlightWaiterCount == 0)
        #expect(probe.mutations.withLock { $0 } == 0)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(path)) == original)
        #expect(await model.closeVault(force: true))
    }

    @Test @MainActor
    func failedUnlockAfterCentralOpenRollsBackWithoutLosingDirtyRecoveryDraft() async throws {
        let fixture = try await fixture()
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: fixture.base) }
        let note = try await fixture.repository.create(title: "Canonical", body: "Original durable body")
        let canonicalBytes = try await canonicalAppPageSnapshot(fixture.repository, id: note.id)
        let model = model(base: fixture.base)
        await model.open(fixture.root, create: false)
        // Supply a dirty buffer synchronously, avoiding an autosave timer as a race scheduler.
        model.currentNote = note; model.title = "Dirty title"; model.body = "Dirty draft must survive unsuccessful reconstruction"
        model.tagInput = "retained"; model.lccInput = note.lcc ?? ""
        #expect(model.dirty)
        #expect(await model.lockVault(cancelPreCommitSaves: true))
        let draftURL = fixture.base.appendingPathComponent("KnowledgeVault/\(fixture.repository.manifest.id.uuidString)/Drafts/\(note.id.uuidString).json")
        let draftBytes = try Data(contentsOf: draftURL)
        let entered = ReconstructionSignal(), release = ReconstructionSignal(), finished = ReconstructionSignal()
        defer { release.finish() }
        model.searchIndexFactory = { url, lease, gate in
            ReconstructionIndex(base: try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate), afterCache: {
                entered.signal()
                try await release.wait()
                throw ReconstructionRaceError.injectedIndexFailure
            })
        }
        let unlock = Task { @MainActor in defer { finished.signal() }; return await model.unlockVault() }
        defer { unlock.cancel() }
        try await entered.wait()
        let openedBeforeReconstruction = try #require(await model.sessionManager.currentSession)
        #expect(await model.sessionManager.state == .open(openedBeforeReconstruction))
        #expect(!model.isVaultAvailable && model.root == nil && model.index == nil)
        release.signal()
        try await finished.wait()
        #expect(!(await unlock.value))
        #expect(model.isLocked && model.sessionPhase == .locked)
        #expect(model.sessionState == model.sessionManager.accessGate.currentState)
        #expect(model.root == nil && model.index == nil && model.notes.isEmpty && model.body.isEmpty)
        #expect(model.errorMessage != nil && model.sessionTransitionErrors.isEmpty)
        #expect(model.sessionManager.operationRegistrySnapshot().activeCount == 0)
        #expect(await model.sessionManager.inFlightWaiterCount == 0)
        #expect(try await canonicalAppPageSnapshot(fixture.repository, id: note.id) == canonicalBytes)
        #expect(try Data(contentsOf: draftURL) == draftBytes)
        model.searchIndexFactory = { try SQLiteSearchIndex(url: $0, sessionLease: $1, accessGate: $2) }
        #expect(await model.unlockVault())
        let recovered = try #require(model.recoveredDrafts.first)
        #expect(recovered.id == note.id && recovered.title == "Dirty title")
        #expect(recovered.body == "Dirty draft must survive unsuccessful reconstruction" && recovered.tags == ["retained"])
        #expect(model.notes.first?.body == note.body)
        #expect(try await canonicalAppPageSnapshot(fixture.repository, id: note.id) == canonicalBytes)
        #expect(try Data(contentsOf: draftURL) == draftBytes)
        #expect(model.sessionManager.operationRegistrySnapshot().activeCount == 0)
        #expect(await model.closeVault(force: true))
    }
}
}
