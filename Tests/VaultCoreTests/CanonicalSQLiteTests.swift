import Foundation
import SQLite3
import Testing
@testable import VaultCore

private func canonicalTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-sqlite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func canonicalSQL(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw VaultError.storage("Test database open failed.") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(db))) }
}

private func canonicalSQLInteger(_ url: URL, _ sql: String) throws -> Int {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw VaultError.storage("Test database open failed.") }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else { throw VaultError.storage(String(cString: sqlite3_errmsg(db))) }
    return Int(sqlite3_column_int(statement, 0))
}

private func canonicalNote(_ id: UUID, sources: [UUID] = []) -> NoteRecord {
    var note = NoteRecord(id: id, title: "Canonical page", aliases: [], tags: [], inlineTags: [],
        createdAt: "2026-10-12", updatedAt: "2026-10-12", body: "", relativePath: "sqlite/\(id.uuidString)", contentHash: "", originalHeader: nil)
    note.sourceIDs = sources
    return note
}

@Test func canonicalSQLiteRequiresExplicitIdentityAndAuthorityWithoutUpgradingPageOnlyStores() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let legacy = try SQLiteBlockStore(unguardedTestingURL: url)
    let pageID = UUID()
    let before = try await legacy.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("authoritative legacy")])]), pageID: pageID, condition: .createOnly)
    try await legacy.close()
    #expect(throws: VaultError.self) { try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID, createIfMissing: false) }
    #expect(try canonicalSQLInteger(url, "PRAGMA user_version") == 2)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM sqlite_master WHERE name='vault_state'") == 0)
    let reopened = try SQLiteBlockStore(unguardedTestingURL: url, createIfMissing: false)
    #expect(try await reopened.load(pageID: pageID) == before)
    try await reopened.close()

    let canonicalURL = root.appendingPathComponent("canonical.sqlite")
    let canonical = try SQLiteBlockStore(canonicalStagingURL: canonicalURL, vaultID: vaultID)
    try await canonical.close()
    #expect(try canonicalSQLInteger(canonicalURL, "PRAGMA user_version") == 3)
    #expect(throws: VaultError.self) { try SQLiteBlockStore(unguardedTestingURL: canonicalURL, createIfMissing: false) }
    #expect(throws: VaultError.self) { try SQLiteBlockStore(canonicalStagingURL: canonicalURL, vaultID: UUID(), createIfMissing: false) }
    #expect(throws: VaultError.self) { try SQLiteBlockStore(canonicalStagingURL: canonicalURL, vaultID: vaultID, requiredCapabilities: ["futureRequired"], createIfMissing: false) }
    let admitted = try SQLiteBlockStore(canonicalStagingURL: canonicalURL, vaultID: vaultID, createIfMissing: false)
    try await admitted.close()
}

@Test func canonicalSQLiteSourceOrderIsRelationalAndUnavailableIdentitiesSurviveReopen() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID(), pageID = UUID()
    let store = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID)
    let sourceIDs = [UUID(), UUID()]
    for id in sourceIDs {
        _ = try await store.publishSourceAndPage(source: CanonicalSource(id: id), condition: .createOnly,
            operationID: UUID(), expectedVaultRevision: try await store.canonicalVaultRevision())
    }
    let initial = try await store.savePage(record: canonicalNote(pageID, sources: sourceIDs),
        document: BlockDocument(blocks: [EditorBlock(runs: [RichRun("linked content")])]), condition: .createOnly)
    #expect(try await store.loadPage(pageID: pageID).record.sourceIDs == sourceIDs)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM page_sources") == 2)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM sources WHERE ownership='unavailable'") == 2)
    let reordered = try await store.savePage(record: canonicalNote(pageID, sources: Array(sourceIDs.reversed())),
        document: initial.document, condition: .replace(expected: initial.revision))
    #expect(reordered.revision != initial.revision)
    try await store.close()
    let reopened = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopened.loadPage(pageID: pageID).record.sourceIDs == Array(sourceIDs.reversed()))
    #expect(try await reopened.load(pageID: pageID) == reordered)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM pragma_foreign_key_check") == 0)
    try await reopened.close()
}

@Test func canonicalSQLiteMissingRelationshipAndCompoundFailureRollBackAllAuthorities() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), pageID = UUID(), sourceID = UUID()
    let store = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID())
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("committed")])])
    let initial = try await store.savePage(record: canonicalNote(pageID), document: document, condition: .createOnly)
    let vaultBefore = try await store.canonicalVaultRevision()
    await #expect(throws: VaultError.self) {
        try await store.savePage(record: canonicalNote(pageID, sources: [UUID()]), document: document, condition: .replace(expected: initial.revision))
    }
    #expect(try await store.load(pageID: pageID) == initial)
    #expect(try await store.canonicalVaultRevision() == vaultBefore)
    try canonicalSQL(url, "CREATE TRIGGER reject_link BEFORE INSERT ON page_sources BEGIN SELECT RAISE(ABORT,'injected relational failure'); END;")
    await #expect(throws: VaultError.self) {
        try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID), condition: .createOnly,
            page: CanonicalPagePublication(record: canonicalNote(pageID, sources: [sourceID]), document: document, condition: .replace(expected: initial.revision)),
            operationID: UUID(), expectedVaultRevision: vaultBefore)
    }
    #expect(try await store.load(pageID: pageID) == initial)
    #expect(try await store.canonicalVaultRevision() == vaultBefore)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM sources") == 0)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM page_sources") == 0)
    try await store.close()
}

