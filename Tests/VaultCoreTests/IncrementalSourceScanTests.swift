import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class IncrementalSourceStoreProbe: VaultContentStore {
    struct State: Sendable {
        var reads: [String: Int] = [:]
        var reliableTokens = true
        var tokenOverride: VaultContentChangeToken?
        var unavailable: Set<String> = []
        var onOriginalRead: (@Sendable () -> Void)?
    }
    let base: PlaintextVaultContentStore
    let state = Mutex(State())
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func synchronize(at path: String) throws { try base.synchronize(at: path) }
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.publishCanonicalOriginal(data, metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalOriginal(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalLinked(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data {
        let hook = state.withLock { state in
            state.reads[path, default: 0] += 1
            return path.contains("/original.") ? state.onOriginalRead : nil
        }
        try rejectUnavailable(path)
        hook?()
        return try base.read(at: path)
    }
    func changeToken(at path: String) throws -> VaultContentChangeToken? {
        try rejectUnavailable(path)
        if let token = state.withLock({ $0.tokenOverride }) { return token }
        return try state.withLock { $0.reliableTokens } ? base.changeToken(at: path) : nil
    }
    private func rejectUnavailable(_ path: String) throws {
        if state.withLock({ $0.unavailable.contains(path) }) { throw VaultContentStoreError.unavailable(path) }
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws { try base.write(data, at: path, condition: condition) }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
    var originalReads: Int { state.withLock { $0.reads.filter { $0.key.contains("/original.") }.values.reduce(0, +) } }
    func reset() { state.withLock { $0.reads = [:] } }
}

struct IncrementalSourceScanTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-incremental-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func sourcePath(_ source: SourceRecord) -> String { "Sources/" + source.id.uuidString.lowercased() + "/" }

    @Test func metadataDiscoveryUnchangedRefreshAndForcedVerification() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        let a = try await repo.importSource(data: Data("Content".utf8), filename: "a.txt", title: "A", originURL: nil)
        let empty = try await repo.importSource(data: Data(), filename: "empty.txt", title: "Empty", originURL: nil)
        store.reset()
        let metadata = try await repo.scanSources()
        #expect(metadata.sources.count == 2)
        #expect(metadata.sources.allSatisfy { $0.contentState == .notLoaded && $0.body.isEmpty })
        #expect(metadata.sourceVerification.values.allSatisfy { $0 == .notVerified })
        #expect(store.originalReads == 0)
        let lazy = try await repo.loadSource(id: a.id)
        #expect(lazy.body == "Content")
        #expect(store.originalReads == 1) // Loading A does not materialize Empty.
        let first = try await repo.scan()
        #expect(first.sources.first { $0.id == empty.id }?.contentState == .loaded)
        #expect(store.originalReads == 2)
        store.reset()
        let reused = try await repo.scan()
        #expect(store.originalReads == 0)
        #expect(reused.sources == first.sources)
        #expect(reused.sourceVerification.values.allSatisfy { $0 == .reusedPreviouslyVerified })
        let verified = try await repo.scan(sourceLoading: .verifyOriginals)
        #expect(store.originalReads == 2)
        #expect(verified.sourceVerification.values.allSatisfy { $0 == .verifiedThisScan })
        store.reset()
        #expect(FileVaultRepository.checkSourceAvailability(a, root: root, contentStore: store) == "Available")
        #expect(store.originalReads == 1) // Explicit availability always reads bytes.
    }

    @Test func metadataAndOriginalChangesUpdateIndexAndIndexCanRebuild() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        let bytes = Data("Alpha discovery".utf8)
        let source = try await repo.importSource(data: bytes, filename: "a.txt", title: "A", originURL: nil)
        let index = try SQLiteSearchIndex(url: root.appendingPathComponent("index.sqlite"))
        try await index.reconcile(repo.scan())
        store.reset()
        let unchanged = try await repo.scanSources()
        #expect(try await index.sourcesRequiringContent(in: unchanged).isEmpty)
        try await index.reconcile(unchanged)
        #expect(store.originalReads == 0)
        #expect(try await index.search("Alpha", kind: .source).map(\.id) == [source.id])
        let renamed = try await repo.renameSource(source, title: "Renamed")
        let changedMetadata = try await repo.scanSources()
        #expect(try await index.sourcesRequiringContent(in: changedMetadata) == [source.id])
        await #expect(throws: (any Error).self) { try await index.reconcile(changedMetadata) }
        try await index.reconcile(repo.scan())
        #expect(store.originalReads == 1)
        #expect(try await index.search("Renamed", kind: .source).map(\.id) == [source.id])
        let rebuilt = try SQLiteSearchIndex(url: root.appendingPathComponent("rebuilt.sqlite"))
        try await rebuilt.reconcile(repo.scan(sourceLoading: .verifyOriginals))
        #expect(try await rebuilt.search("Alpha", kind: .source).map(\.id) == [source.id])
        #expect(try await rebuilt.search("Renamed", kind: .source).map(\.id) == [source.id])
    }

    @Test func unavailableCorruptAndDeletedOriginalsCannotReusePlaintext() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        let bytes = Data("Secret".utf8)
        let source = try await repo.importSource(data: bytes, filename: "a.txt", title: "A", originURL: nil)
        let original = sourcePath(source) + source.metadata.storedFilename
        _ = try await repo.scan()
        #expect(await repo.cachedSourceCount == 1)
        _ = store.state.withLock { $0.unavailable.insert(original) }
        let unavailable = try await repo.scan()
        #expect(unavailable.sources.first?.contentState == .unavailable)
        #expect(unavailable.sources.first?.body.isEmpty == true)
        #expect(await repo.cachedSourceCount == 0)
        await #expect(throws: (any Error).self) { _ = try await repo.loadSource(id: source.id) }
        _ = store.state.withLock { $0.unavailable.remove(original) }
        _ = try await repo.scan()
        try store.base.write(Data("Corrupt".utf8), at: original, condition: .replace(expected: bytes))
        let corrupt = try await repo.scan()
        #expect(corrupt.sources.first?.id == source.id && corrupt.sources.first?.contentState == .unavailable && corrupt.sources.first?.body.isEmpty == true)
        #expect(corrupt.issues.contains { $0.contains("checksum") })
        #expect(await repo.cachedSourceCount == 0)
        #expect(FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: store).contains("checksum"))
        try store.base.delete(at: original, expected: .file(Data("Corrupt".utf8)))
        #expect(try await repo.scan().sources.first?.contentState == .unavailable)
        #expect(await repo.cachedSourceCount == 0)
    }

    @Test func unsupportedEvidenceReloadsAndLinkedContentUpdatesSearch() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        _ = try await repo.importSource(data: Data("Owned".utf8), filename: "a.txt", title: "A", originURL: nil)
        store.state.withLock { $0.reliableTokens = false }
        store.reset()
        _ = try await repo.scan(); _ = try await repo.scan()
        #expect(store.originalReads == 2)
        #expect(await repo.cachedSourceCount == 0)
        let external = root.appendingPathComponent("External.txt")
        try Data("First external word".utf8).write(to: external)
        let linked = try #require(try await repo.linkSources(at: external, maximumFiles: 1).first)
        let index = try SQLiteSearchIndex(url: root.appendingPathComponent("linked.sqlite"))
        let first = try await repo.scan()
        #expect(first.sourceVerification[linked.id] == .linkedContentRead)
        try await index.reconcile(first)
        try Data("Second external phrase".utf8).write(to: external)
        try await index.reconcile(repo.scan())
        #expect(try await index.search("First", kind: .source).isEmpty)
        #expect(try await index.search("Second", kind: .source).map(\.id) == [linked.id])
        try FileManager.default.removeItem(at: external)
        let unavailable = try await repo.scan()
        #expect(unavailable.sources.first { $0.id == linked.id }?.contentState == .unavailable)
        try await index.reconcile(unavailable)
        #expect(try await index.search("Second", kind: .source).isEmpty)
    }

    @Test func deletionAndRestoreDiscardSnapshots() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        let source = try await repo.importSource(data: Data("Owned".utf8), filename: "a.txt", title: "A", originURL: nil)
        _ = try await repo.scan()
        try await repo.deleteSource(source)
        #expect(await repo.cachedSourceCount == 0)
        #expect(try await repo.scan().sources.isEmpty)
        let trashed = try #require(try await repo.trashItems().first)
        try await repo.restore(trashed)
        store.reset()
        #expect(try await repo.scan().sources.map(\.id) == [source.id])
        #expect(store.originalReads == 1)
        // An external directory deletion followed by targeted loading also evicts the snapshot.
        let path = String(sourcePath(source).dropLast())
        try store.base.delete(at: path, expected: store.base.snapshot(at: path))
        await #expect(throws: (any Error).self) { _ = try await repo.loadSource(id: source.id) }
        #expect(await repo.cachedSourceCount == 0)
    }

    @Test func cacheRetiresOnLockCloseAndVaultSwitchAndOldLeaseCannotLoad() async throws {
        let root = try folder(), other = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        _ = try await canonicalSchema5TestRepository(root: root, create: true)
        _ = try await canonicalSchema5TestRepository(root: other, create: true)
        let manager = VaultSessionManager()
        let (_, _, repo) = try await manager.openRepository(root: root)
        let source = try await repo.importSource(data: Data("Secret".utf8), filename: "a.txt", title: "A", originURL: nil)
        _ = try await repo.scan()
        #expect(await repo.cachedSourceCount == 1)
        try await manager.lock()
        #expect(await repo.cachedSourceCount == 0)
        await #expect(throws: (any Error).self) { _ = try await repo.loadSource(id: source.id) }
        let session = try await manager.unlock()
        let fresh = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: manager.accessGate)
        #expect(await fresh.cachedSourceCount == 0)
        _ = try await fresh.scan()
        await #expect(throws: (any Error).self) { _ = try await repo.scanSources() }
        try await manager.close()
        #expect(await fresh.cachedSourceCount == 0)
        _ = try await manager.openRepository(root: other)
        await #expect(throws: (any Error).self) { _ = try await fresh.loadSource(id: source.id) }
        try await manager.close()
        #expect(await fresh.cachedSourceCount == 0)
    }

    @Test func cancelledAndRevokedMidReadNeverPopulateCache() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await canonicalSchema5TestRepository(root: root, create: true)
        let manager = VaultSessionManager()
        let session = try await manager.open(root: root)
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, contentStore: store, sessionLease: session.lease, accessGate: manager.accessGate)
        let source = try await repo.importSource(data: Data("Secret".utf8), filename: "a.txt", title: "A", originURL: nil)
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        store.state.withLock { $0.onOriginalRead = { continuation.yield(()); release.wait() } }
        let pending = Task { try await repo.scan() }
        for await _ in entered { break }
        pending.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(await repo.cachedSourceCount == 0)
        store.state.withLock { $0.onOriginalRead = nil }
        _ = try await repo.scan()
        #expect(await repo.cachedSourceCount == 1)
        let gate = manager.accessGate
        store.state.withLock { $0.onOriginalRead = {
            gate.updateState(.locked(vaultID: session.vaultID, root: session.root, vaultName: root.lastPathComponent, generation: session.generation))
        } }
        await #expect(throws: (any Error).self) { _ = try await repo.loadSource(id: source.id, verifyOriginal: true) }
        #expect(await repo.cachedSourceCount == 0)
        continuation.finish()
    }

    @Test func staleEvidenceNeverClaimsFreshVerificationAndForcedReadRejectsCorruption() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        let bytes = Data("Verified".utf8)
        let source = try await repo.importSource(data: bytes, filename: "a.txt", title: "A", originURL: nil)
        _ = try await repo.scan()
        let original = sourcePath(source) + source.metadata.storedFilename
        let oldToken = try #require(try store.base.changeToken(at: original))
        store.state.withLock { $0.tokenOverride = oldToken }
        try store.base.write(Data("Corrupt".utf8), at: original, condition: .replace(expected: bytes))
        let reused = try await repo.scan()
        #expect(reused.sourceVerification[source.id] == .reusedPreviouslyVerified)
        #expect(try await repo.scanSources().sourceVerification[source.id] == .notVerified)
        let verified = try await repo.scan(sourceLoading: .verifyOriginals)
        #expect(verified.sources.first?.id == source.id && verified.sources.first?.contentState == .unavailable && verified.sources.first?.body.isEmpty == true)
        #expect(verified.issues.contains { $0.contains("checksum") })
        #expect(await repo.cachedSourceCount == 0)
    }

    @Test(arguments: ["lock", "unlock", "close", "switch"])
    func delayedReadCannotPublishAfterSessionTransition(transition: String) async throws {
        let root = try folder(), other = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        _ = try await canonicalSchema5TestRepository(root: root, create: true)
        _ = try await canonicalSchema5TestRepository(root: other, create: true)
        let manager = VaultSessionManager()
        let session = try await manager.open(root: root)
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, contentStore: store, sessionLease: session.lease, accessGate: manager.accessGate)
        let source = try await repo.importSource(data: Data("Session secret".utf8), filename: "a.txt", title: "A", originURL: nil)
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        store.state.withLock { $0.onOriginalRead = { continuation.yield(()); release.wait() } }
        let pending = Task { try await repo.loadSource(id: source.id) }
        for await _ in entered { break }
        if transition == "lock" || transition == "unlock" { try await manager.lock() }
        else { try await manager.close() }
        if transition == "unlock" { _ = try await manager.unlock() }
        if transition == "switch" { _ = try await manager.open(root: other) }
        release.signal()
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        #expect(await repo.cachedSourceCount == 0)
        store.state.withLock { $0.onOriginalRead = nil }
        if transition == "unlock", let current = manager.accessGate.currentLease {
            let fresh = try FileVaultRepository.open(root: root, contentStore: store, sessionLease: current, accessGate: manager.accessGate)
            let original = sourcePath(source) + source.metadata.storedFilename
            _ = store.state.withLock { $0.unavailable.insert(original) }
            await #expect(throws: (any Error).self) { _ = try await fresh.loadSource(id: source.id) }
            #expect(await fresh.cachedSourceCount == 0)
        }
        continuation.finish()
        try await manager.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"))
    func benchmarkSixteenSourceReadCounts() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try IncrementalSourceStoreProbe(root: root)
        let repo = try await canonicalSchema5TestRepository(root: root, create: true, contentStore: store)
        for i in 0..<16 {
            _ = try await repo.importSource(data: Data(String(repeating: "Source \(i) content for indexing.\n", count: 4096).utf8), filename: "\(i).txt", title: "\(i)", originURL: nil)
        }
        let clock = ContinuousClock()
        store.reset()
        let coldStart = clock.now
        _ = try await repo.scan()
        let cold = coldStart.duration(to: clock.now)
        #expect(store.originalReads == 16)
        store.reset()
        let start = clock.now
        for _ in 0..<10 { _ = try await repo.scan() }
        let warm = start.duration(to: clock.now)
        #expect(store.originalReads == 0)
        store.reset()
        let forcedStart = clock.now
        for _ in 0..<10 { _ = try await repo.scan(sourceLoading: .verifyOriginals) }
        let forced = forcedStart.duration(to: clock.now)
        #expect(store.originalReads == 160)
        print("SRC.P4 benchmark: cold scan \(cold), 16 original reads; 10 warm scans \(warm), 0 original reads; 10 forced verification scans \(forced), 160 original reads.")
    }
}
