import Foundation
import SQLite3

/// The connection, statements and transactions belong exclusively to the store actor.
private final class BlockSQLiteConnection: @unchecked Sendable {
    var pointer: OpaquePointer?
    init(url: URL, createIfMissing: Bool) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, (createIfMissing ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw VaultError.storage("Could not open the block database.")
        }
        self.pointer = pointer
    }
    deinit { if let pointer { sqlite3_close_v2(pointer) } }
}

public actor SQLiteBlockStore: BlockStore {
    public nonisolated let mode = BlockStorageMode.sqliteBlocks
    public nonisolated let sessionLease: VaultSessionLease?
    public nonisolated let accessGate: VaultAccessGate?
    private let connection: BlockSQLiteConnection
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()
    private let decoder = JSONDecoder()
    public static let schemaVersion = 2

    /// Canonical production access requires the admitted vault's current lease.
    public init(url: URL, sessionLease: VaultSessionLease, accessGate: VaultAccessGate, createIfMissing: Bool = true) throws {
        try accessGate.validate(lease: sessionLease, targetRoot: sessionLease.root, targetVaultID: sessionLease.vaultID, operation: "blockStore.open")
        try SQLiteVaultMigration.requireLocalRoot(sessionLease.root)
        let root = sessionLease.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) else { throw VaultError.invalid("Block database must belong to the admitted vault.") }
        self.sessionLease = sessionLease; self.accessGate = accessGate
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing)
    }
    /// Staging migration and disposable tests have no admitted session yet.
    /// Callers must separately establish a safe local staging target.
    init(unguardedTestingURL url: URL, createIfMissing: Bool = true) throws {
        sessionLease = nil; accessGate = nil
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing)
    }
    private static func prepare(_ connection: BlockSQLiteConnection, initializeIfNeeded: Bool) throws {
        guard let db = connection.pointer else { throw VaultError.storage("Block database closed.") }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(db))) }
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;")
        func readVersion() throws -> Int32 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, let statement else { throw VaultError.storage("Cannot read block schema version.") }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw VaultError.storage("Cannot read block schema version.") }
            return sqlite3_column_int(statement, 0)
        }
        var version = try readVersion()
        guard version >= 0, version <= schemaVersion else { throw VaultError.invalid("Unsupported block database schema version.") }
        guard version != 0 || initializeIfNeeded else { throw VaultError.invalid("The block database has no supported schema.") }
        if version == 0 {
            try exec("BEGIN IMMEDIATE")
            do {
                try exec("""
                CREATE TABLE pages(id TEXT PRIMARY KEY, revision BLOB NOT NULL, metadata BLOB, properties BLOB NOT NULL, trashed INTEGER NOT NULL DEFAULT 0 CHECK(trashed IN (0,1)));
                CREATE TABLE blocks(page_id TEXT NOT NULL, id TEXT NOT NULL, parent_id TEXT, sibling_order INTEGER NOT NULL CHECK(sibling_order>=0), kind TEXT NOT NULL, runs BLOB NOT NULL, semantic BLOB NOT NULL, created_at REAL NOT NULL, modified_at REAL NOT NULL, extensions BLOB NOT NULL, PRIMARY KEY(page_id,id), FOREIGN KEY(page_id) REFERENCES pages(id) ON DELETE CASCADE, FOREIGN KEY(page_id,parent_id) REFERENCES blocks(page_id,id) DEFERRABLE INITIALLY DEFERRED);
                CREATE INDEX block_parent_order ON blocks(page_id,parent_id,sibling_order);
                PRAGMA user_version=1;
                COMMIT;
                """)
            } catch { try? exec("ROLLBACK"); throw error }
            version = 1
        }
        if version == 1 {
            try exec("BEGIN IMMEDIATE")
            do {
                // Existing v1 trash has no trustworthy removal date; NULL retains
                // the repository's undated-entry grace rather than inventing one.
                try exec("ALTER TABLE pages ADD COLUMN trashed_at REAL; PRAGMA user_version=2; COMMIT;")
            } catch { try? exec("ROLLBACK"); throw error }
        }
    }
    private func validate(_ operation: String) throws {
        if let accessGate, let sessionLease {
            try accessGate.validate(lease: sessionLease, targetRoot: sessionLease.root, targetVaultID: sessionLease.vaultID, operation: operation)
        }
    }
    private var db: OpaquePointer { get throws { guard let value = connection.pointer else { throw VaultError.storage("Block database closed.") }; return value } }
    private enum Value { case text(String), blob(Data), integer(Int64), real(Double), null }
    private func statement(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        let db = try db
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let index = Int32(index + 1), result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(pointer, index, text, -1, transient)
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(pointer, index, $0.baseAddress, Int32(data.count), transient) }
            case .integer(let value): result = sqlite3_bind_int64(pointer, index, value)
            case .real(let value): result = sqlite3_bind_double(pointer, index, value)
            case .null: result = sqlite3_bind_null(pointer, index)
            }
            guard result == SQLITE_OK else { sqlite3_finalize(pointer); throw failure() }
        }
        return pointer
    }
    private func failure() -> VaultError { .storage(connection.pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Block database closed.") }
    private func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func transaction<T>(validating publication: (@Sendable () throws -> Void)? = nil, _ operation: () throws -> T) throws -> T {
        try validate("blockStore.write"); try run("BEGIN IMMEDIATE")
        do {
            try publication?()
            let value = try operation()
            try validate("blockStore.commit"); try publication?(); try run("COMMIT")
            return value
        }
        catch { try? run("ROLLBACK"); throw error }
    }
    /// A page's revision, blocks and metadata must come from one SQLite snapshot,
    /// including when another store connection publishes a change concurrently.
    /// Reads inside a write transaction reuse its already reserved snapshot.
    private func readTransaction<T>(_ operation: () throws -> T) throws -> T {
        try validate("blockStore.read")
        if sqlite3_get_autocommit(try db) == 0 { return try operation() }
        try run("BEGIN DEFERRED")
        do { let value = try operation(); try validate("blockStore.read"); try run("COMMIT"); return value }
        catch { try? run("ROLLBACK"); throw error }
    }
    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    private struct Extensions: Codable, Equatable {
        var originalMarkdown: String?; var originalSignature: String?; var originalIndentation: String?; var originalDepth: Int?
        init(_ block: EditorBlock) { originalMarkdown = block.originalMarkdown; originalSignature = block.originalSignature; originalIndentation = block.originalIndentation; originalDepth = block.originalDepth }
    }
    private struct Row: Equatable { var block: EditorBlock; var parent: UUID?; var order: Int }
    private func rows(_ document: BlockDocument) -> [UUID: Row] {
        var result: [UUID: Row] = [:]
        func walk(_ blocks: [EditorBlock], parent: UUID?) {
            for (order, block) in blocks.enumerated() {
                var own = block; own.children = []
                result[block.id] = Row(block: own, parent: parent, order: order)
                walk(block.children, parent: block.id)
            }
        }
        walk(document.blocks, parent: nil); return result
    }
    public func load(pageID: UUID) throws -> BlockStoreSnapshot {
        try readTransaction { try loadDocument(pageID: pageID) }
    }
    private func loadDocument(pageID: UUID) throws -> BlockStoreSnapshot {
        try validate("blockStore.load")
        let statement = try statement("SELECT revision,properties FROM pages WHERE id=?", [.text(pageID.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw VaultError.unavailable("Page does not exist in the block database.") }
        guard status == SQLITE_ROW else { throw failure() }
        let revision = BlockStoreRevision(token: blob(statement, 0))
        var document = try decoder.decode(BlockDocument.self, from: blob(statement, 1))
        let blocks = try self.statement("SELECT id,parent_id,sibling_order,kind,runs,semantic,created_at,modified_at,extensions FROM blocks WHERE page_id=? ORDER BY sibling_order,id", [.text(pageID.uuidString)])
        defer { sqlite3_finalize(blocks) }
        var children: [String: [EditorBlock]] = [:], count = 0
        while true {
            let status = sqlite3_step(blocks)
            if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw failure() }
            guard let id = UUID(uuidString: text(blocks, 0)) else { throw VaultError.invalid("Invalid block identity.") }
            let parent = text(blocks, 1)
            guard sqlite3_column_int64(blocks, 2) == Int64(children[parent, default: []].count) else {
                throw VaultError.invalid("Invalid block sibling order.")
            }
            var block = EditorBlock(id: id, kind: .init(rawValue: text(blocks, 3)), runs: try decoder.decode([RichRun].self, from: blob(blocks, 4)), metadata: try decoder.decode(BlockMetadata.self, from: blob(blocks, 5)))
            block.createdAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(blocks, 6)); block.modifiedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(blocks, 7))
            let extra = try decoder.decode(Extensions.self, from: blob(blocks, 8))
            block.originalMarkdown = extra.originalMarkdown; block.originalSignature = extra.originalSignature; block.originalIndentation = extra.originalIndentation; block.originalDepth = extra.originalDepth
            children[parent, default: []].append(block); count += 1
        }
        var seen = Set<UUID>()
        func tree(_ parent: String) throws -> [EditorBlock] {
            try (children[parent] ?? []).map { value in
                guard seen.insert(value.id).inserted else { throw VaultError.invalid("Cyclic block tree.") }
                var block = value; block.children = try tree(value.id.uuidString); return block
            }
        }
        document.blocks = try tree("")
        guard seen.count == count, BlockDocumentCodec.valid(document) else { throw VaultError.invalid("Invalid or orphaned block tree.") }
        try validate("blockStore.load")
        return .init(pageID: pageID, document: document, revision: revision)
    }
    @discardableResult public func save(_ document: BlockDocument, pageID: UUID, condition: BlockStoreWriteCondition) throws -> BlockStoreSnapshot {
        try transaction { try persist(document, pageID: pageID, condition: condition, metadata: nil) }
    }
    private func persist(_ document: BlockDocument, pageID: UUID, condition: BlockStoreWriteCondition, metadata: Data?) throws -> BlockStoreSnapshot {
        guard !document.unsupportedVersion, BlockDocumentCodec.valid(document) else { throw VaultError.invalid("Unsupported or invalid block document.") }
        let current: BlockStoreSnapshot?
        switch condition {
        case .createOnly:
            let statement = try statement("SELECT 1 FROM pages WHERE id=?", [.text(pageID.uuidString)]); defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { throw VaultError.conflict("Block page already exists.") }
            guard status == SQLITE_DONE else { throw failure() }; current = nil
        case .replace(let expected):
            current = try load(pageID: pageID)
            guard current?.revision == expected else { throw VaultError.conflict("Block page revision changed.") }
        }
        let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
        var properties = document; properties.blocks = []
        if current == nil {
            try run("INSERT INTO pages(id,revision,metadata,properties) VALUES(?,?,?,?)", [.text(pageID.uuidString), .blob(revision.token), metadata.map(Value.blob) ?? .null, .blob(try encoder.encode(properties))])
        } else {
            try run("UPDATE pages SET revision=?,properties=?,metadata=COALESCE(?,metadata) WHERE id=?", [.blob(revision.token), .blob(try encoder.encode(properties)), metadata.map(Value.blob) ?? .null, .text(pageID.uuidString)])
        }
        let old = current.map { rows($0.document) } ?? [:], next = rows(document)
        for id in old.keys where next[id] == nil { try run("DELETE FROM blocks WHERE page_id=? AND id=?", [.text(pageID.uuidString), .text(id.uuidString)]) }
        for (id, row) in next where old[id] != row {
            let block = row.block
            try run("""
            INSERT INTO blocks(page_id,id,parent_id,sibling_order,kind,runs,semantic,created_at,modified_at,extensions) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(page_id,id) DO UPDATE SET parent_id=excluded.parent_id,sibling_order=excluded.sibling_order,kind=excluded.kind,runs=excluded.runs,semantic=excluded.semantic,created_at=excluded.created_at,modified_at=excluded.modified_at,extensions=excluded.extensions
            """, [.text(pageID.uuidString), .text(id.uuidString), row.parent.map { .text($0.uuidString) } ?? .null, .integer(Int64(row.order)), .text(block.kind.rawValue), .blob(try encoder.encode(block.runs)), .blob(try encoder.encode(block.metadata)), .real(block.createdAt.timeIntervalSinceReferenceDate), .real(block.modifiedAt.timeIntervalSinceReferenceDate), .blob(try encoder.encode(Extensions(block)))])
        }
        return .init(pageID: pageID, document: document, revision: revision)
    }
    public func savePage(record: NoteRecord, document: BlockDocument, condition: BlockStoreWriteCondition, validating publication: (@Sendable () throws -> Void)? = nil) throws -> BlockStoreSnapshot {
        var metadata = record; metadata.body = ""; metadata.contentHash = ""
        return try transaction(validating: publication) { try persist(document, pageID: record.id, condition: condition, metadata: encoder.encode(metadata)) }
    }
    public func loadPage(pageID: UUID) throws -> (record: NoteRecord, snapshot: BlockStoreSnapshot) {
        try readTransaction { try loadPageInTransaction(pageID: pageID) }
    }
    private func loadPageInTransaction(pageID: UUID) throws -> (record: NoteRecord, snapshot: BlockStoreSnapshot) {
        let snapshot = try load(pageID: pageID)
        let statement = try statement("SELECT metadata,trashed,trashed_at FROM pages WHERE id=?", [.text(pageID.uuidString)]); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { throw VaultError.unavailable("Page metadata missing.") }
        var record = try decoder.decode(NoteRecord.self, from: blob(statement, 0))
        guard record.id == pageID else { throw VaultError.invalid("Page metadata identity does not match its record.") }
        record.body = BlockDocumentCodec.encode(snapshot.document); record.contentHash = snapshot.revision.token.base64EncodedString()
        record.inlineTags = MarkdownService.analyze(record.body).tags
        if sqlite3_column_int(statement, 1) == 1 {
            let cycle = digest(snapshot.revision.token) + "-" + pageID.uuidString.lowercased()
            if sqlite3_column_type(statement, 2) == SQLITE_NULL {
                record.relativePath = "sqlite/undated-trash-" + cycle
            } else {
                record.relativePath = "sqlite/trash-\(Int(sqlite3_column_double(statement, 2)))-" + cycle
            }
        }
        return (record, snapshot)
    }
    public func allPages(includeTrashed: Bool = false) throws -> [NoteRecord] {
        try readTransaction { try allPagesInTransaction(includeTrashed: includeTrashed) }
    }
    public func allTrashedPages() throws -> [NoteRecord] {
        try readTransaction { try allPagesInTransaction(includeTrashed: true, onlyTrashed: true) }
    }
    private func allPagesInTransaction(includeTrashed: Bool, onlyTrashed: Bool = false) throws -> [NoteRecord] {
        try validate("blockStore.allPages")
        let query = onlyTrashed ? "SELECT id FROM pages WHERE trashed=1 ORDER BY id" : (includeTrashed ? "SELECT id FROM pages ORDER BY id" : "SELECT id FROM pages WHERE trashed=0 ORDER BY id")
        let statement = try statement(query); defer { sqlite3_finalize(statement) }
        var result: [NoteRecord] = []
        while true {
            let status = sqlite3_step(statement); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw failure() }
            guard let id = UUID(uuidString: text(statement, 0)) else { throw VaultError.invalid("Invalid page identity.") }
            result.append(try loadPage(pageID: id).record)
        }
        return result
    }
    public func delete(pageID: UUID, expected: BlockStoreRevision) throws {
        try transaction {
            guard try load(pageID: pageID).revision == expected else { throw VaultError.conflict("Block page revision changed.") }
            // Deferred parent constraints allow every descendant to disappear in one commit.
            try run("DELETE FROM pages WHERE id=?", [.text(pageID.uuidString)])
        }
    }
    @discardableResult public func setTrashed(pageID: UUID, expected: BlockStoreRevision, trashed: Bool) throws -> BlockStoreSnapshot {
        try transaction {
            let current = try load(pageID: pageID)
            guard current.revision == expected else { throw VaultError.conflict("Block page revision changed.") }
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            try run("UPDATE pages SET trashed=?,trashed_at=?,revision=? WHERE id=?", [.integer(trashed ? 1 : 0), trashed ? .real(Date().timeIntervalSince1970) : .null, .blob(revision.token), .text(pageID.uuidString)])
            return .init(pageID: pageID, document: current.document, revision: revision)
        }
    }
    @discardableResult public func apply(_ mutation: BlockMutation, to blockID: UUID, pageID: UUID, expected: BlockStoreRevision) throws -> BlockStoreSnapshot {
        try transaction {
            let current = try load(pageID: pageID)
            guard current.revision == expected else { throw VaultError.conflict("Block page revision changed.") }
            var document = current.document
            guard document.apply(mutation, to: blockID) != nil else { return current }
            return try persist(document, pageID: pageID, condition: .replace(expected: expected), metadata: nil)
        }
    }
    public func checkpoint() throws {
        try validate("blockStore.checkpoint")
        let statement = try statement("PRAGMA wal_checkpoint(TRUNCATE)"); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else { throw failure() }
    }
    public func close() throws {
        guard let pointer = connection.pointer else { return }
        guard sqlite3_close(pointer) == SQLITE_OK else { throw failure() }
        connection.pointer = nil
    }
}