@Test func canonicalSQLiteCompoundWritesCheckPageAndCollectionRevisions() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), sourceID = UUID(), pageID = UUID()
    let store = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID())
    let vaultBefore = try await store.canonicalVaultRevision()
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("published together")])])
    _ = try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID), condition: .createOnly,
        page: CanonicalPagePublication(record: canonicalNote(pageID, sources: [sourceID]), document: document, condition: .createOnly),
        operationID: UUID(), expectedVaultRevision: vaultBefore)
    let committed = try await store.loadPage(pageID: pageID)
    #expect(committed.record.sourceIDs == [sourceID])
    #expect(committed.snapshot.document == document)
    #expect(try await store.canonicalVaultRevision() != vaultBefore)
    await #expect(throws: VaultError.self) {
        try await store.publishSourceAndPage(source: CanonicalSource(id: UUID()), condition: .createOnly,
            operationID: UUID(), expectedVaultRevision: vaultBefore)
    }
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM sources") == 1)
    #expect(try await store.load(pageID: pageID) == committed.snapshot)
    try await store.close()
}

@Test func canonicalSQLitePurgeRestrictsReferencedSourcesAndNeverReusesDeletedIdentities() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), sourceID = UUID(), pageID = UUID()
    let store = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID())
    let outcome = try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID), condition: .createOnly,
        page: CanonicalPagePublication(record: canonicalNote(pageID, sources: [sourceID]),
            document: BlockDocument(blocks: [EditorBlock(runs: [RichRun("retained relationship")])]), condition: .createOnly),
        operationID: UUID(), expectedVaultRevision: try await store.canonicalVaultRevision())
    let trashedSource = try await store.setSourceTrashed(id: sourceID, expected: outcome.sourceRevision, trashed: true)
    let trashedPage = try await store.setTrashed(pageID: pageID, expected: try #require(outcome.pageRevision), trashed: true)
    #expect(try await store.loadPage(pageID: pageID).record.sourceIDs == [sourceID])
    let vaultBefore = try await store.canonicalVaultRevision()
    await #expect(throws: VaultError.self) {
        try await store.purgeCanonicalEntity(id: sourceID, kind: .source, expected: trashedSource.revision, expectedVaultRevision: vaultBefore)
    }
    #expect(try await store.tombstone(id: sourceID, kind: .source) == nil)
    #expect(try await store.canonicalVaultRevision() == vaultBefore)
    try await store.purgeCanonicalEntity(id: pageID, kind: .page, expected: trashedPage.revision, expectedVaultRevision: vaultBefore)
    #expect(try await store.tombstone(id: pageID, kind: .page)?.lastRevision == trashedPage.revision)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM page_sources") == 0)
    await #expect(throws: VaultError.self) {
        try await store.savePage(record: canonicalNote(pageID), document: trashedPage.document, condition: .createOnly)
    }
    try await store.purgeCanonicalEntity(id: sourceID, kind: .source, expected: trashedSource.revision,
        expectedVaultRevision: try await store.canonicalVaultRevision())
    #expect(try await store.tombstone(id: sourceID, kind: .source)?.lastRevision == trashedSource.revision)
    await #expect(throws: VaultError.self) {
        try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID), condition: .createOnly,
            operationID: UUID(), expectedVaultRevision: try await store.canonicalVaultRevision())
    }
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM tombstones") == 2)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM sources") == 0)
    try await store.close()
}

private final class CanonicalPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if calls == 2 { throw VaultError.conflict("Publication authority revoked before commit.") }
    }
}

@Test func canonicalSQLitePrecommitAuthorityFailureHasNoOperationOutcome() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), sourceID = UUID(), operationID = UUID()
    let store = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID())
    let vaultBefore = try await store.canonicalVaultRevision(), probe = CanonicalPublicationProbe()
    await #expect(throws: VaultError.self) {
        try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID), condition: .createOnly,
            operationID: operationID, expectedVaultRevision: vaultBefore, validating: { try probe.validate() })
    }
    #expect(try await store.committedOperation(id: operationID) == nil)
    #expect(try await store.canonicalVaultRevision() == vaultBefore)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM sources") == 0)
    let committed = try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID), condition: .createOnly,
        operationID: operationID, expectedVaultRevision: vaultBefore)
    #expect(try await store.committedOperation(id: operationID) == committed)
    await #expect(throws: VaultError.self) {
        try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID), condition: .createOnly,
            operationID: operationID, expectedVaultRevision: committed.vaultRevision)
    }
    #expect(try await store.committedOperation(id: operationID) == committed)
    try await store.close()
}

