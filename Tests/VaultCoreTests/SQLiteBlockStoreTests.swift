import Foundation
import SQLite3
import Testing
@testable import VaultCore

private func blockSQL(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(db))) }
}
private func blockSQLValue(_ url: URL, _ sql: String) throws -> Int {
    var db: OpaquePointer?, statement: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    return Int(sqlite3_column_int(statement, 0))
}

@Test func sqliteBlocksReconstructAndWriteOnlyAffectedRows() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let store = try SQLiteBlockStore(unguardedTestingURL: url)
    var metadata = BlockMetadata(); metadata.extra["future"] = "opaque"; metadata.semantic = "future-semantic"
    var style = InlineStyle(); style.bold = true; style.wikiTarget = "Page"
    let child = EditorBlock(kind: .init(rawValue: "future-kind"), runs: [RichRun("😀 rich", style: style)], metadata: metadata)
    let parent = EditorBlock(runs: [RichRun("parent")], children: [child])
    var document = BlockDocument(blocks: [parent, EditorBlock(runs: [RichRun("unaffected")])], trailingNewline: true)
    document.recoveredMetadata = "unknown envelope"
    let initial = try await store.save(document, pageID: page, condition: .createOnly)
    #expect(try await store.load(pageID: page).document == document)
    try blockSQL(url, "CREATE TABLE writes(id TEXT); CREATE TRIGGER audit_update AFTER UPDATE ON blocks BEGIN INSERT INTO writes VALUES(new.id); END;")
    _ = document.update(child.id) { $0.runs.append(RichRun(" edited")) }
    let edited = try await store.save(document, pageID: page, condition: .replace(expected: initial.revision))
    #expect(try blockSQLValue(url, "SELECT count(*) FROM writes") == 1)
    do { _ = try await store.save(document, pageID: page, condition: .replace(expected: initial.revision)); Issue.record("stale revision accepted") } catch {}
    #expect(try await store.load(pageID: page) == edited)
    let split = try await store.apply(.split(2), to: child.id, pageID: page, expected: edited.revision)
    #expect(split.document.blocks[0].children.count == 2)
    try await store.close()
    let reopened = try SQLiteBlockStore(unguardedTestingURL: url)
    #expect(try await reopened.load(pageID: page) == split)
    try await reopened.delete(pageID: page, expected: split.revision)
    #expect(try blockSQLValue(url, "SELECT count(*) FROM blocks") == 0)
    try await reopened.close()
}

@Test func sqliteBlocksRollbackAndRejectFutureSchema() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let store = try SQLiteBlockStore(unguardedTestingURL: url)
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("original")])])
    let initial = try await store.save(document, pageID: page, condition: .createOnly)
    try blockSQL(url, "CREATE TRIGGER reject_update BEFORE UPDATE ON blocks BEGIN SELECT RAISE(ABORT,'injected failure'); END;")
    var changed = document; _ = changed.update(document.blocks[0].id) { $0.runs = [RichRun("changed")] }
    do { _ = try await store.save(changed, pageID: page, condition: .replace(expected: initial.revision)); Issue.record("injected failure did not roll back") } catch {}
    #expect(try await store.load(pageID: page) == initial)
    #expect(try blockSQLValue(url, "PRAGMA user_version") == SQLiteBlockStore.schemaVersion)
    do { try blockSQL(url, "PRAGMA foreign_keys=ON; INSERT INTO blocks SELECT page_id,'bad','missing',0,kind,runs,semantic,created_at,modified_at,extensions FROM blocks LIMIT 1"); Issue.record("orphan accepted") } catch {}
    #expect(try blockSQLValue(url, "SELECT count(*) FROM blocks") == 1)
    try await store.close()
    try blockSQL(url, "PRAGMA user_version=999")
    do { _ = try SQLiteBlockStore(unguardedTestingURL: url); Issue.record("future schema accepted") } catch {}
}

