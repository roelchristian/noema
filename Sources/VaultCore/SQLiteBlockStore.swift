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
    private let databaseURL: URL
    private let connection: BlockSQLiteConnection
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()
    private let decoder = JSONDecoder()
    public static let schemaVersion = 2
    public static let expandedSchemaVersion = 3
    private let canonicalVaultID: UUID?

    /// Canonical production access requires the admitted vault's current lease.
    public init(url: URL, sessionLease: VaultSessionLease, accessGate: VaultAccessGate, createIfMissing: Bool = true) throws {
        try accessGate.validate(lease: sessionLease, targetRoot: sessionLease.root, targetVaultID: sessionLease.vaultID, operation: "blockStore.open")
        try SQLiteVaultMigration.requireLocalRoot(sessionLease.root)
        let root = sessionLease.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) else { throw VaultError.invalid("Block database must belong to the admitted vault.") }
        canonicalVaultID = nil
        self.sessionLease = sessionLease; self.accessGate = accessGate
        databaseURL = url.standardizedFileURL.resolvingSymlinksInPath()
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing)
    }
    /// Staging migration and disposable tests have no admitted session yet.
    /// Callers must separately establish a safe local staging target.
    init(unguardedTestingURL url: URL, createIfMissing: Bool = true) throws {
        canonicalVaultID = nil
        sessionLease = nil; accessGate = nil
        databaseURL = url.standardizedFileURL.resolvingSymlinksInPath()
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing)
    }
    /// Expanded authority is opt-in and cannot reinterpret an existing page-only DB.
    init(url: URL, sessionLease: VaultSessionLease, accessGate: VaultAccessGate,
                canonicalVaultID: UUID, requiredCapabilities: [String] = ["canonicalMetadataV1"],
                createIfMissing: Bool = false) throws {
        try accessGate.validate(lease: sessionLease, targetRoot: sessionLease.root, targetVaultID: canonicalVaultID, operation: "blockStore.openCanonical")
        try SQLiteVaultMigration.requireLocalRoot(sessionLease.root)
        let root = sessionLease.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root), sessionLease.vaultID == canonicalVaultID else { throw VaultError.invalid("Canonical database identity/root mismatch.") }
        self.canonicalVaultID = canonicalVaultID; self.sessionLease = sessionLease; self.accessGate = accessGate
        databaseURL = url.standardizedFileURL.resolvingSymlinksInPath()
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing, canonicalVaultID: canonicalVaultID, requiredCapabilities: requiredCapabilities)
    }
    /// Only explicit staging/test construction may initialize expanded authority.
    init(canonicalStagingURL url: URL, vaultID: UUID,
         requiredCapabilities: [String] = ["canonicalMetadataV1"], createIfMissing: Bool = true) throws {
        canonicalVaultID = vaultID; sessionLease = nil; accessGate = nil
        databaseURL = url.standardizedFileURL.resolvingSymlinksInPath()
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing, canonicalVaultID: vaultID, requiredCapabilities: requiredCapabilities)
    }
    private static func prepare(_ connection: BlockSQLiteConnection, initializeIfNeeded: Bool, canonicalVaultID: UUID? = nil, requiredCapabilities: [String] = []) throws {
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
        if canonicalVaultID != nil {
            guard requiredCapabilities == ["canonicalMetadataV1"], version == 0 || version == expandedSchemaVersion else { throw VaultError.invalid("Canonical authority requires explicit schema 3; existing authority is never upgraded on open.") }
        }
        if canonicalVaultID != nil, version == 0 {
            var tables: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &tables, nil) == SQLITE_OK, let tables else { throw VaultError.invalid("Cannot inspect staging database.") }
            defer { sqlite3_finalize(tables) }
            guard sqlite3_step(tables) == SQLITE_ROW, sqlite3_column_int(tables, 0) == 0 else { throw VaultError.invalid("Canonical staging cannot reinterpret an unversioned database.") }
        }
        guard version >= 0, version <= (canonicalVaultID == nil ? schemaVersion : expandedSchemaVersion) else { throw VaultError.invalid("Unsupported block database schema version.") }
        guard version != 0 || initializeIfNeeded else { throw VaultError.invalid("The block database has no supported schema.") }
        if let canonicalVaultID, version == expandedSchemaVersion {
            var state: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT vault_id,capability,payload_version FROM vault_state WHERE singleton=1", -1, &state, nil) == SQLITE_OK, let state else { throw VaultError.invalid("Canonical vault state missing.") }
            defer { sqlite3_finalize(state) }
            guard sqlite3_step(state) == SQLITE_ROW,
                  sqlite3_column_text(state, 0).map({ String(cString: $0) }) == canonicalVaultID.uuidString,
                  sqlite3_column_text(state, 1).map({ String(cString: $0) }) == "canonicalMetadataV1",
                  sqlite3_column_int(state, 2) == 1 else { throw VaultError.invalid("Canonical identity/capability/payload mismatch.") }
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=1000; PRAGMA temp_store=MEMORY;")
        if version == 0 {
            try exec("BEGIN IMMEDIATE")
            do {
                try exec("""
                CREATE TABLE pages(id TEXT PRIMARY KEY, revision BLOB NOT NULL, metadata BLOB, properties BLOB NOT NULL, trashed INTEGER NOT NULL DEFAULT 0 CHECK(trashed IN (0,1)));
                CREATE TABLE blocks(page_id TEXT NOT NULL, id TEXT NOT NULL, parent_id TEXT, sibling_order INTEGER NOT NULL CHECK(sibling_order>=0), kind TEXT NOT NULL, runs BLOB NOT NULL, semantic BLOB NOT NULL, created_at REAL NOT NULL, modified_at REAL NOT NULL, extensions BLOB NOT NULL, PRIMARY KEY(page_id,id), FOREIGN KEY(page_id) REFERENCES pages(id) ON DELETE CASCADE, FOREIGN KEY(page_id,parent_id) REFERENCES blocks(page_id,id) DEFERRABLE INITIALLY DEFERRED);
                CREATE INDEX block_parent_order ON blocks(page_id,parent_id,sibling_order);
                PRAGMA user_version=1;
                """)
                if canonicalVaultID == nil { try exec("COMMIT") }
            } catch { try? exec("ROLLBACK"); throw error }
            version = 1
        }
        if version == 1 {
            if canonicalVaultID == nil { try exec("BEGIN IMMEDIATE") }
            do {
                // Existing v1 trash has no trustworthy removal date; NULL retains
                // the repository's undated-entry grace rather than inventing one.
                try exec("ALTER TABLE pages ADD COLUMN trashed_at REAL; PRAGMA user_version=2;")
                if canonicalVaultID == nil { try exec("COMMIT") }
            } catch { try? exec("ROLLBACK"); throw error }
            version = 2
        }
        if let canonicalVaultID {
            if version == 2 {
                // Fresh canonical construction retains the original DDL transaction.
                // An existing schema2 was rejected before any DDL/WAL changes.
                do {
                    try exec(canonicalSchema)
                    var insert: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "INSERT INTO vault_state(singleton,vault_id,capability,payload_version,revision,extensions) VALUES(1,?, 'canonicalMetadataV1',1,?, '{}')", -1, &insert, nil) == SQLITE_OK, let insert else { throw VaultError.storage("Cannot initialize canonical identity.") }
                    defer { sqlite3_finalize(insert) }
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    sqlite3_bind_text(insert, 1, canonicalVaultID.uuidString, -1, transient)
                    sqlite3_bind_text(insert, 2, UUID().uuidString, -1, transient)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw VaultError.storage("Cannot initialize canonical identity.") }
                    try exec("PRAGMA user_version=3; COMMIT")
                } catch { try? exec("ROLLBACK"); throw error }
            }
            var state: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT vault_id,capability,payload_version FROM vault_state WHERE singleton=1", -1, &state, nil) == SQLITE_OK, let state else { throw VaultError.invalid("Canonical vault state missing.") }
            defer { sqlite3_finalize(state) }
            guard sqlite3_step(state) == SQLITE_ROW,
                  sqlite3_column_text(state, 0).map({ String(cString: $0) }) == canonicalVaultID.uuidString,
                  sqlite3_column_text(state, 1).map({ String(cString: $0) }) == "canonicalMetadataV1",
                  sqlite3_column_int(state, 2) == 1 else { throw VaultError.invalid("Canonical identity/capability/payload mismatch.") }
        }
    }
    private static let canonicalSchema = """
    CREATE TABLE vault_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), vault_id TEXT NOT NULL, capability TEXT NOT NULL, payload_version INTEGER NOT NULL, revision BLOB NOT NULL, extensions BLOB NOT NULL);
    CREATE TABLE sources(id TEXT PRIMARY KEY, revision BLOB NOT NULL, ownership TEXT NOT NULL CHECK(ownership IN ('imported','linked','unavailable')), payload_version INTEGER NOT NULL, required_features BLOB NOT NULL, metadata BLOB NOT NULL, blob_path TEXT, checksum TEXT, byte_size INTEGER, linked_reference BLOB, trashed INTEGER NOT NULL DEFAULT 0 CHECK(trashed IN (0,1)), trashed_at REAL);
    CREATE TABLE page_sources(page_id TEXT NOT NULL, source_id TEXT NOT NULL, source_order INTEGER NOT NULL CHECK(source_order>=0), PRIMARY KEY(page_id,source_id), UNIQUE(page_id,source_order), FOREIGN KEY(page_id) REFERENCES pages(id) ON DELETE CASCADE, FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE RESTRICT);
    CREATE TABLE tombstones(entity_id TEXT NOT NULL, entity_kind TEXT NOT NULL CHECK(entity_kind IN ('page','source')), last_revision BLOB NOT NULL, deleted_at REAL NOT NULL, disposition TEXT NOT NULL, PRIMARY KEY(entity_id,entity_kind));
    CREATE TABLE conflicts(id TEXT PRIMARY KEY, target_id TEXT NOT NULL, target_kind TEXT NOT NULL CHECK(target_kind IN ('page','source')), base_revision BLOB, payload_version INTEGER NOT NULL, preserved_payload BLOB NOT NULL, created_at REAL NOT NULL, disposition TEXT NOT NULL, revision BLOB NOT NULL);
    CREATE TABLE committed_operations(operation_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, source_revision BLOB NOT NULL, page_id TEXT, page_revision BLOB, vault_revision BLOB NOT NULL);
    """
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
        try Task.checkCancellation()
        try validate("blockStore.write"); try run("BEGIN IMMEDIATE")
        do {
            try publication?()
            let value = try operation()
            try Task.checkCancellation()
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
        var extensions: PersistencePayload?; var unknownFields: [String: JSONValue]?
        init(_ block: EditorBlock) { originalMarkdown = block.originalMarkdown; originalSignature = block.originalSignature; originalIndentation = block.originalIndentation; originalDepth = block.originalDepth; extensions = block.extensions; unknownFields = block.unknownFields.isEmpty ? nil : block.unknownFields }
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
            block.extensions = extra.extensions; block.unknownFields = extra.unknownFields ?? [:]
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
        if canonicalVaultID != nil { try document.validateWritablePayloads() }
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
            if canonicalVaultID != nil { try rejectTombstoned(pageID, kind: .page) }
            let statement = try statement("SELECT 1 FROM pages WHERE id=?", [.text(pageID.uuidString)]); defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { throw VaultError.conflict("Block page already exists.") }
            guard status == SQLITE_DONE else { throw failure() }; current = nil
        case .replace(let expected):
            current = try load(pageID: pageID)
            guard current?.revision == expected else { throw VaultError.conflict("Block page revision changed.") }
        }
        var document = document
        if let current { document = document.preparingAnnotationsForPersistence(comparedTo: current.document) }
        if canonicalVaultID != nil {
            try document.validateWritablePayloads()
            try document.validatingAnnotations(pageID: pageID, expectedRevision: current?.revision)
        } else {
            guard document.extensions == nil, document.flattened.allSatisfy({ block in
                block.extensions == nil && block.metadata.extensions == nil && block.runs.allSatisfy { $0.extensions == nil && $0.style.extensions == nil }
            }) else { throw VaultError.invalid("Versioned extensions require explicit canonical schema 3.") }
        }
        let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
        if canonicalVaultID != nil { document = document.advancingAnnotationRevision(to: revision) }
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
        if canonicalVaultID != nil, current == nil { _ = try advanceVaultRevision() }
        return .init(pageID: pageID, document: document, revision: revision)
    }
    public func savePage(record: NoteRecord, document: BlockDocument, condition: BlockStoreWriteCondition, validating publication: (@Sendable () throws -> Void)? = nil) throws -> BlockStoreSnapshot {
        try transaction(validating: publication) { try savePageInTransaction(record: record, document: document, condition: condition) }
    }
    private func savePageInTransaction(record: NoteRecord, document: BlockDocument, condition: BlockStoreWriteCondition) throws -> BlockStoreSnapshot {
        try record.extensions?.validateWritable(); try validateOptionalFields(record.unknownFields)
        guard canonicalVaultID != nil || record.extensions == nil else { throw VaultError.invalid("Page extensions require canonical schema 3.") }
        var metadata = record; metadata.body = ""; metadata.contentHash = ""
        if canonicalVaultID != nil { metadata.sourceIDs = nil }
        let snapshot = try persist(document, pageID: record.id, condition: condition, metadata: encoder.encode(metadata))
        if canonicalVaultID != nil { try replaceSourceLinks(pageID: record.id, sourceIDs: record.linkedSourceIDs) }
        return snapshot
    }
    public func loadPage(pageID: UUID) throws -> (record: NoteRecord, snapshot: BlockStoreSnapshot) {
        try readTransaction { try loadPageInTransaction(pageID: pageID) }
    }
    private func loadPageInTransaction(pageID: UUID) throws -> (record: NoteRecord, snapshot: BlockStoreSnapshot) {
        let snapshot = try load(pageID: pageID)
        let statement = try statement("SELECT metadata,trashed,trashed_at FROM pages WHERE id=?", [.text(pageID.uuidString)]); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { throw VaultError.unavailable("Page metadata missing.") }
        var record = try decoder.decode(NoteRecord.self, from: blob(statement, 0))
        if canonicalVaultID != nil { record.sourceIDs = try sourceLinks(pageID: pageID) }
        guard record.id == pageID else { throw VaultError.invalid("Page metadata identity does not match its record.") }
        var portableDocument = snapshot.document
        if !portableDocument.unsupportedVersion { portableDocument.originalSource = nil }
        record.body = BlockDocumentCodec.encode(portableDocument); record.contentHash = snapshot.revision.token.base64EncodedString()
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
        guard canonicalVaultID == nil else { throw VaultError.invalid("Canonical purge requires lifecycle and collection revisions.") }
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
            var document = current.document
            if canonicalVaultID != nil {
                document = document.advancingAnnotationRevision(to: revision)
                var properties = document; properties.blocks = []
                try run("UPDATE pages SET properties=? WHERE id=?", [.blob(try encoder.encode(properties)), .text(pageID.uuidString)])
            }
            try run("UPDATE pages SET trashed=?,trashed_at=?,revision=? WHERE id=?", [.integer(trashed ? 1 : 0), trashed ? .real(Date().timeIntervalSince1970) : .null, .blob(revision.token), .text(pageID.uuidString)])
            return .init(pageID: pageID, document: document, revision: revision)
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
    private func requireCanonical() throws {
        guard canonicalVaultID != nil else { throw VaultError.invalid("Canonical metadata requires explicitly admitted schema 3.") }
    }
    public func canonicalVaultRevision() throws -> BlockStoreRevision {
        try requireCanonical()
        return try readTransaction { try vaultRevision() }
    }
    private func vaultRevision() throws -> BlockStoreRevision {
        let statement = try statement("SELECT revision FROM vault_state WHERE singleton=1"); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return .init(token: blob(statement, 0))
    }
    private func advanceVaultRevision() throws -> BlockStoreRevision {
        let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
        try run("UPDATE vault_state SET revision=? WHERE singleton=1", [.blob(revision.token)])
        return revision
    }
    private func rejectTombstoned(_ id: UUID, kind: CanonicalEntityKind) throws {
        let statement = try statement("SELECT 1 FROM tombstones WHERE entity_id=? AND entity_kind=?", [.text(id.uuidString), .text(kind.rawValue)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw VaultError.conflict("Deleted canonical identities cannot be reused.") }
    }
    public func sourceSnapshot(id: UUID) throws -> CanonicalSourceSnapshot {
        try requireCanonical()
        return try readTransaction { try sourceInTransaction(id: id) }
    }
    private func sourceInTransaction(id: UUID) throws -> CanonicalSourceSnapshot {
        let statement = try statement("SELECT revision,ownership,payload_version,required_features,metadata,trashed,trashed_at FROM sources WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw VaultError.unavailable("Canonical source identity missing.") }
        guard status == SQLITE_ROW, let ownership = CanonicalSourceOwnership(rawValue: text(statement, 1)) else { throw failure() }
        let source = CanonicalSource(id: id, ownership: ownership, metadata: blob(statement, 4), payloadVersion: Int(sqlite3_column_int(statement, 2)), requiredFeatures: try decoder.decode([String].self, from: blob(statement, 3)))
        try source.validateWritable()
        return .init(source: source, revision: .init(token: blob(statement, 0)), trashed: sqlite3_column_int(statement, 5) == 1,
                     trashedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)))
    }
    private func persistSource(_ source: CanonicalSource, condition: BlockStoreWriteCondition) throws -> BlockStoreRevision {
        try source.validateWritable()
        // Missing immutable-byte flush/rename or scoped linked-access evidence must
        // never be represented by a caller-provided checksum as successful receipt.
        guard source.ownership == .unavailable else { throw VaultError.invalid("Imported and linked publication requires verified durability/access receipts; this foundation accepts unavailable identities only.") }
        switch condition {
        case .createOnly:
            try rejectTombstoned(source.id, kind: .source)
            let statement = try statement("SELECT 1 FROM sources WHERE id=?", [.text(source.id.uuidString)]); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw VaultError.conflict("Canonical source already exists.") }
        case .replace(let expected):
            let existing = try sourceInTransaction(id: source.id)
            guard existing.revision == expected, existing.source.ownership == source.ownership else { throw VaultError.conflict("Canonical source revision or ownership changed.") }
        }
        let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
        switch condition {
        case .createOnly:
            try run("INSERT INTO sources(id,revision,ownership,payload_version,required_features,metadata) VALUES(?,?,?,?,?,?)", [.text(source.id.uuidString), .blob(revision.token), .text(source.ownership.rawValue), .integer(Int64(source.payloadVersion)), .blob(try encoder.encode(source.requiredFeatures)), .blob(source.metadata)])
        case .replace:
            try run("UPDATE sources SET revision=?,payload_version=?,required_features=?,metadata=? WHERE id=?", [.blob(revision.token), .integer(Int64(source.payloadVersion)), .blob(try encoder.encode(source.requiredFeatures)), .blob(source.metadata), .text(source.id.uuidString)])
        }
        return revision
    }
    private func replaceSourceLinks(pageID: UUID, sourceIDs: [UUID]) throws {
        guard Set(sourceIDs).count == sourceIDs.count else { throw VaultError.invalid("Duplicate source relationship.") }
        try run("DELETE FROM page_sources WHERE page_id=?", [.text(pageID.uuidString)])
        for (order, id) in sourceIDs.enumerated() {
            _ = try sourceInTransaction(id: id)
            try run("INSERT INTO page_sources(page_id,source_id,source_order) VALUES(?,?,?)", [.text(pageID.uuidString), .text(id.uuidString), .integer(Int64(order))])
        }
    }
    private func sourceLinks(pageID: UUID) throws -> [UUID] {
        let statement = try statement("SELECT source_id,source_order FROM page_sources WHERE page_id=? ORDER BY source_order", [.text(pageID.uuidString)])
        defer { sqlite3_finalize(statement) }
        var ids: [UUID] = []
        while true {
            let status = sqlite3_step(statement); if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)), sqlite3_column_int64(statement, 1) == Int64(ids.count) else { throw VaultError.invalid("Invalid source relationship order or identity.") }
            ids.append(id)
        }
        return ids
    }
    public func committedOperation(id: UUID) throws -> CanonicalPublicationOutcome? {
        try requireCanonical()
        return try readTransaction { try operationInTransaction(id: id) }
    }
    private func operationInTransaction(id: UUID) throws -> CanonicalPublicationOutcome? {
        let statement = try statement("SELECT source_id,source_revision,page_id,page_revision,vault_revision FROM committed_operations WHERE operation_id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement); if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let sourceID = UUID(uuidString: text(statement, 0)) else { throw failure() }
        let pageID = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : UUID(uuidString: text(statement, 2))
        return .init(operationID: id, sourceID: sourceID, sourceRevision: .init(token: blob(statement, 1)), pageID: pageID,
                     pageRevision: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : .init(token: blob(statement, 3)), vaultRevision: .init(token: blob(statement, 4)))
    }
    /// Durable success is COMMIT. Callers reconcile an uncertain return using the
    /// operation identity rather than retrying a create as a different operation.
    public func publishSourceAndPage(source: CanonicalSource, condition: BlockStoreWriteCondition,
                                     page: CanonicalPagePublication? = nil, operationID: UUID,
                                     expectedVaultRevision: BlockStoreRevision,
                                     validating publication: (@Sendable () throws -> Void)? = nil) throws -> CanonicalPublicationOutcome {
        try requireCanonical()
        return try transaction(validating: publication) {
            guard try operationInTransaction(id: operationID) == nil else { throw VaultError.conflict("Operation already committed; inspect its outcome.") }
            guard try vaultRevision() == expectedVaultRevision else { throw VaultError.conflict("Canonical collection changed.") }
            let sourceRevision = try persistSource(source, condition: condition)
            var snapshot: BlockStoreSnapshot?
            if let page { snapshot = try savePageInTransaction(record: page.record, document: page.document, condition: page.condition) }
            let vaultRevision: BlockStoreRevision
            if case .createOnly = condition { vaultRevision = try advanceVaultRevision() }
            else { vaultRevision = try self.vaultRevision() }
            try run("INSERT INTO committed_operations(operation_id,source_id,source_revision,page_id,page_revision,vault_revision) VALUES(?,?,?,?,?,?)", [.text(operationID.uuidString), .text(source.id.uuidString), .blob(sourceRevision.token), snapshot.map { .text($0.pageID.uuidString) } ?? .null, snapshot.map { .blob($0.revision.token) } ?? .null, .blob(vaultRevision.token)])
            return .init(operationID: operationID, sourceID: source.id, sourceRevision: sourceRevision, pageID: snapshot?.pageID, pageRevision: snapshot?.revision, vaultRevision: vaultRevision)
        }
    }
    public func tombstone(id: UUID, kind: CanonicalEntityKind) throws -> CanonicalTombstone? {
        try requireCanonical()
        return try readTransaction {
            let statement = try statement("SELECT last_revision,deleted_at,disposition FROM tombstones WHERE entity_id=? AND entity_kind=?", [.text(id.uuidString), .text(kind.rawValue)]); defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement); if status == SQLITE_DONE { return nil }; guard status == SQLITE_ROW else { throw failure() }
            return .init(id: id, kind: kind, lastRevision: .init(token: blob(statement, 0)), deletedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), disposition: text(statement, 2))
        }
    }
    /// Purge is available only for already trashed pages and unavailable sources
    /// without live relationships. Owned-byte deletion remains outside this API.
    public func purgeCanonicalEntity(id: UUID, kind: CanonicalEntityKind, expected: BlockStoreRevision,
                                     expectedVaultRevision: BlockStoreRevision,
                                     validating publication: (@Sendable () throws -> Void)? = nil) throws {
        try requireCanonical()
        try transaction(validating: publication) {
            guard try vaultRevision() == expectedVaultRevision else { throw VaultError.conflict("Canonical collection changed.") }
            switch kind {
            case .page:
                let current = try loadDocument(pageID: id)
                guard current.revision == expected else { throw VaultError.conflict("Page revision changed.") }
                let statement = try statement("SELECT trashed FROM pages WHERE id=?", [.text(id.uuidString)]); defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 else { throw VaultError.invalid("Only a trashed page can be purged.") }
            case .source:
                let current = try sourceInTransaction(id: id)
                guard current.revision == expected else { throw VaultError.conflict("Source revision changed.") }
                guard current.trashed, current.source.ownership == .unavailable else { throw VaultError.invalid("Only a trashed unavailable source can be purged without a preservation receipt.") }
            }
            try run("INSERT INTO tombstones(entity_id,entity_kind,last_revision,deleted_at,disposition) VALUES(?,?,?,?,?)", [.text(id.uuidString), .text(kind.rawValue), .blob(expected.token), .real(Date().timeIntervalSince1970), .text("purged")])
            try run(kind == .page ? "DELETE FROM pages WHERE id=?" : "DELETE FROM sources WHERE id=?", [.text(id.uuidString)])
            _ = try advanceVaultRevision()
        }
    }
    @discardableResult public func setSourceTrashed(id: UUID, expected: BlockStoreRevision, trashed: Bool,
                                                   validating publication: (@Sendable () throws -> Void)? = nil) throws -> CanonicalSourceSnapshot {
        try requireCanonical()
        return try transaction(validating: publication) {
            guard try sourceInTransaction(id: id).revision == expected else { throw VaultError.conflict("Source revision changed.") }
            try run("UPDATE sources SET trashed=?,trashed_at=?,revision=? WHERE id=?", [.integer(trashed ? 1 : 0), trashed ? .real(Date().timeIntervalSince1970) : .null, .blob(Data(UUID().uuidString.utf8)), .text(id.uuidString)])
            return try sourceInTransaction(id: id)
        }
    }
    public func checkpoint() throws {
        try validate("blockStore.checkpoint")
        let statement = try statement("PRAGMA wal_checkpoint(TRUNCATE)"); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else { throw failure() }
    }
    /// An explicit portable snapshot; copying an open database/WAL is unsupported.
    /// A new destination outside the canonical vault is reserved without overwriting.
    public func backup(to destination: URL) throws {
        try Task.checkCancellation()
        try validate("blockStore.backup")
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard target != databaseURL else { throw VaultError.invalid("Backup cannot replace the canonical database.") }
        if let sessionLease {
            let root = sessionLease.root.standardizedFileURL.resolvingSymlinksInPath()
            guard target != root, !target.path.hasPrefix(root.path + "/") else {
                throw VaultError.invalid("Choose a backup destination outside the canonical vault.")
            }
        }
        try Data().write(to: target, options: .withoutOverwriting)
        let output = try BlockSQLiteConnection(url: target, createIfMissing: false)
        guard let destinationDB = output.pointer,
              let backup = sqlite3_backup_init(destinationDB, "main", try db, "main") else {
            throw VaultError.storage("Could not initialize database backup.")
        }
        // This actor holds no suspension point during snapshot transfer. SQLite's
        // backup API includes committed WAL content and rolls back incomplete copies.
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw VaultError.storage("Database backup did not complete (\(result), \(finished)).")
        }
        try validate("blockStore.backup")
        try Task.checkCancellation()
        guard sqlite3_close(destinationDB) == SQLITE_OK else { throw VaultError.storage("Could not close database backup.") }
        output.pointer = nil
    }

    /// Resource retirement remains permitted after the session lease is revoked.
    /// SQLite owns journal cleanup; callers must never unlink WAL/SHM themselves.
    public func close() throws {
        guard let pointer = connection.pointer else { return }
        guard sqlite3_close(pointer) == SQLITE_OK else { throw failure() }
        connection.pointer = nil
    }
}