@Test func canonicalSQLitePreservesSourcePayloadAndRejectsUnsupportedOwnershipAndVersions() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), sourceID = UUID()
    let store = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID())
    let opaque = Data(#"{"title":"Unknown source","future":{"nested":[true,null,42,"value"]}}"#.utf8)
    let initial = try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID, metadata: opaque), condition: .createOnly,
        operationID: UUID(), expectedVaultRevision: try await store.canonicalVaultRevision())
    #expect(try await store.sourceSnapshot(id: sourceID).source.metadata == opaque)
    let replacement = try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID, metadata: opaque), condition: .replace(expected: initial.sourceRevision),
        operationID: UUID(), expectedVaultRevision: initial.vaultRevision)
    #expect(replacement.sourceRevision != initial.sourceRevision)
    #expect(replacement.vaultRevision == initial.vaultRevision)
    await #expect(throws: VaultError.self) {
        try await store.publishSourceAndPage(source: CanonicalSource(id: sourceID, metadata: opaque), condition: .replace(expected: initial.sourceRevision),
            operationID: UUID(), expectedVaultRevision: replacement.vaultRevision)
    }
    for source in [CanonicalSource(id: UUID(), ownership: .imported), CanonicalSource(id: UUID(), ownership: .linked),
                   CanonicalSource(id: UUID(), payloadVersion: 2), CanonicalSource(id: UUID(), requiredFeatures: ["future"]),
                   CanonicalSource(id: UUID(), metadata: Data(#"{"id":"duplicate authority"}"#.utf8))] {
        await #expect(throws: VaultError.self) {
            try await store.publishSourceAndPage(source: source, condition: .createOnly,
                operationID: UUID(), expectedVaultRevision: replacement.vaultRevision)
        }
    }
    #expect(try await store.sourceSnapshot(id: sourceID).source.metadata == opaque)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM sources") == 1)
    try await store.close()
}

@Test func canonicalSQLiteRepresentativeReadWriteComparison() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blocks = (0..<100).map { EditorBlock(runs: [RichRun("Representative rich paragraph \($0) 😀")]) }
    let original = BlockDocument(blocks: blocks)
    let legacy = try SQLiteBlockStore(unguardedTestingURL: root.appendingPathComponent("legacy.sqlite"))
    let canonical = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("canonical.sqlite"), vaultID: UUID())
    var results: [(String, Double, Double)] = []
    for (label, store) in [("schema2", legacy), ("schema3", canonical)] {
        let pageID = UUID()
        var snapshot = try await store.savePage(record: canonicalNote(pageID), document: original, condition: .createOnly)
        let writeStart = Date.timeIntervalSinceReferenceDate
        for iteration in 0..<20 {
            var changed = snapshot.document
            _ = changed.update(blocks[0].id) { $0.runs = [RichRun("Edited paragraph \(iteration)")] }
            snapshot = try await store.savePage(record: canonicalNote(pageID), document: changed, condition: .replace(expected: snapshot.revision))
        }
        let writeTime = Date.timeIntervalSinceReferenceDate - writeStart
        let readStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<20 { #expect(try await store.loadPage(pageID: pageID).snapshot == snapshot) }
        let readTime = Date.timeIntervalSinceReferenceDate - readStart
        results.append((label, writeTime, readTime))
        try await store.close()
    }
    for (label, writes, reads) in results {
        print("STOR02A performance \(label): 100 blocks, 20 incremental writes \(writes)s, 20 coherent reads \(reads)s")
    }
}

@Test func canonicalSQLiteFreshSchemaFailureRollsBackEveryDDLStep() throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    // Existing noncanonical bytes collide late in schema construction. They must
    // survive while every newly created schema table and version marker rolls back.
    try canonicalSQL(url, "CREATE TABLE conflicts(preserved TEXT); INSERT INTO conflicts VALUES('unique old bytes');")
    #expect(throws: VaultError.self) { try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID()) }
    #expect(try canonicalSQLInteger(url, "PRAGMA user_version") == 0)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM sqlite_master WHERE name IN ('pages','blocks','sources','vault_state')") == 0)
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM conflicts WHERE preserved='unique old bytes'") == 1)
}

@Test func canonicalSQLiteRejectsUnknownSQLPreservationWrapperWithoutRewriting() async throws {
    let root = try canonicalTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    let store = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID())
    let saved = try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("preserved")])]), pageID: UUID(), condition: .createOnly)
    try canonicalSQL(url, "UPDATE blocks SET extensions=CAST('{\"futureWrapper\":true}' AS BLOB)")
    await #expect(throws: VaultError.self) { try await store.load(pageID: saved.pageID) }
    #expect(try canonicalSQLInteger(url, "SELECT count(*) FROM blocks WHERE CAST(extensions AS TEXT)='{\"futureWrapper\":true}'") == 1)
    try await store.close()
}