@Test func sqliteBlockSubtreeMutationsAreAtomic() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let store = try SQLiteBlockStore(unguardedTestingURL: url)
    let descendant = EditorBlock(runs: [RichRun("descendant")])
    let first = EditorBlock(runs: [RichRun("first")], children: [descendant])
    let second = EditorBlock(runs: [RichRun("second")])
    let third = EditorBlock(runs: [RichRun("third")])
    var current = try await store.save(BlockDocument(blocks: [first, second, third]), pageID: page, condition: .createOnly)
    current = try await store.apply(.reorderAfter(third.id), to: first.id, pageID: page, expected: current.revision)
    #expect(current.document.blocks.map(\.id) == [second.id, third.id, first.id])
    #expect(try await store.load(pageID: page) == current)
    current = try await store.apply(.move(-1), to: first.id, pageID: page, expected: current.revision)
    current = try await store.apply(.indent, to: first.id, pageID: page, expected: current.revision)
    #expect(current.document.blocks[0].children[0].children[0].id == descendant.id)
    #expect(try await store.load(pageID: page) == current)
    current = try await store.apply(.outdent, to: first.id, pageID: page, expected: current.revision)
    current = try await store.apply(.mergeBackward, to: first.id, pageID: page, expected: current.revision)
    #expect(current.document.blocks[0].children[0].id == descendant.id)
    #expect(current.document.blocks[0].text == "secondfirst")
    #expect(try await store.load(pageID: page) == current)
    try blockSQL(url, "CREATE TRIGGER reject_delete BEFORE DELETE ON blocks WHEN old.id='\(descendant.id.uuidString)' BEGIN SELECT RAISE(ABORT,'subtree deletion failed'); END;")
    do { _ = try await store.apply(.delete, to: second.id, pageID: page, expected: current.revision); Issue.record("partially deleted subtree") } catch {}
    #expect(try await store.load(pageID: page) == current)
    try blockSQL(url, "DROP TRIGGER reject_delete")
    current = try await store.apply(.delete, to: second.id, pageID: page, expected: current.revision)
    #expect(current.document.flattened.map(\.id) == [third.id])
    #expect(try await store.load(pageID: page) == current)
    #expect(try blockSQLValue(url, "SELECT count(*) FROM pragma_foreign_key_check") == 0)
    try await store.close()
}

private func sqliteBlockNote(id: UUID, title: String) -> NoteRecord {
    NoteRecord(id: id, title: title, aliases: ["alias"], tags: ["tag"], inlineTags: [], createdAt: "2026-10-12", updatedAt: "2026-10-12", body: "", relativePath: "Wiki/\(id.uuidString).md", contentHash: "", originalHeader: "future: retained")
}

private final class BlockPublicationValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if count == 2 { throw VaultError.conflict("Publication authority was revoked.") }
    }
}

@Test func sqlitePagePublicationValidationRollsBackMetadataAndBlocks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let store = try SQLiteBlockStore(unguardedTestingURL: url)
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("original")])])
    let initial = try await store.savePage(record: sqliteBlockNote(id: page, title: "original"), document: document, condition: .createOnly)
    var changed = document; _ = changed.update(document.blocks[0].id) { $0.runs = [RichRun("changed")] }
    let validation = BlockPublicationValidation()
    do {
        _ = try await store.savePage(record: sqliteBlockNote(id: page, title: "changed"), document: changed, condition: .replace(expected: initial.revision), validating: { try validation.check() })
        Issue.record("revoked publication committed")
    } catch {}
    let loaded = try await store.loadPage(pageID: page)
    #expect(loaded.snapshot == initial)
    #expect(loaded.record.title == "original")
    #expect(loaded.record.originalHeader == "future: retained")
    try await store.close()
}

@Test func sqliteConnectionsRejectStaleWritesAndReadCoherentPageSnapshots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let reader = try SQLiteBlockStore(unguardedTestingURL: url)
    let writer = try SQLiteBlockStore(unguardedTestingURL: url)
    let initial = try await reader.savePage(record: sqliteBlockNote(id: page, title: "0"), document: BlockDocument(blocks: [EditorBlock(runs: [RichRun("0")])]), condition: .createOnly)
    let writes = Task {
        var current = initial
        for index in 1...40 {
            var document = current.document
            _ = document.update(document.blocks[0].id) { $0.runs = [RichRun(String(index))] }
            current = try await writer.savePage(record: sqliteBlockNote(id: page, title: String(index)), document: document, condition: .replace(expected: current.revision))
        }
        return current
    }
    for _ in 0..<80 {
        let loaded = try await reader.loadPage(pageID: page)
        #expect(loaded.record.title == loaded.snapshot.document.blocks[0].text)
        #expect(loaded.record.contentHash == loaded.snapshot.revision.token.base64EncodedString())
    }
    let current = try await writes.value
    do { _ = try await reader.save(initial.document, pageID: page, condition: .replace(expected: initial.revision)); Issue.record("cross-connection stale write accepted") } catch {}
    #expect(try await reader.load(pageID: page) == current)
    try await reader.close(); try await writer.close()
}

@Test func sqliteSchemaCreationFailureRollsBackDDL() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    try blockSQL(url, "CREATE TABLE blocks(preserved TEXT); INSERT INTO blocks VALUES('original')")
    do { _ = try SQLiteBlockStore(unguardedTestingURL: url); Issue.record("conflicting schema accepted") } catch {}
    #expect(try blockSQLValue(url, "PRAGMA user_version") == 0)
    #expect(try blockSQLValue(url, "SELECT count(*) FROM sqlite_master WHERE name='pages'") == 0)
    #expect(try blockSQLValue(url, "SELECT count(*) FROM blocks WHERE preserved='original'") == 1)
}

@Test func sqliteBlocksRejectCorruptSiblingOrdersAndParentCycles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let store = try SQLiteBlockStore(unguardedTestingURL: url)
    let first = EditorBlock(runs: [RichRun("first")]), second = EditorBlock(runs: [RichRun("second")])
    _ = try await store.save(BlockDocument(blocks: [first, second]), pageID: page, condition: .createOnly)
    try blockSQL(url, "UPDATE blocks SET sibling_order=0 WHERE id='\(second.id.uuidString)'")
    await #expect(throws: VaultError.self) { _ = try await store.load(pageID: page) }
    try blockSQL(url, "UPDATE blocks SET sibling_order=1 WHERE id='\(second.id.uuidString)'; UPDATE blocks SET parent_id=id,sibling_order=0 WHERE id='\(first.id.uuidString)'; UPDATE blocks SET sibling_order=0 WHERE id='\(second.id.uuidString)'")
    await #expect(throws: VaultError.self) { _ = try await store.load(pageID: page) }
    try await store.close()
}

@Test func sqliteBlocksRejectRevokedSessionWithoutMutatingPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = VaultSessionManager()
    let session = try await manager.open(root: root) { _ in UUID() }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let store = try SQLiteBlockStore(url: url, sessionLease: session.lease, accessGate: manager.accessGate)
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("preserved")])])
    let initial = try await store.save(document, pageID: page, condition: .createOnly)
    try await manager.lock()
    await #expect(throws: VaultAccessError.self) { _ = try await store.load(pageID: page) }
    await #expect(throws: VaultAccessError.self) { _ = try await store.save(document, pageID: page, condition: .replace(expected: initial.revision)) }
    await #expect(throws: VaultAccessError.self) { try await store.delete(pageID: page, expected: initial.revision) }
    try await store.close()
    let inspection = try SQLiteBlockStore(unguardedTestingURL: url)
    #expect(try await inspection.load(pageID: page) == initial)
    try await inspection.close()
}

@Test func sqliteSchemaUpgradePreservesPagesAndTrashCyclesResetRetentionIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let initialStore = try SQLiteBlockStore(unguardedTestingURL: url)
    let record = sqliteBlockNote(id: page, title: "Trash")
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("#original")])])
    let initial = try await initialStore.savePage(record: record, document: document, condition: .createOnly)
    let oldTrash = try await initialStore.setTrashed(pageID: page, expected: initial.revision, trashed: true)
    try await initialStore.close()
    // Recreate the prior version's shape, retaining its page/block records.
    try blockSQL(url, "ALTER TABLE pages DROP COLUMN trashed_at; PRAGMA user_version=1")
    let store = try SQLiteBlockStore(unguardedTestingURL: url)
    #expect(try blockSQLValue(url, "PRAGMA user_version") == SQLiteBlockStore.schemaVersion)
    #expect(try await store.load(pageID: page) == oldTrash)
    let undated = try await store.loadPage(pageID: page).record
    #expect(undated.relativePath.hasPrefix("sqlite/undated-trash-"))
    #expect(try await store.allTrashedPages().map(\.id) == [page])
    #expect(try await store.allPages().isEmpty)
    let restored = try await store.setTrashed(pageID: page, expected: oldTrash.revision, trashed: false)
    #expect(try await store.loadPage(pageID: page).record.relativePath == record.relativePath)
    #expect(try blockSQLValue(url, "SELECT count(*) FROM pages WHERE trashed_at IS NULL") == 1)
    let firstTrash = try await store.setTrashed(pageID: page, expected: restored.revision, trashed: true)
    try blockSQL(url, "UPDATE pages SET trashed_at=1")
    let firstPath = try await store.loadPage(pageID: page).record.relativePath
    #expect(firstPath.hasPrefix("sqlite/trash-1-"))
    let secondRestore = try await store.setTrashed(pageID: page, expected: firstTrash.revision, trashed: false)
    _ = try await store.setTrashed(pageID: page, expected: secondRestore.revision, trashed: true)
    let newPath = try await store.loadPage(pageID: page).record.relativePath
    #expect(newPath.hasPrefix("sqlite/trash-"))
    #expect(newPath != firstPath)
    #expect(try blockSQLValue(url, "SELECT count(*) FROM pages WHERE trashed_at>1") == 1)
    try await store.close()
}

@Test func sqliteDirectBlockMutationsDeriveInlineTagsFromCurrentContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), page = UUID()
    let store = try SQLiteBlockStore(unguardedTestingURL: url)
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("body #fresh")])])
    let initial = try await store.savePage(record: sqliteBlockNote(id: page, title: "Tags"), document: document, condition: .createOnly)
    #expect(try await store.loadPage(pageID: page).record.inlineTags == ["fresh"])
    _ = try await store.apply(.delete, to: document.blocks[0].id, pageID: page, expected: initial.revision)
    #expect(try await store.loadPage(pageID: page).record.inlineTags.isEmpty)
    try await store.close()
}

@Test func sqliteBlocksExistingOpenRejectsMissingAndUnversionedDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    #expect(throws: (any Error).self) { try SQLiteBlockStore(unguardedTestingURL: url, createIfMissing: false) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try Data().write(to: url)
    #expect(throws: (any Error).self) { try SQLiteBlockStore(unguardedTestingURL: url, createIfMissing: false) }
    #expect(try Data(contentsOf: url).isEmpty)
}
