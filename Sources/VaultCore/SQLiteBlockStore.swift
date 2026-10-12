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

public actor SQLiteBlockStore: BlockStore, KnowledgeStore, SemanticStore {
    public nonisolated let mode = BlockStorageMode.sqliteBlocks
    public nonisolated let sessionLease: VaultSessionLease?
    public nonisolated let accessGate: VaultAccessGate?
    private let databaseURL: URL
    private let connection: BlockSQLiteConnection
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()
    private let decoder = JSONDecoder()
    public static let schemaVersion = 2
    public static let expandedSchemaVersion = 3
    public static let semanticSchemaVersion = 5
    public static let semanticRequiredCapabilities = ["canonicalKnowledgeV1", "canonicalMetadataV1", "semanticAnnotationsV1"]
    public static let knowledgeSchemaVersion = 4
    public static let knowledgeRequiredCapabilities = ["canonicalKnowledgeV1", "canonicalMetadataV1"]
    private let canonicalVaultID: UUID?
    private let operationValidation: (@Sendable () throws -> Void)?

    /// Disposable page-store tests have no admitted session; no production caller uses this route.
    /// Callers must separately establish a safe local staging target.
    init(unguardedTestingURL url: URL, createIfMissing: Bool = true) throws {
        canonicalVaultID = nil; operationValidation = nil
        sessionLease = nil; accessGate = nil
        databaseURL = url.standardizedFileURL.resolvingSymlinksInPath()
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing)
    }
    /// Expanded authority is opt-in and cannot reinterpret an existing page-only DB.
    init(url: URL, sessionLease: VaultSessionLease, accessGate: VaultAccessGate,
                canonicalVaultID: UUID, requiredCapabilities: [String] = semanticRequiredCapabilities, schemaVersion: Int = semanticSchemaVersion,
                createIfMissing: Bool = false) throws {
        guard schemaVersion == Self.semanticSchemaVersion, !createIfMissing else { throw VaultError.invalid("Production admission requires an existing schema-5 database.") }
        try Self.validateCanonicalDeclaration(schemaVersion: schemaVersion, capabilities: requiredCapabilities)
        try accessGate.validate(lease: sessionLease, targetRoot: sessionLease.root, targetVaultID: canonicalVaultID, operation: "blockStore.openCanonical")
        try SQLiteVaultLocality.requireLocalRoot(sessionLease.root)
        let root = sessionLease.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root), sessionLease.vaultID == canonicalVaultID else { throw VaultError.invalid("Canonical database identity/root mismatch.") }
        operationValidation = nil
        self.canonicalVaultID = canonicalVaultID; self.sessionLease = sessionLease; self.accessGate = accessGate
        databaseURL = url.standardizedFileURL.resolvingSymlinksInPath()
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing, canonicalVaultID: canonicalVaultID, requiredCapabilities: requiredCapabilities, expectedSchemaVersion: schemaVersion)
    }
    /// Only explicit staging/test construction may initialize expanded authority.
    init(canonicalStagingURL url: URL, vaultID: UUID,
         requiredCapabilities: [String] = ["canonicalMetadataV1"], schemaVersion: Int = 3, createIfMissing: Bool = true,
         validating operation: (@Sendable () throws -> Void)? = nil) throws {
        try operation?()
        operationValidation = operation
        try Self.validateCanonicalDeclaration(schemaVersion: schemaVersion, capabilities: requiredCapabilities)
        canonicalVaultID = vaultID; sessionLease = nil; accessGate = nil
        databaseURL = url.standardizedFileURL.resolvingSymlinksInPath()
        connection = try BlockSQLiteConnection(url: url, createIfMissing: createIfMissing)
        try Self.prepare(connection, initializeIfNeeded: createIfMissing, canonicalVaultID: vaultID, requiredCapabilities: requiredCapabilities, expectedSchemaVersion: schemaVersion, validating: operation)
        try operation?()
    }
    private static func validateCanonicalDeclaration(schemaVersion: Int, capabilities: [String]) throws {
        let expected: [String]
        switch schemaVersion {
        case 3: expected = ["canonicalMetadataV1"]
        case knowledgeSchemaVersion: expected = knowledgeRequiredCapabilities
        case semanticSchemaVersion: expected = semanticRequiredCapabilities
        default: throw VaultError.invalid("Unsupported canonical schema declaration.")
        }
        guard capabilities == expected else { throw VaultError.invalid("Unsupported canonical capabilities.") }
    }
    private static func prepare(_ connection: BlockSQLiteConnection, initializeIfNeeded: Bool, canonicalVaultID: UUID? = nil, requiredCapabilities: [String] = [], expectedSchemaVersion: Int = 3, validating operation: (@Sendable () throws -> Void)? = nil) throws {
        try operation?()
        guard let db = connection.pointer else { throw VaultError.storage("Block database closed.") }
        func exec(_ sql: String) throws {
            try operation?()
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw VaultError.storage(String(cString: sqlite3_errmsg(db))) }
            try operation?()
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
        let version = try readVersion()
        if canonicalVaultID != nil {
            guard (expectedSchemaVersion == 3 && requiredCapabilities == ["canonicalMetadataV1"]) || (expectedSchemaVersion == 4 && requiredCapabilities == knowledgeRequiredCapabilities) || (expectedSchemaVersion == 5 && requiredCapabilities == semanticRequiredCapabilities) else { throw VaultError.invalid("Unsupported canonical schema/capability declaration.") }
            guard version == 0 || version == expectedSchemaVersion else { throw VaultError.invalid("Canonical authority transition required; existing authority is never upgraded on open.") }
        }
        if canonicalVaultID != nil, version == 0 {
            var tables: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &tables, nil) == SQLITE_OK, let tables else { throw VaultError.invalid("Cannot inspect staging database.") }
            defer { sqlite3_finalize(tables) }
            guard sqlite3_step(tables) == SQLITE_ROW, sqlite3_column_int(tables, 0) == 0 else { throw VaultError.invalid("Canonical staging cannot reinterpret an unversioned database.") }
        }
        guard version == 0 || version == (canonicalVaultID == nil ? schemaVersion : expectedSchemaVersion) else { throw VaultError.invalid("Unsupported block database schema version.") }
        guard version != 0 || initializeIfNeeded else { throw VaultError.invalid("The block database has no supported schema.") }
        if let canonicalVaultID, version == expectedSchemaVersion {
            var state: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT vault_id,capability,payload_version FROM vault_state WHERE singleton=1", -1, &state, nil) == SQLITE_OK, let state else { throw VaultError.invalid("Canonical vault state missing.") }
            defer { sqlite3_finalize(state) }
            guard sqlite3_step(state) == SQLITE_ROW,
                  sqlite3_column_text(state, 0).map({ String(cString: $0) }) == canonicalVaultID.uuidString,
                  sqlite3_column_text(state, 1).map({ String(cString: $0) }) == "canonicalMetadataV1",
                  sqlite3_column_int(state, 2) == 1 else { throw VaultError.invalid("Canonical identity/capability/payload mismatch.") }
            if expectedSchemaVersion >= 4 { try validateKnowledgeCapabilities(db, expected: requiredCapabilities) }
            if expectedSchemaVersion == 5 { try validateSemanticRegistry(db) }
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=1000; PRAGMA temp_store=MEMORY;")
        if version == 0 {
            try exec("BEGIN IMMEDIATE")
            do {
                try exec(pageSchema)
                if let canonicalVaultID {
                    var schema = canonicalSchema
                    if expectedSchemaVersion >= 4 {
                        schema = schema.replacingOccurrences(of: "extensions BLOB NOT NULL);", with: "extensions BLOB NOT NULL, required_capabilities BLOB NOT NULL);")
                    }
                    try exec(schema)
                    var insert: OpaquePointer?
                    let sql = expectedSchemaVersion >= 4
                        ? "INSERT INTO vault_state(singleton,vault_id,capability,payload_version,revision,extensions,required_capabilities) VALUES(1,?, 'canonicalMetadataV1',1,?, '{}',?)"
                        : "INSERT INTO vault_state(singleton,vault_id,capability,payload_version,revision,extensions) VALUES(1,?, 'canonicalMetadataV1',1,?, '{}')"
                    guard sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK, let insert else { throw VaultError.storage("Cannot initialize canonical identity.") }
                    defer { sqlite3_finalize(insert) }
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    sqlite3_bind_text(insert, 1, canonicalVaultID.uuidString, -1, transient)
                    sqlite3_bind_text(insert, 2, UUID().uuidString, -1, transient)
                    if expectedSchemaVersion >= 4 {
                        let capabilities = try JSONEncoder().encode(requiredCapabilities)
                        _ = capabilities.withUnsafeBytes { sqlite3_bind_blob(insert, 3, $0.baseAddress, Int32(capabilities.count), transient) }
                        try exec(knowledgeSchema)
                    }
                    if expectedSchemaVersion == 5 { try exec(semanticSchema) }
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw VaultError.storage("Cannot initialize canonical identity.") }
                }
                let finalVersion = canonicalVaultID == nil ? schemaVersion : expectedSchemaVersion
                try exec("PRAGMA user_version=\(finalVersion); COMMIT")
            } catch { try? exec("ROLLBACK"); throw error }
        }
        if canonicalVaultID != nil, expectedSchemaVersion >= 4 {
            try validateKnowledgeCapabilities(db, expected: requiredCapabilities)
            if expectedSchemaVersion == 5 { try validateSemanticRegistry(db) }
        }
    }
    private static let pageSchema = """
    CREATE TABLE pages(id TEXT PRIMARY KEY, revision BLOB NOT NULL, metadata BLOB, properties BLOB NOT NULL, trashed INTEGER NOT NULL DEFAULT 0 CHECK(trashed IN (0,1)), trashed_at REAL);
    CREATE TABLE blocks(page_id TEXT NOT NULL, id TEXT NOT NULL, parent_id TEXT, sibling_order INTEGER NOT NULL CHECK(sibling_order>=0), kind TEXT NOT NULL, runs BLOB NOT NULL, semantic BLOB NOT NULL, created_at REAL NOT NULL, modified_at REAL NOT NULL, extensions BLOB NOT NULL, PRIMARY KEY(page_id,id), FOREIGN KEY(page_id) REFERENCES pages(id) ON DELETE CASCADE, FOREIGN KEY(page_id,parent_id) REFERENCES blocks(page_id,id) DEFERRABLE INITIALLY DEFERRED);
    CREATE INDEX block_parent_order ON blocks(page_id,parent_id,sibling_order);
    """
    private static let canonicalSchema = """
    CREATE TABLE vault_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), vault_id TEXT NOT NULL, capability TEXT NOT NULL, payload_version INTEGER NOT NULL, revision BLOB NOT NULL, extensions BLOB NOT NULL);
    CREATE TABLE sources(id TEXT PRIMARY KEY, revision BLOB NOT NULL, ownership TEXT NOT NULL CHECK(ownership IN ('imported','linked','unavailable')), payload_version INTEGER NOT NULL, required_features BLOB NOT NULL, metadata BLOB NOT NULL, blob_path TEXT, checksum TEXT, byte_size INTEGER, linked_reference BLOB, trashed INTEGER NOT NULL DEFAULT 0 CHECK(trashed IN (0,1)), trashed_at REAL);
    CREATE TABLE page_sources(page_id TEXT NOT NULL, source_id TEXT NOT NULL, source_order INTEGER NOT NULL CHECK(source_order>=0), PRIMARY KEY(page_id,source_id), UNIQUE(page_id,source_order), FOREIGN KEY(page_id) REFERENCES pages(id) ON DELETE CASCADE, FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE RESTRICT);
    CREATE TABLE tombstones(entity_id TEXT NOT NULL, entity_kind TEXT NOT NULL CHECK(entity_kind IN ('page','source')), last_revision BLOB NOT NULL, deleted_at REAL NOT NULL, disposition TEXT NOT NULL, PRIMARY KEY(entity_id,entity_kind));
    CREATE TABLE conflicts(id TEXT PRIMARY KEY, target_id TEXT NOT NULL, target_kind TEXT NOT NULL CHECK(target_kind IN ('page','source')), base_revision BLOB, payload_version INTEGER NOT NULL, preserved_payload BLOB NOT NULL, created_at REAL NOT NULL, disposition TEXT NOT NULL, revision BLOB NOT NULL);
    CREATE TABLE committed_operations(operation_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, source_revision BLOB NOT NULL, page_id TEXT, page_revision BLOB, vault_revision BLOB NOT NULL);
    """
    private static func validateKnowledgeCapabilities(_ db: OpaquePointer, expected: [String]) throws {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT required_capabilities FROM vault_state WHERE singleton=1", -1, &query, nil) == SQLITE_OK, let query else { throw VaultError.invalid("Knowledge capabilities missing.") }
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw VaultError.invalid("Knowledge capabilities missing.") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
        guard let capabilities = try? JSONDecoder().decode([String].self, from: data), capabilities == expected else { throw VaultError.invalid("Knowledge capability mismatch.") }
        for (table, keys) in [("knowledge_entity_types", ["concept", "person", "place"]), ("knowledge_relation_types", ["relatedTo"])] {
            var registry: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT key,version,descriptor FROM \(table) ORDER BY key", -1, &registry, nil) == SQLITE_OK, let registry else { throw VaultError.invalid("Knowledge registry missing.") }
            defer { sqlite3_finalize(registry) }
            var stored: [String] = []
            while true { let status = sqlite3_step(registry); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW, sqlite3_column_int(registry, 1) == 1, let key = sqlite3_column_text(registry, 0) else { throw VaultError.invalid("Unsupported required knowledge registry.") }; let storedKey = String(cString: key); guard !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.invalid("Empty knowledge registry key.") }; try validateRegistryDescriptor(registry, column: 2, expectedKey: storedKey); stored.append(storedKey) }
            guard Set(keys).isSubset(of: Set(stored)) else { throw VaultError.invalid("Unsupported required knowledge registry.") }
        }

    }
    private static func validateRegistryDescriptor(_ statement: OpaquePointer, column: Int32, expectedKey: String? = nil) throws {
        guard let bytes = sqlite3_column_blob(statement, column) else { throw VaultError.invalid("Missing registry descriptor.") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        guard data.count <= 262_144, let fields = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { throw VaultError.invalid("Malformed registry descriptor.") }
        try validateOptionalFields(fields)
        if let key = fields["key"], let expectedKey, key != .string(expectedKey) { throw VaultError.invalid("Registry descriptor identity mismatch.") }
        if let metadata = fields["metadata"] {
            do {
                let payload = try JSONDecoder().decode(PersistencePayload.self, from: JSONEncoder().encode(metadata))
                try payload.validateWritable()
            } catch { throw VaultError.invalid("Unsupported registry metadata payload.") }
        }
        for key in ["version", "payloadVersion"] { if let version = fields[key], version != .number(1) { throw VaultError.invalid("Unsupported registry payload version.") } }
        if let required = fields["requiredFeatures"], required != .array([]) { throw VaultError.invalid("Unsupported registry required features.") }
    }
    private static func validateSemanticRegistry(_ db: OpaquePointer) throws {
        var q: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key,version,descriptor FROM semantic_object_types ORDER BY key", -1, &q, nil) == SQLITE_OK, let q else { throw VaultError.invalid("Semantic registry missing.") }
        defer { sqlite3_finalize(q) }
        var keys: [String] = []
        while true { let step = sqlite3_step(q); if step == SQLITE_DONE { break }; guard step == SQLITE_ROW, sqlite3_column_int(q, 1) == 1, let key = sqlite3_column_text(q, 0) else { throw VaultError.invalid("Unsupported semantic registry.") }; try validateRegistryDescriptor(q, column: 2); keys.append(String(cString: key)) }
        guard keys == ["definition", "question"] else { throw VaultError.invalid("Unsupported semantic registry.") }
    }
    private static let knowledgeSchema = """
    CREATE TABLE knowledge_entity_types(key TEXT PRIMARY KEY, version INTEGER NOT NULL, descriptor BLOB NOT NULL);
    CREATE TABLE knowledge_relation_types(key TEXT PRIMARY KEY, version INTEGER NOT NULL, descriptor BLOB NOT NULL);
    INSERT INTO knowledge_entity_types VALUES('person',1,'{}'),('place',1,'{}'),('concept',1,'{}');
    INSERT INTO knowledge_relation_types VALUES('relatedTo',1,'{}');
    CREATE TABLE knowledge_entities(id TEXT PRIMARY KEY, type_key TEXT NOT NULL REFERENCES knowledge_entity_types(key), revision BLOB NOT NULL, lifecycle TEXT NOT NULL CHECK(lifecycle IN ('live','tombstoned')), payload BLOB NOT NULL);
    CREATE TABLE knowledge_entity_aliases(id TEXT PRIMARY KEY, entity_id TEXT NOT NULL REFERENCES knowledge_entities(id) ON DELETE RESTRICT, payload BLOB NOT NULL);
    CREATE TABLE knowledge_relations(id TEXT PRIMARY KEY, predicate TEXT NOT NULL REFERENCES knowledge_relation_types(key), source_id TEXT NOT NULL REFERENCES knowledge_entities(id) ON DELETE RESTRICT, target_id TEXT NOT NULL REFERENCES knowledge_entities(id) ON DELETE RESTRICT, revision BLOB NOT NULL, lifecycle TEXT NOT NULL CHECK(lifecycle IN ('live','tombstoned')), payload BLOB NOT NULL);
    CREATE TABLE knowledge_operations(operation_id TEXT PRIMARY KEY, result_kind TEXT NOT NULL, result_payload BLOB NOT NULL, record_revision BLOB NOT NULL, vault_revision BLOB NOT NULL);
    """
    private static let semanticSchema = """
    CREATE TABLE semantic_object_types(key TEXT PRIMARY KEY, version INTEGER NOT NULL, descriptor BLOB NOT NULL);
    INSERT INTO semantic_object_types VALUES('question',1,'{}'),('definition',1,'{}');
    CREATE TABLE semantic_objects(id TEXT PRIMARY KEY, type_key TEXT NOT NULL REFERENCES semantic_object_types(key), revision BLOB NOT NULL, lifecycle TEXT NOT NULL CHECK(lifecycle IN ('live','tombstoned')), payload BLOB NOT NULL);
    CREATE TABLE semantic_object_entities(object_id TEXT NOT NULL REFERENCES semantic_objects(id) ON DELETE RESTRICT, entity_id TEXT NOT NULL REFERENCES knowledge_entities(id) ON DELETE RESTRICT, designation TEXT NOT NULL CHECK(designation IN ('relatedTo','subject')), PRIMARY KEY(object_id,entity_id,designation));
    CREATE UNIQUE INDEX semantic_single_subject ON semantic_object_entities(object_id) WHERE designation='subject';
    CREATE TABLE semantic_annotations(id TEXT PRIMARY KEY, revision BLOB NOT NULL, location_kind TEXT NOT NULL CHECK(location_kind IN ('wholeBlock','inline','entity','object')), captured_page TEXT, captured_block TEXT, live_page TEXT, live_block TEXT, owner_entity TEXT REFERENCES knowledge_entities(id) ON DELETE RESTRICT, owner_object TEXT REFERENCES semantic_objects(id) ON DELETE RESTRICT, referent_entity TEXT REFERENCES knowledge_entities(id) ON DELETE RESTRICT, referent_object TEXT REFERENCES semantic_objects(id) ON DELETE RESTRICT, payload BLOB NOT NULL, FOREIGN KEY(live_page,live_block) REFERENCES blocks(page_id,id) DEFERRABLE INITIALLY DEFERRED, CHECK((location_kind IN ('wholeBlock','inline') AND captured_page IS NOT NULL AND captured_block IS NOT NULL AND owner_entity IS NULL AND owner_object IS NULL) OR (location_kind='entity' AND owner_entity IS NOT NULL AND captured_page IS NULL AND captured_block IS NULL AND owner_object IS NULL) OR (location_kind='object' AND owner_object IS NOT NULL AND captured_page IS NULL AND captured_block IS NULL AND owner_entity IS NULL)), CHECK(referent_entity IS NULL OR referent_object IS NULL));
    """
    private func validate(_ operation: String) throws {
        try operationValidation?()
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
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: PersistenceCodingKey.self)
            let supported: Set<String> = ["originalMarkdown", "originalSignature", "originalIndentation", "originalDepth", "extensions", "unknownFields"]
            guard values.allKeys.allSatisfy({ supported.contains($0.stringValue) }) else {
                throw VaultError.invalid("Unsupported SQLite block preservation wrapper.")
            }
            originalMarkdown = try values.decodeIfPresent(String.self, forKey: .init("originalMarkdown"))
            originalSignature = try values.decodeIfPresent(String.self, forKey: .init("originalSignature"))
            originalIndentation = try values.decodeIfPresent(String.self, forKey: .init("originalIndentation"))
            originalDepth = try values.decodeIfPresent(Int.self, forKey: .init("originalDepth"))
            extensions = try values.decodeIfPresent(PersistencePayload.self, forKey: .init("extensions"))
            unknownFields = try values.decodeIfPresent([String: JSONValue].self, forKey: .init("unknownFields"))
        }
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
        if try isSemanticSchema() { document = try projectingSemanticAnnotations(document, pageID: pageID) }
        if canonicalVaultID != nil { try document.validateWritablePayloads() }
        try validate("blockStore.load")
        return .init(pageID: pageID, document: document, revision: revision)
    }
    @discardableResult public func save(_ document: BlockDocument, pageID: UUID, condition: BlockStoreWriteCondition) throws -> BlockStoreSnapshot {
        try transaction { try persist(document, pageID: pageID, condition: condition, metadata: nil) }
    }
    private func persist(_ document: BlockDocument, pageID: UUID, condition: BlockStoreWriteCondition, metadata: Data?, semanticProjection: Bool = true) throws -> BlockStoreSnapshot {
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
        if try isSemanticSchema() { properties.extensions?.properties.removeValue(forKey: "annotations") }
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
        if semanticProjection, try isSemanticSchema() { try persistSemanticProjection(document, pageID: pageID, pageRevision: revision, previousRevision: current?.revision) }
        if canonicalVaultID != nil { let semantic = try isSemanticSchema(); if current == nil || (semanticProjection && semantic) { _ = try advanceVaultRevision() } }
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
        if try isSemanticSchema() { properties.extensions?.properties.removeValue(forKey: "annotations") }
                try run("UPDATE pages SET properties=? WHERE id=?", [.blob(try encoder.encode(properties)), .text(pageID.uuidString)])
            }
            try run("UPDATE pages SET trashed=?,trashed_at=?,revision=? WHERE id=?", [.integer(trashed ? 1 : 0), trashed ? .real(Date().timeIntervalSince1970) : .null, .blob(revision.token), .text(pageID.uuidString)])
            if try isSemanticSchema() {
                for snapshot in try annotationRows(pageID: pageID) where snapshot.annotation.anchorDisposition == .resolved {
                    var annotation = snapshot.annotation
                    try validateAnnotationEvidence(annotation, document: current.document, pageRevision: current.revision)
                    annotation.expectedRevision = revision.token
                    if case .inline(let page, let block, var target) = annotation.location {
                        target.digest = InlineAnnotationTarget.evidence(quote: target.quote, revision: revision.token)
                        annotation.location = .inline(pageID: page, blockID: block, target: target)
                    }
                    _ = try persistAnnotation(annotation, document: current.document, expected: snapshot.revision)
                }
                _ = try advanceVaultRevision()
                return try loadDocument(pageID: pageID)
            }
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
    /// Capturing preservation data never grants it authority over a live target.
    public func preserveConflict(_ conflict: CanonicalConflict,
                                 expectedVaultRevision: BlockStoreRevision,
                                 validating publication: (@Sendable () throws -> Void)? = nil) throws -> CanonicalConflictSnapshot {
        try requireCanonical()
        guard conflict.payloadVersion == 1, !conflict.preservedPayload.isEmpty,
              conflict.preservedPayload.count <= 1_048_576 else {
            throw VaultError.invalid("Unsupported or oversized conflict payload.")
        }
        return try transaction(validating: publication) {
            guard try vaultRevision() == expectedVaultRevision else { throw VaultError.conflict("Canonical collection changed.") }
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            try run("INSERT INTO conflicts(id,target_id,target_kind,base_revision,payload_version,preserved_payload,created_at,disposition,revision) VALUES(?,?,?,?,?,?,?,?,?)",
                    [.text(conflict.id.uuidString), .text(conflict.targetID.uuidString), .text(conflict.targetKind.rawValue),
                     conflict.baseRevision.map { .blob($0.token) } ?? .null, .integer(Int64(conflict.payloadVersion)),
                     .blob(conflict.preservedPayload), .real(Date().timeIntervalSince1970), .text("pending"), .blob(revision.token)])
            _ = try advanceVaultRevision()
            return try conflictInTransaction(id: conflict.id)
        }
    }
    public func conflictSnapshot(id: UUID) throws -> CanonicalConflictSnapshot {
        try requireCanonical()
        return try readTransaction { try conflictInTransaction(id: id) }
    }
    private func conflictInTransaction(id: UUID) throws -> CanonicalConflictSnapshot {
        let statement = try statement("SELECT target_id,target_kind,base_revision,payload_version,preserved_payload,created_at,disposition,revision FROM conflicts WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw VaultError.unavailable("Canonical conflict missing.") }
        guard status == SQLITE_ROW, let targetID = UUID(uuidString: text(statement, 0)),
              let kind = CanonicalEntityKind(rawValue: text(statement, 1)),
              let disposition = CanonicalConflictDisposition(rawValue: text(statement, 6)),
              sqlite3_column_int(statement, 3) == 1 else { throw VaultError.invalid("Unsupported conflict record.") }
        let payload = blob(statement, 4)
        guard !payload.isEmpty, payload.count <= 1_048_576 else { throw VaultError.invalid("Invalid conflict preservation payload.") }
        let conflict = CanonicalConflict(id: id, targetID: targetID, targetKind: kind,
            baseRevision: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : .init(token: blob(statement, 2)),
            preservedPayload: payload)
        return .init(conflict: conflict, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                     disposition: disposition, revision: .init(token: blob(statement, 7)))
    }
    /// Target and disposition share one revision-checked transaction. Retention
    /// never removes unique bytes, and unavailable targets can remain retained.
    public func disposeConflict(id: UUID, expected: BlockStoreRevision,
                                disposition: CanonicalConflictDisposition,
                                page: CanonicalPagePublication? = nil,
                                validating publication: (@Sendable () throws -> Void)? = nil) throws -> CanonicalConflictSnapshot {
        try requireCanonical()
        guard disposition != .pending else { throw VaultError.invalid("Choose a conflict disposition.") }
        return try transaction(validating: publication) {
            let current = try conflictInTransaction(id: id)
            guard current.revision == expected else { throw VaultError.conflict("Conflict revision changed.") }
            if disposition == .pagePublished {
                guard let page, current.conflict.targetKind == .page,
                      page.record.id == current.conflict.targetID,
                      case .replace = page.condition else { throw VaultError.invalid("Conflict publication requires its captured page target revision.") }
                _ = try savePageInTransaction(record: page.record, document: page.document, condition: page.condition)
            } else if page != nil { throw VaultError.invalid("Retaining a conflict cannot publish a page.") }
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            try run("UPDATE conflicts SET disposition=?,revision=? WHERE id=?", [.text(disposition.rawValue), .blob(revision.token), .text(id.uuidString)])
            return try conflictInTransaction(id: id)
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
    /// Explicit staging migration preserves the old page revision/lifecycle; live
    /// admitted stores cannot invoke this authority-changing import.
    func importPreservedPage(record: NoteRecord, document: BlockDocument, revision: BlockStoreRevision,
                             trashed: Bool, trashedAt: Date?) throws {
        try requireCanonical()
        guard sessionLease == nil else { throw VaultError.invalid("Preserved import requires explicit staging.") }
        try transaction {
            _ = try savePageInTransaction(record: record, document: document, condition: .createOnly)
            try run("UPDATE pages SET revision=?,trashed=?,trashed_at=? WHERE id=?", [.blob(revision.token), .integer(trashed ? 1 : 0), trashedAt.map { .real($0.timeIntervalSince1970) } ?? .null, .text(record.id.uuidString)])
        }
    }
    public func trashedAt(pageID: UUID) throws -> Date? {
        try readTransaction {
            let query = try statement("SELECT trashed_at FROM pages WHERE id=? AND trashed=1", [.text(pageID.uuidString)])
            defer { sqlite3_finalize(query) }
            let status = sqlite3_step(query)
            guard status == SQLITE_ROW else { if status == SQLITE_DONE { return nil }; throw failure() }
            return sqlite3_column_type(query, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(query, 0))
        }
    }
    public func sourceSnapshot(id: UUID) throws -> CanonicalSourceSnapshot {
        try requireCanonical()
        return try readTransaction { try sourceInTransaction(id: id) }
    }
    private func sourceInTransaction(id: UUID) throws -> CanonicalSourceSnapshot {
        let statement = try statement("SELECT revision,ownership,payload_version,required_features,metadata,trashed,trashed_at,blob_path,checksum,byte_size,linked_reference FROM sources WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw VaultError.unavailable("Canonical source identity missing.") }
        guard status == SQLITE_ROW, let ownership = CanonicalSourceOwnership(rawValue: text(statement, 1)) else { throw failure() }
        var source = CanonicalSource(id: id, ownership: ownership, metadata: blob(statement, 4), payloadVersion: Int(sqlite3_column_int(statement, 2)), requiredFeatures: try decoder.decode([String].self, from: blob(statement, 3)))
        if ownership != .unavailable {
            guard sqlite3_column_type(statement, 8) != SQLITE_NULL, sqlite3_column_type(statement, 9) != SQLITE_NULL else { throw VaultError.invalid("Missing canonical original descriptor.") }
            source.original = .init(blobPath: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : text(statement, 7),
                                    checksum: text(statement, 8), size: Int(sqlite3_column_int64(statement, 9)),
                                    linkedBookmark: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : blob(statement, 10))
        }
        try source.validateWritable()
        return .init(source: source, revision: .init(token: blob(statement, 0)), trashed: sqlite3_column_int(statement, 5) == 1,
                     trashedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)))
    }
    private func persistSource(_ source: CanonicalSource, condition: BlockStoreWriteCondition) throws -> BlockStoreRevision {
        try source.validateWritable()
        switch condition {
        case .createOnly:
            try rejectTombstoned(source.id, kind: .source)
            let statement = try statement("SELECT 1 FROM sources WHERE id=?", [.text(source.id.uuidString)]); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw VaultError.conflict("Canonical source already exists.") }
        case .replace(let expected):
            let existing = try sourceInTransaction(id: source.id)
            guard existing.revision == expected, existing.source.ownership == source.ownership, existing.source.original == source.original else { throw VaultError.conflict("Canonical source revision or ownership changed.") }
        }
        let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
        switch condition {
        case .createOnly:
            try run("INSERT INTO sources(id,revision,ownership,payload_version,required_features,metadata) VALUES(?,?,?,?,?,?)", [.text(source.id.uuidString), .blob(revision.token), .text(source.ownership.rawValue), .integer(Int64(source.payloadVersion)), .blob(try encoder.encode(source.requiredFeatures)), .blob(source.metadata)])
        case .replace:
            try run("UPDATE sources SET revision=?,payload_version=?,required_features=?,metadata=? WHERE id=?", [.blob(revision.token), .integer(Int64(source.payloadVersion)), .blob(try encoder.encode(source.requiredFeatures)), .blob(source.metadata), .text(source.id.uuidString)])
        }
        try run("UPDATE sources SET blob_path=?,checksum=?,byte_size=?,linked_reference=? WHERE id=?", [source.original?.blobPath.map { .text($0) } ?? .null, source.original.map { .text($0.checksum) } ?? .null, source.original.map { .integer(Int64($0.size)) } ?? .null, source.original?.linkedBookmark.map { .blob($0) } ?? .null, .text(source.id.uuidString)])
        return revision
    }
    public func sourceSnapshots(includeTrashed: Bool = false) throws -> [CanonicalSourceSnapshot] {
        try requireCanonical()
        return try readTransaction {
            let query = try statement(includeTrashed ? "SELECT id FROM sources ORDER BY id" : "SELECT id FROM sources WHERE trashed=0 ORDER BY id")
            defer { sqlite3_finalize(query) }
            var result: [CanonicalSourceSnapshot] = []
            while true {
                let status = sqlite3_step(query); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let id = UUID(uuidString: text(query, 0)) else { throw failure() }
                result.append(try sourceInTransaction(id: id))
            }
            return result
        }
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
                                     byteReceipt: CanonicalSourceByteReceipt? = nil,
                                     validating publication: (@Sendable () throws -> Void)? = nil) throws -> CanonicalPublicationOutcome {
        try requireCanonical()
        let validateBytes: @Sendable () throws -> Void = {
            try publication?()
            if source.ownership != .unavailable {
                guard let byteReceipt, let vaultID = self.canonicalVaultID else { throw VaultError.invalid("Verified source receipt required.") }
                try byteReceipt.validate(source: source, vaultID: vaultID, operationID: operationID)
            } else if source.original != nil { throw VaultError.invalid("Unavailable identity cannot invent original bytes.") }
        }
        return try transaction(validating: validateBytes) {
            try validateBytes()
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
                if try isSemanticSchema(), !(try annotationRows(pageID: id)).isEmpty {
                    throw VaultError.invalid("Semantic page purge requires independent annotation preservation.")
                }
                if case .array(let records) = current.document.extensions?.properties["annotations"], !records.isEmpty {
                    throw VaultError.invalid("Annotated page purge requires an explicit preservation operation.")
                }
                let statement = try statement("SELECT trashed FROM pages WHERE id=?", [.text(id.uuidString)]); defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 else { throw VaultError.invalid("Only a trashed page can be purged.") }
            case .source:
                let current = try sourceInTransaction(id: id)
                guard current.revision == expected else { throw VaultError.conflict("Source revision changed.") }
                guard current.trashed else { throw VaultError.invalid("Only a trashed source can be purged; original bytes remain preserved.") }
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
    /// Structural validation supplements identity and required-capability admission.
    public func validateIntegrity() throws {
        try validate("blockStore.integrity")
        let integrity = try statement("PRAGMA integrity_check")
        defer { sqlite3_finalize(integrity) }
        guard sqlite3_step(integrity) == SQLITE_ROW, text(integrity, 0) == "ok",
              sqlite3_step(integrity) == SQLITE_DONE else { throw VaultError.invalid("Canonical database integrity check failed.") }
        let foreignKeys = try statement("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(foreignKeys) }
        guard sqlite3_step(foreignKeys) == SQLITE_DONE else { throw VaultError.invalid("Canonical database relationship integrity check failed.") }
    }

    /// Decode every canonical record from one snapshot. Query/UI limits never
    /// bound archive acceptance; structurally valid SQL can hold invalid payloads.
    public func validateCanonicalLogicalIntegrity(validating operation: (@Sendable () throws -> Void)? = nil) throws {
        try requireCanonical()
        try readTransaction {
            try operation?()
            try validateIntegrity()
            func eachIdentity(_ table: String, _ body: (UUID) throws -> Void) throws {
                let query = try statement("SELECT id FROM \(table) ORDER BY id")
                defer { sqlite3_finalize(query) }
                while true {
                    try Task.checkCancellation(); try validate("blockStore.logicalIntegrity"); try operation?()
                    let status = sqlite3_step(query)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW, let id = UUID(uuidString: text(query, 0)) else { throw VaultError.invalid("Invalid canonical identity in \(table).") }
                    try body(id)
                }
            }
            try eachIdentity("pages") { id in
                let document = try loadDocument(pageID: id)
                let metadata = try statement("SELECT metadata FROM pages WHERE id=?", [.text(id.uuidString)])
                defer { sqlite3_finalize(metadata) }
                guard sqlite3_step(metadata) == SQLITE_ROW else { throw failure() }
                // BlockStore's document-only pages are valid; when repository
                // metadata is present it must satisfy its own payload contract.
                if sqlite3_column_type(metadata, 0) != SQLITE_NULL {
                    let record = try loadPageInTransaction(pageID: id).record
                    try record.extensions?.validateWritable(); try validateOptionalFields(record.unknownFields)
                }
                try document.document.validateWritablePayloads()
                _ = try sourceLinks(pageID: id)
            }
            try eachIdentity("sources") { _ = try sourceInTransaction(id: $0) }
            try eachIdentity("conflicts") { _ = try conflictInTransaction(id: $0) }
            let extensions = try statement("SELECT extensions FROM vault_state WHERE singleton=1")
            defer { sqlite3_finalize(extensions) }
            guard sqlite3_step(extensions) == SQLITE_ROW else { throw VaultError.invalid("Canonical vault state missing.") }
            try validateOptionalFields(decoder.decode([String: JSONValue].self, from: blob(extensions, 0)))
            if try isSemanticSchema() {
                try Self.validateKnowledgeCapabilities(try db, expected: Self.semanticRequiredCapabilities)
                try Self.validateSemanticRegistry(try db)
                try eachIdentity("knowledge_entities") { _ = try entityInTransaction(id: $0) }
                try eachIdentity("knowledge_relations") { _ = try relationInTransaction(id: $0) }
                try eachIdentity("semantic_objects") { _ = try objectInTransaction(id: $0) }
                for snapshot in try annotationRows() {
                    try validate("blockStore.logicalIntegrity"); try operation?()
                    let annotation = snapshot.annotation
                    let owner = try (annotation.anchorDisposition == .resolved ? annotation.location.pageID : nil).map { try loadDocument(pageID: $0) }
                    try validateAnnotationEvidence(annotation, document: owner?.document, pageRevision: owner?.revision)
                }
            }
            try operation?()
        }
    }

    public func checkpoint() throws {
        try validate("blockStore.checkpoint")
        let statement = try statement("PRAGMA wal_checkpoint(TRUNCATE)"); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else { throw failure() }
        try validate("blockStore.checkpoint")
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

    private func requireKnowledge() throws {
        try validate("knowledge.read")
        guard canonicalVaultID != nil else { throw KnowledgeStoreError.transitionRequired }
        let query = try statement("PRAGMA user_version"); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, [Self.knowledgeSchemaVersion, Self.semanticSchemaVersion].contains(Int(sqlite3_column_int(query, 0))) else { throw KnowledgeStoreError.transitionRequired }
    }
    private func checkedKnowledgeRevision(_ expected: BlockStoreRevision) throws {
        guard try vaultRevision() == expected else { throw KnowledgeStoreError.staleRevision }
    }
    private func entityInTransaction(id: UUID) throws -> KnowledgeEntitySnapshot {
        let query = try statement("SELECT revision,payload,type_key,lifecycle FROM knowledge_entities WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        let step = sqlite3_step(query)
        if step == SQLITE_DONE { throw KnowledgeStoreError.notFound(id) }
        guard step == SQLITE_ROW else { throw failure() }
        var entity = try decoder.decode(KnowledgeEntity.self, from: knowledgeRecordData(blob(query, 1), fields: ["id": id.uuidString, "typeKey": text(query, 2), "lifecycle": text(query, 3)]))
        guard entity.id == id, entity.typeKey == text(query, 2), entity.lifecycle.rawValue == text(query, 3), entity.aliases.isEmpty else { throw VaultError.invalid("Knowledge relational identity/payload mismatch.") }
        try entity.validateWritable()
        let aliases = try statement("SELECT payload,id FROM knowledge_entity_aliases WHERE entity_id=? ORDER BY id", [.text(id.uuidString)])
        defer { sqlite3_finalize(aliases) }
        entity.aliases = []
        while true { let status = sqlite3_step(aliases); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw failure() }; let alias = try decoder.decode(KnowledgeAlias.self, from: blob(aliases, 0)); guard alias.id.uuidString == text(aliases, 1) else { throw VaultError.invalid("Knowledge alias identity mismatch.") }; try alias.validateWritable(); entity.aliases.append(alias) }
        return .init(entity: entity, revision: .init(token: blob(query, 0)))
    }
    private func relationInTransaction(id: UUID) throws -> KnowledgeRelationSnapshot {
        let query = try statement("SELECT revision,payload,predicate,source_id,target_id,lifecycle FROM knowledge_relations WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        let step = sqlite3_step(query)
        if step == SQLITE_DONE { throw KnowledgeStoreError.notFound(id) }
        guard step == SQLITE_ROW else { throw failure() }
        let relation = try decoder.decode(KnowledgeRelation.self, from: knowledgeRecordData(blob(query, 1), fields: ["id": id.uuidString, "predicate": text(query, 2), "sourceID": text(query, 3), "targetID": text(query, 4), "lifecycle": text(query, 5)]))
        guard relation.id == id, relation.predicate == text(query, 2), relation.sourceID.uuidString == text(query, 3), relation.targetID.uuidString == text(query, 4), relation.lifecycle.rawValue == text(query, 5) else { throw VaultError.invalid("Knowledge relational identity/payload mismatch.") }
        try relation.validateWritable()
        return .init(relation: relation, revision: .init(token: blob(query, 0)))
    }
    private func knowledgeRecordPayload<T: Encodable>(_ record: T, omitting keys: Set<String>) throws -> Data {
        var fields = try decoder.decode([String: JSONValue].self, from: encoder.encode(record))
        for key in keys { fields.removeValue(forKey: key) }
        return try encoder.encode(fields)
    }
    private func knowledgeRecordData(_ payload: Data, fields relational: [String: String]) throws -> Data {
        var fields = try decoder.decode([String: JSONValue].self, from: payload)
        for (key, value) in relational {
            guard fields[key] == nil else { throw VaultError.invalid("Knowledge payload duplicates relational identity.") }
            fields[key] = .string(value)
        }
        return try encoder.encode(fields)
    }
    private func persistKnowledgeEntity(_ entity: KnowledgeEntity, inserting: Bool) throws -> KnowledgeEntitySnapshot {
        try entity.validateWritable()
        let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
        var payload = entity; payload.aliases = []
        if inserting {
            let existing = try statement("SELECT 1 FROM knowledge_entities WHERE id=?", [.text(entity.id.uuidString)]); defer { sqlite3_finalize(existing) }
            guard sqlite3_step(existing) == SQLITE_DONE else { throw KnowledgeStoreError.identityConflict(entity.id) }
            try run("INSERT INTO knowledge_entities(id,type_key,revision,lifecycle,payload) VALUES(?,?,?,?,?)", [.text(entity.id.uuidString),.text(entity.typeKey),.blob(revision.token),.text(entity.lifecycle.rawValue),.blob(try knowledgeRecordPayload(payload, omitting: ["id", "typeKey", "lifecycle"]))])
        } else {
            try run("UPDATE knowledge_entities SET revision=?,lifecycle=?,payload=? WHERE id=?", [.blob(revision.token),.text(entity.lifecycle.rawValue),.blob(try knowledgeRecordPayload(payload, omitting: ["id", "typeKey", "lifecycle"])),.text(entity.id.uuidString)])
        }
        return .init(entity: entity, revision: revision)
    }
    private func recordKnowledgeOperation<T: Codable>(_ value: T, revision: BlockStoreRevision, kind: String, operationID: UUID) throws -> BlockStoreRevision {
        let revisionVault = try advanceVaultRevision()
        try run("INSERT INTO knowledge_operations(operation_id,result_kind,result_payload,record_revision,vault_revision) VALUES(?,?,?,?,?)", [.text(operationID.uuidString),.text(kind),.blob(try encoder.encode(value)),.blob(revision.token),.blob(revisionVault.token)])
        return revisionVault
    }
    private func checkKnowledgeOperation(_ operationID: UUID) throws {
        let query = try statement("SELECT 1 FROM knowledge_operations WHERE operation_id=?", [.text(operationID.uuidString)]); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE, try operationInTransaction(id: operationID) == nil else { throw VaultError.conflict("Operation already committed; inspect its outcome.") }
    }
    public func loadEntity(id: UUID) throws -> KnowledgeEntitySnapshot {
        try requireKnowledge(); return try readTransaction { try entityInTransaction(id: id) }
    }
    public func createEntity(_ entity: KnowledgeEntity, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot> {
        try requireKnowledge()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            guard entity.lifecycle == .live else { throw VaultError.invalid("A new entity must be live.") }
            var entity = entity; entity.createdAt = Date(); entity.modifiedAt = entity.createdAt
            let snapshot = try persistKnowledgeEntity(entity, inserting: true)
            for alias in entity.aliases { try run("INSERT INTO knowledge_entity_aliases(id,entity_id,payload) VALUES(?,?,?)", [.text(alias.id.uuidString),.text(entity.id.uuidString),.blob(try encoder.encode(alias))]) }
            let vault = try recordKnowledgeOperation(entity, revision: snapshot.revision, kind: "entity", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }
    public func searchEntities(query: String, limit: Int) throws -> [KnowledgeEntitySnapshot] {
        try requireKnowledge()
        guard limit > 0, limit <= 1000 else { throw VaultError.invalid("Knowledge search limit must be 1...1000.") }
        return try readTransaction {
            let statement = try statement("SELECT id FROM knowledge_entities ORDER BY id"); defer { sqlite3_finalize(statement) }
            var result: [KnowledgeEntitySnapshot] = []
            while result.count < limit {
                let status = sqlite3_step(statement); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)) else { throw failure() }
                let current = try entityInTransaction(id: id)
                if current.entity.label.localizedCaseInsensitiveContains(query) || current.entity.aliases.contains(where: { $0.label.localizedCaseInsensitiveContains(query) }) || query.isEmpty { result.append(current) }
            }
            return result
        }
    }
    private func mutateEntity(id: UUID, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID, permitTombstone: Bool = false, mutation: (inout KnowledgeEntity) throws -> Void) throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot> {
        try requireKnowledge()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let current = try entityInTransaction(id: id)
            var entity = current.entity
            guard current.revision == expected else { throw KnowledgeStoreError.staleRevision }
            guard permitTombstone || current.entity.lifecycle == .live else { throw KnowledgeStoreError.tombstoned(id) }
            try mutation(&entity); entity.modifiedAt = Date()
            let snapshot = try persistKnowledgeEntity(entity, inserting: false)
            let vault = try recordKnowledgeOperation(snapshot.entity, revision: snapshot.revision, kind: "entity", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }
    public func updateEntity(id: UUID, patch: KnowledgeEntityPatch, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot> {
        try mutateEntity(id: id, expected: expected, expectedVaultRevision: expectedVaultRevision, operationID: operationID) { entity in
            entity = try patch.applying(to: entity)
        }
    }
    public func addAlias(entityID: UUID, alias: KnowledgeAlias, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot> {
        try mutateEntity(id: entityID, expected: expected, expectedVaultRevision: expectedVaultRevision, operationID: operationID) { entity in
            try alias.validateWritable()
            try run("INSERT INTO knowledge_entity_aliases(id,entity_id,payload) VALUES(?,?,?)", [.text(alias.id.uuidString),.text(entityID.uuidString),.blob(try encoder.encode(alias))])
            entity.aliases.append(alias); entity.aliases.sort { $0.id.uuidString < $1.id.uuidString }
        }
    }
    public func removeAlias(entityID: UUID, aliasID: UUID, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot> {
        try mutateEntity(id: entityID, expected: expected, expectedVaultRevision: expectedVaultRevision, operationID: operationID) { entity in
            guard entity.aliases.contains(where: { $0.id == aliasID }) else { throw KnowledgeStoreError.notFound(aliasID) }
            try run("DELETE FROM knowledge_entity_aliases WHERE id=? AND entity_id=?", [.text(aliasID.uuidString),.text(entityID.uuidString)])
            entity.aliases.removeAll { $0.id == aliasID }
        }
    }
    public func transitionEntity(id: UUID, to lifecycle: KnowledgeLifecycle, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot> {
        try mutateEntity(id: id, expected: expected, expectedVaultRevision: expectedVaultRevision, operationID: operationID, permitTombstone: true) { $0.lifecycle = lifecycle }
    }
    public func createRelation(_ relation: KnowledgeRelation, expectedSource: BlockStoreRevision, expectedTarget: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<KnowledgeRelationSnapshot> {
        try requireKnowledge()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID); try relation.validateWritable()
            let source = try entityInTransaction(id: relation.sourceID), target = try entityInTransaction(id: relation.targetID)
            guard source.revision == expectedSource, target.revision == expectedTarget else { throw KnowledgeStoreError.staleRevision }
            guard source.entity.lifecycle == .live, target.entity.lifecycle == .live, relation.lifecycle == .live else { throw VaultError.invalid("New relations require live endpoints.") }
            let existing = try statement("SELECT 1 FROM knowledge_relations WHERE id=?", [.text(relation.id.uuidString)]); defer { sqlite3_finalize(existing) }
            guard sqlite3_step(existing) == SQLITE_DONE else { throw KnowledgeStoreError.identityConflict(relation.id) }
            var relation = relation; relation.createdAt = Date(); relation.modifiedAt = relation.createdAt
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            try run("INSERT INTO knowledge_relations(id,predicate,source_id,target_id,revision,lifecycle,payload) VALUES(?,?,?,?,?,?,?)", [.text(relation.id.uuidString),.text(relation.predicate),.text(relation.sourceID.uuidString),.text(relation.targetID.uuidString),.blob(revision.token),.text(relation.lifecycle.rawValue),.blob(try knowledgeRecordPayload(relation, omitting: ["id", "predicate", "sourceID", "targetID", "lifecycle"]))])
            let vault = try recordKnowledgeOperation(relation, revision: revision, kind: "relation", operationID: operationID)
            return .init(value: .init(relation: relation, revision: revision), vaultRevision: vault, operationID: operationID)
        }
    }
    public func queryRelations(entityID: UUID, direction: KnowledgeRelationDirection) throws -> [KnowledgeRelationSnapshot] {
        try requireKnowledge()
        return try readTransaction {
            _ = try entityInTransaction(id: entityID)
            let predicate: String
            switch direction { case .outgoing: predicate = "source_id=?"; case .incoming: predicate = "target_id=?"; case .both: predicate = "source_id=? OR target_id=?" }
            let values: [Value] = direction == .both ? [.text(entityID.uuidString),.text(entityID.uuidString)] : [.text(entityID.uuidString)]
            let query = try statement("SELECT id FROM knowledge_relations WHERE \(predicate) ORDER BY id LIMIT 1000", values); defer { sqlite3_finalize(query) }
            var result: [KnowledgeRelationSnapshot] = []
            while true { let status = sqlite3_step(query); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW, let id = UUID(uuidString: text(query, 0)) else { throw failure() }; result.append(try relationInTransaction(id: id)) }
            return result
        }
    }
    public func transitionRelation(id: UUID, to lifecycle: KnowledgeLifecycle, expected: BlockStoreRevision, expectedSource: BlockStoreRevision, expectedTarget: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<KnowledgeRelationSnapshot> {
        try requireKnowledge()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let current = try relationInTransaction(id: id)
            var relation = current.relation
            guard current.revision == expected, try entityInTransaction(id: current.relation.sourceID).revision == expectedSource, try entityInTransaction(id: current.relation.targetID).revision == expectedTarget else { throw KnowledgeStoreError.staleRevision }
            relation.lifecycle = lifecycle; relation.modifiedAt = Date()
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            try run("UPDATE knowledge_relations SET revision=?,lifecycle=?,payload=? WHERE id=?", [.blob(revision.token),.text(lifecycle.rawValue),.blob(try knowledgeRecordPayload(relation, omitting: ["id", "predicate", "sourceID", "targetID", "lifecycle"])),.text(id.uuidString)])
            let vault = try recordKnowledgeOperation(relation, revision: revision, kind: "relation", operationID: operationID)
            return .init(value: .init(relation: relation, revision: revision), vaultRevision: vault, operationID: operationID)
        }
    }
    public func resolveEntity(id: UUID) throws -> KnowledgeEntityResolution {
        try requireKnowledge()
        return try readTransaction {
            do { let current = try entityInTransaction(id: id); return current.entity.lifecycle == .live ? .live(current) : .tombstoned(current) }
            catch KnowledgeStoreError.notFound { return .unresolved(id) }
        }
    }
    public func committedKnowledgeEntityOperation(id: UUID) throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot>? {
        try requireKnowledge()
        return try readTransaction {
            let query = try statement("SELECT result_payload,record_revision,vault_revision FROM knowledge_operations WHERE operation_id=? AND result_kind='entity'", [.text(id.uuidString)]); defer { sqlite3_finalize(query) }
            let status = sqlite3_step(query); if status == SQLITE_DONE { return nil }; guard status == SQLITE_ROW else { throw failure() }
            return .init(value: .init(entity: try decoder.decode(KnowledgeEntity.self, from: blob(query, 0)), revision: .init(token: blob(query, 1))), vaultRevision: .init(token: blob(query, 2)), operationID: id)
        }
    }
    public func committedKnowledgeRelationOperation(id: UUID) throws -> KnowledgeMutationResult<KnowledgeRelationSnapshot>? {
        try requireKnowledge()
        return try readTransaction {
            let query = try statement("SELECT result_payload,record_revision,vault_revision FROM knowledge_operations WHERE operation_id=? AND result_kind='relation'", [.text(id.uuidString)]); defer { sqlite3_finalize(query) }
            let status = sqlite3_step(query); if status == SQLITE_DONE { return nil }; guard status == SQLITE_ROW else { throw failure() }
            return .init(value: .init(relation: try decoder.decode(KnowledgeRelation.self, from: blob(query, 0)), revision: .init(token: blob(query, 1))), vaultRevision: .init(token: blob(query, 2)), operationID: id)
        }
    }

    /// Resource retirement remains permitted after the session lease is revoked.
    /// SQLite owns journal cleanup; callers must never unlink WAL/SHM themselves.
    public func close() throws {
        guard let pointer = connection.pointer else { return }
        guard sqlite3_close(pointer) == SQLITE_OK else { throw failure() }
        connection.pointer = nil
    }
}

extension SQLiteBlockStore {
    private func isSemanticSchema() throws -> Bool {
        let q = try statement("PRAGMA user_version"); defer { sqlite3_finalize(q) }
        guard sqlite3_step(q) == SQLITE_ROW else { throw failure() }; return sqlite3_column_int(q, 0) == 5
    }
    private func requireSemantic() throws {
        try validate("semantic.access")
        guard try isSemanticSchema() else { throw KnowledgeStoreError.transitionRequired }
        try requireKnowledge()
    }
    private func objectInTransaction(id: UUID) throws -> SemanticObjectSnapshot {
        let q = try statement("SELECT revision,type_key,lifecycle,payload FROM semantic_objects WHERE id=?", [.text(id.uuidString)]); defer { sqlite3_finalize(q) }
        let status = sqlite3_step(q)
        if status == SQLITE_DONE { throw KnowledgeStoreError.notFound(id) }
        guard status == SQLITE_ROW else { throw failure() }
        var object = try decoder.decode(SemanticObject.self, from: knowledgeRecordData(blob(q, 3), fields: ["id":id.uuidString,"typeKey":text(q,1),"lifecycle":text(q,2)]))
        let links = try statement("SELECT entity_id,designation FROM semantic_object_entities WHERE object_id=? ORDER BY entity_id", [.text(id.uuidString)]); defer { sqlite3_finalize(links) }
        guard object.relatedEntityIDs.isEmpty, object.subjectEntityID == nil else { throw VaultError.invalid("Object payload duplicates relational memberships.") }; object.relatedEntityIDs = []; object.subjectEntityID = nil
        while sqlite3_step(links) == SQLITE_ROW { guard let id = UUID(uuidString: text(links,0)) else { throw failure() }; if text(links,1) == "subject" { object.subjectEntityID=id } else { object.relatedEntityIDs.append(id) } }
        try object.validateWritable(); return .init(object: object, revision: .init(token: blob(q,0)))
    }
    private func persistObject(_ object: SemanticObject, expected: BlockStoreRevision?) throws -> SemanticObjectSnapshot {
        try object.validateWritable()
        let current: SemanticObjectSnapshot?
        do { current = try objectInTransaction(id: object.id) }
        catch KnowledgeStoreError.notFound(let missingID) where missingID == object.id { current = nil }
        if let expected { guard current?.revision == expected else { throw KnowledgeStoreError.staleRevision } }
        else { guard current == nil else { throw KnowledgeStoreError.identityConflict(object.id) } }
        if let current { guard current.object.typeKey == object.typeKey else { throw KnowledgeStoreError.identityConflict(object.id) } }
        for id in object.relatedEntityIDs + [object.subjectEntityID].compactMap({ $0 }) { _ = try entityInTransaction(id:id) }
        var stored = object; stored.relatedEntityIDs = []; stored.subjectEntityID = nil
        let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
        let payload = try knowledgeRecordPayload(stored, omitting: ["id", "typeKey", "lifecycle"])
        if current == nil {
            try run("INSERT INTO semantic_objects(id,type_key,revision,lifecycle,payload) VALUES(?,?,?,?,?)", [.text(object.id.uuidString), .text(object.typeKey), .blob(revision.token), .text(object.lifecycle.rawValue), .blob(payload)])
        } else {
            try run("UPDATE semantic_objects SET revision=?,lifecycle=?,payload=? WHERE id=?", [.blob(revision.token), .text(object.lifecycle.rawValue), .blob(payload), .text(object.id.uuidString)])
        }
        try run("DELETE FROM semantic_object_entities WHERE object_id=?", [.text(object.id.uuidString)])
        for id in object.relatedEntityIDs { try run("INSERT INTO semantic_object_entities VALUES(?,?,'relatedTo')", [.text(object.id.uuidString),.text(id.uuidString)]) }
        if let id=object.subjectEntityID { try run("INSERT INTO semantic_object_entities VALUES(?,?,'subject')", [.text(object.id.uuidString),.text(id.uuidString)]) }
        return .init(object:object,revision:revision)
    }
    /// A bounded, coherent catalogue includes independent objects with no occurrences.
    public func knowledgeCatalogue() throws -> KnowledgeCatalogueSnapshot {
        try requireSemantic()
        return try readTransaction {
            let entities = try searchEntities(query: "", limit: 1000)
            let query = try statement("SELECT id FROM semantic_objects ORDER BY id LIMIT 1000", [])
            defer { sqlite3_finalize(query) }
            var objects: [SemanticObjectSnapshot] = []
            while true {
                let step = sqlite3_step(query)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW, let id = UUID(uuidString: text(query, 0)) else { throw failure() }
                objects.append(try objectInTransaction(id: id))
            }
            return .init(entities: entities, objects: objects, annotations: Array(try annotationRows().prefix(1000)), vaultRevision: try vaultRevision())
        }
    }
    public func loadObject(id: UUID) throws -> SemanticObjectSnapshot { try requireSemantic(); return try readTransaction { try objectInTransaction(id:id) } }
    public func createObject(_ object: SemanticObject, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<SemanticObjectSnapshot> {
        try requireSemantic(); return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            guard object.lifecycle == .live else { throw KnowledgeStoreError.tombstoned(object.id) }
            let s=try persistObject(object,expected:nil); let v=try recordKnowledgeOperation(s.object, revision:s.revision,kind:"semanticObject",operationID:operationID)
            return .init(value:s,vaultRevision:v,operationID:operationID)
        }
    }
    public func updateObject(id: UUID, patch: SemanticObjectPatch, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<SemanticObjectSnapshot> {
        try requireSemantic(); return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let old=try objectInTransaction(id:id); guard old.object.lifecycle == .live else { throw KnowledgeStoreError.tombstoned(id) }
            var value=try patch.applying(to:old.object); value.modifiedAt=Date()
            let s=try persistObject(value,expected:expected); let v=try recordKnowledgeOperation(s.object,revision:s.revision,kind:"semanticObject",operationID:operationID)
            return .init(value:s,vaultRevision:v,operationID:operationID)
        }
    }
    public func transitionObject(id: UUID, to lifecycle: KnowledgeLifecycle, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<SemanticObjectSnapshot> {
        try requireSemantic(); return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            var value=try objectInTransaction(id:id).object; value.lifecycle=lifecycle; value.modifiedAt=Date()
            let s=try persistObject(value,expected:expected); let v=try recordKnowledgeOperation(s.object,revision:s.revision,kind:"semanticObject",operationID:operationID)
            return .init(value:s,vaultRevision:v,operationID:operationID)
        }
    }
    private func annotationRows(pageID: UUID? = nil) throws -> [SemanticAnnotationSnapshot] {
        let q = try statement("SELECT id,revision,location_kind,captured_page,captured_block,live_page,live_block,owner_entity,owner_object,referent_entity,referent_object,payload FROM semantic_annotations" + (pageID == nil ? "" : " WHERE captured_page=?") + " ORDER BY id", pageID.map { [.text($0.uuidString)] } ?? [])
        defer { sqlite3_finalize(q) }
        var result: [SemanticAnnotationSnapshot] = []
        while true {
            let step = sqlite3_step(q); if step == SQLITE_DONE { break }; guard step == SQLITE_ROW else { throw failure() }
            var value = try decoder.decode(SemanticAnnotation.self, from: blob(q,11))
            let kind: String; switch value.location { case .wholeBlock: kind="wholeBlock"; case .inline: kind="inline"; case .entity: kind="entity"; case .object: kind="object" }
            guard value.id.uuidString == text(q,0), kind == text(q,2), (value.location.pageID?.uuidString ?? "") == text(q,3), (value.location.blockID?.uuidString ?? "") == text(q,4) else { throw VaultError.invalid("Semantic relational identity mismatch.") }
            switch value.location {
            case .entity(let id): guard text(q,7) == id.uuidString, text(q,8).isEmpty else { throw PersistencePayloadError.invalidAnnotation }
            case .object(let id): guard text(q,8) == id.uuidString, text(q,7).isEmpty else { throw PersistencePayloadError.invalidAnnotation }
            default:
                if value.anchorDisposition == .resolved { guard text(q,5) == text(q,3), text(q,6) == text(q,4) else { throw PersistencePayloadError.invalidAnnotation } }
                else { guard text(q,5).isEmpty, text(q,6).isEmpty else { throw PersistencePayloadError.invalidAnnotation } }
            }
            if value.referent.disposition == .unresolved { guard text(q,9).isEmpty, text(q,10).isEmpty else { throw PersistencePayloadError.invalidAnnotation } }
            else if ["question","definition"].contains(value.referent.identity.kind) {
                guard text(q,10) == value.referent.identity.id.uuidString, text(q,9).isEmpty else { throw PersistencePayloadError.invalidAnnotation }
                let object = try objectInTransaction(id:value.referent.identity.id).object
                guard object.typeKey == value.referent.identity.kind else { throw PersistencePayloadError.invalidAnnotation }
                value.referent.disposition = object.lifecycle == .live ? .live : .tombstoned
            } else {
                guard text(q,9) == value.referent.identity.id.uuidString, text(q,10).isEmpty else { throw PersistencePayloadError.invalidAnnotation }
                let entity = try entityInTransaction(id:value.referent.identity.id).entity
                guard entity.typeKey == value.referent.identity.kind else { throw PersistencePayloadError.invalidAnnotation }
                value.referent.disposition = entity.lifecycle == .live ? .live : .tombstoned
            }
            result.append(.init(annotation:value, revision:.init(token:blob(q,1))))
        }
        return result
    }
    private func annotationInTransaction(id: UUID) throws -> SemanticAnnotationSnapshot? {
        try annotationRows().first { $0.annotation.id == id }
    }
    private func validateAnnotationEvidence(_ a: SemanticAnnotation, document: BlockDocument?, pageRevision: BlockStoreRevision? = nil) throws {
        try a.payload?.validateWritable(); try a.referent.payload?.validateWritable(); try validateOptionalFields(a.unknownFields)
        guard !a.designation.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw PersistencePayloadError.invalidAnnotation }
        if case .inline(_, _, let target) = a.location {
            guard target.version == 1, target.start >= 0, target.end >= target.start, target.prefix.count <= 64, target.suffix.count <= 64 else { throw PersistencePayloadError.invalidAnnotation }
            try validateOptionalFields(target.unknownFields)
        }
        if a.anchorDisposition == .resolved, a.location.pageID != nil {
            guard let document, let id=a.location.blockID, let block=document.block(id) else { throw PersistencePayloadError.invalidAnnotation }
            if let pageRevision { guard a.expectedRevision == pageRevision.token else { throw KnowledgeStoreError.staleRevision } }
            if case .inline(_,_,let target)=a.location {
                guard target.version == 1, target.end >= target.start, target.prefix.count <= 64, target.suffix.count <= 64, InlineAnnotationTarget.validRange(NSRange(location:target.start,length:target.end-target.start),in:block.text), (block.text as NSString).substring(with:NSRange(location:target.start,length:target.end-target.start)) == target.quote, target.digest == InlineAnnotationTarget.evidence(quote:target.quote,revision:a.expectedRevision) else { throw PersistencePayloadError.invalidAnnotation }
            }
        }
    }
    @discardableResult private func persistAnnotation(_ annotation: SemanticAnnotation, document: BlockDocument? = nil, expected: BlockStoreRevision? = nil, allowExisting: Bool = false) throws -> SemanticAnnotationSnapshot {
        var a=annotation; try validateAnnotationEvidence(a, document:document)
        let old=try annotationInTransaction(id:a.id)
        if let old {
            guard allowExisting || expected == old.revision else { throw KnowledgeStoreError.identityConflict(a.id) }
            guard old.annotation.location.pageID == a.location.pageID else { throw KnowledgeStoreError.identityConflict(a.id) }
            if old.annotation.location.pageID == nil { guard old.annotation.location == a.location else { throw KnowledgeStoreError.identityConflict(a.id) } }
        } else if expected != nil { throw KnowledgeStoreError.staleRevision }
        var ownerEntity:Value = .null, ownerObject:Value = .null, referentEntity:Value = .null, referentObject:Value = .null
        switch a.location {
        case .entity(let id): _ = try entityInTransaction(id:id); ownerEntity = .text(id.uuidString)
        case .object(let id): _ = try objectInTransaction(id:id); ownerObject = .text(id.uuidString)
        default: break
        }
        if a.referent.disposition != .unresolved {
            if ["question","definition"].contains(a.referent.identity.kind) { let o=try objectInTransaction(id:a.referent.identity.id).object; guard o.typeKey == a.referent.identity.kind else { throw KnowledgeStoreError.missingReference(o.id) }; referentObject = .text(o.id.uuidString); a.referent.disposition = o.lifecycle == .live ? .live : .tombstoned }
            else { let e=try entityInTransaction(id:a.referent.identity.id).entity; guard e.typeKey == a.referent.identity.kind else { throw KnowledgeStoreError.missingReference(e.id) }; referentEntity = .text(e.id.uuidString); a.referent.disposition = e.lifecycle == .live ? .live : .tombstoned }
        }
        let kind:String; switch a.location { case .wholeBlock:kind="wholeBlock";case .inline:kind="inline";case .entity:kind="entity";case .object:kind="object" }
        let live=a.anchorDisposition == .resolved, revision=BlockStoreRevision(token:Data(UUID().uuidString.utf8))
        let values:[Value]=[.blob(revision.token),.text(kind),a.location.pageID.map{.text($0.uuidString)} ?? .null,a.location.blockID.map{.text($0.uuidString)} ?? .null,live ? (a.location.pageID.map{.text($0.uuidString)} ?? .null) : .null,live ? (a.location.blockID.map{.text($0.uuidString)} ?? .null) : .null,ownerEntity,ownerObject,referentEntity,referentObject,.blob(try encoder.encode(a)),.text(a.id.uuidString)]
        if old == nil { try run("INSERT INTO semantic_annotations(revision,location_kind,captured_page,captured_block,live_page,live_block,owner_entity,owner_object,referent_entity,referent_object,payload,id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",values) }
        else { try run("UPDATE semantic_annotations SET revision=?,location_kind=?,captured_page=?,captured_block=?,live_page=?,live_block=?,owner_entity=?,owner_object=?,referent_entity=?,referent_object=?,payload=? WHERE id=?",values) }
        return .init(annotation:a, revision:revision)
    }
    private func projectingSemanticAnnotations(_ document: BlockDocument, pageID: UUID) throws -> BlockDocument {
        var d=document; var values:[JSONValue]=[]
        for s in try annotationRows(pageID:pageID) { let a=s.annotation; guard case .inline(let p,let b,let target)=a.location else { continue }; var inline=InlineAnnotation(id:a.id,pageID:p,blockID:b,designation:a.designation,expectedRevision:a.expectedRevision,target:target,disposition:a.anchorDisposition); inline.targetEntity=a.referent.identity; inline.payload=a.payload; inline.createdAt=a.createdAt; inline.modifiedAt=a.modifiedAt; var raw=try decoder.decode(JSONValue.self,from:encoder.encode(inline)); if case .object(var fields)=raw { fields.merge(a.unknownFields){old,_ in old}; raw = .object(fields) }; values.append(raw) }
        if !values.isEmpty { if d.extensions == nil { d.extensions = .init() }; d.extensions?.properties["annotations"] = .array(values) }
        return d
    }
    private func persistSemanticProjection(_ document: BlockDocument, pageID: UUID, pageRevision: BlockStoreRevision, previousRevision: BlockStoreRevision?) throws {
        var incoming:Set<UUID>=[]
        if case .array(let values)=document.extensions?.properties["annotations"] { for raw in values { let i=try decoder.decode(InlineAnnotation.self,from:encoder.encode(raw)); incoming.insert(i.id); let ref=SemanticReferent(identity:i.targetEntity ?? .init(kind:"legacy",id:i.id),disposition: i.targetEntity.map { ["person","place","concept","question","definition"].contains($0.kind) ? .live : .unresolved } ?? .unresolved); var a=SemanticAnnotation(id:i.id,location:.inline(pageID:pageID,blockID:i.blockID,target:i.target),referent:ref,designation:i.designation,anchorDisposition:i.disposition,expectedRevision:i.expectedRevision,payload:i.payload,createdAt:i.createdAt,modifiedAt:i.modifiedAt); if case .object(let fields)=raw { a.unknownFields=fields.filter{ !["id","pageID","blockID","designation","targetEntity","payload","createdAt","modifiedAt","expectedRevision","target","disposition"].contains($0.key) } }; if let old = try annotationInTransaction(id:a.id) { guard old.annotation.location.pageID == pageID else { throw KnowledgeStoreError.identityConflict(a.id) }; if old.annotation.referent.identity == a.referent.identity { a.referent = old.annotation.referent }; a.locationUnknownFields = old.annotation.locationUnknownFields }; try persistAnnotation(a,document:document,allowExisting:true) } }
        for old in try annotationRows(pageID:pageID) where !incoming.contains(old.annotation.id) { var a=old.annotation; if case .wholeBlock = a.location, a.anchorDisposition == .resolved, let blockID=a.location.blockID, document.block(blockID) != nil { guard a.expectedRevision == (previousRevision?.token ?? Data()) else { throw KnowledgeStoreError.staleRevision }; a.expectedRevision=pageRevision.token }; if case .inline=a.location { a.anchorDisposition = .deleted }; if let b=a.location.blockID, document.block(b) == nil { a.anchorDisposition = .deleted }; try persistAnnotation(a,document:document,allowExisting:true) }
    }
    private func semanticPageObjects(_ pageID: UUID) throws -> [SemanticObjectSnapshot] {
        let ids = Set(try annotationRows(pageID: pageID).filter {
            $0.annotation.referent.disposition != .unresolved && ["question", "definition"].contains($0.annotation.referent.identity.kind)
        }.map { $0.annotation.referent.identity.id })
        return try ids.sorted { $0.uuidString < $1.uuidString }.map { try objectInTransaction(id: $0) }
    }
    public func loadSemanticPage(pageID: UUID) throws -> SemanticPageSnapshot { try requireSemantic(); return try readTransaction { .init(snapshot:try load(pageID:pageID),annotations:try annotationRows(pageID:pageID),objects:try semanticPageObjects(pageID)) } }
    public func saveSemanticPage(_ incoming: SemanticPageEdit, condition: BlockStoreWriteCondition, expectedObjectRevisions: [UUID:BlockStoreRevision], expectedEntityRevisions: [UUID:BlockStoreRevision], expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<SemanticPageSnapshot> {
        try requireSemantic(); return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let existing=try annotationRows(pageID:incoming.pageID)
            let old: BlockStoreSnapshot?
            switch condition { case .createOnly: old=nil; case .replace(let expected): let value=try loadDocument(pageID:incoming.pageID); guard value.revision == expected else { throw KnowledgeStoreError.staleRevision }; old=value }
            let edit: SemanticPageEdit
            if let old { edit=incoming.preparingAnnotationsForPersistence(comparedTo:.init(snapshot:old,annotations:existing)) } else { edit=incoming }
            for (id,rev) in expectedEntityRevisions { guard try entityInTransaction(id:id).revision == rev else { throw KnowledgeStoreError.staleRevision } }
            for (id,rev) in expectedObjectRevisions { guard try objectInTransaction(id:id).revision == rev else { throw KnowledgeStoreError.staleRevision } }
            for item in existing { guard edit.expectedAnnotationRevisions[item.annotation.id] == item.revision else { throw KnowledgeStoreError.staleRevision } }
            guard Set(edit.annotations.map(\.id)).count == edit.annotations.count, Set(edit.objects.map(\.id)).count == edit.objects.count else { throw PersistencePayloadError.invalidAnnotation }
            for object in edit.objects {
                for id in object.relatedEntityIDs + [object.subjectEntityID].compactMap({$0}) { guard expectedEntityRevisions[id] != nil else { throw KnowledgeStoreError.staleRevision } }
                if let prior = try? objectInTransaction(id:object.id), prior.object.lifecycle != .live { throw KnowledgeStoreError.tombstoned(object.id) }
                _ = try persistObject(object,expected:expectedObjectRevisions[object.id])
            }
            for annotation in edit.annotations {
                guard annotation.location.pageID == edit.pageID else { throw PersistencePayloadError.invalidAnnotation }
                try validateAnnotationEvidence(annotation,document:edit.document,pageRevision:old?.revision)
                if annotation.referent.disposition != .unresolved { let id=annotation.referent.identity.id
                    if ["question","definition"].contains(annotation.referent.identity.kind) { guard expectedObjectRevisions[id] != nil || edit.objects.contains(where:{$0.id == id}) else { throw KnowledgeStoreError.staleRevision } }
                    else { guard expectedEntityRevisions[id] != nil else { throw KnowledgeStoreError.staleRevision } }
                }
            }
            var content=edit.document; content.extensions?.properties.removeValue(forKey:"annotations")
            var metadata = edit.metadata
            guard metadata == nil || metadata?.id == edit.pageID else { throw PersistencePayloadError.invalidAnnotation }
            try metadata?.extensions?.validateWritable()
            if let metadata { try validateOptionalFields(metadata.unknownFields) }
            metadata?.body = ""; metadata?.contentHash = ""
            if canonicalVaultID != nil { metadata?.sourceIDs = nil }
            let metadataBytes = try metadata.map { try encoder.encode($0) }
            let snapshot=try persist(content,pageID:edit.pageID,condition:condition,metadata:metadataBytes,semanticProjection:false)
            if canonicalVaultID != nil, let record = edit.metadata { try replaceSourceLinks(pageID: edit.pageID, sourceIDs: record.linkedSourceIDs) }
            for var annotation in edit.annotations {
                if annotation.anchorDisposition == .resolved { annotation.expectedRevision=snapshot.revision.token; if case .inline(let page,let block,var target)=annotation.location { target.digest=InlineAnnotationTarget.evidence(quote:target.quote,revision:annotation.expectedRevision); annotation.location = .inline(pageID:page,blockID:block,target:target) } }
                _ = try persistAnnotation(annotation,document:snapshot.document,expected:edit.expectedAnnotationRevisions[annotation.id])
            }
            for prior in existing where !edit.annotations.contains(where:{$0.id == prior.annotation.id}) { var annotation=prior.annotation; annotation.anchorDisposition = .deleted; _ = try persistAnnotation(annotation,document:snapshot.document,expected:prior.revision) }
            let result=SemanticPageSnapshot(snapshot:try loadDocument(pageID:edit.pageID),annotations:try annotationRows(pageID:edit.pageID),objects:try semanticPageObjects(edit.pageID))
            let vault=try recordKnowledgeOperation(edit.pageID,revision:result.snapshot.revision,kind:"semanticPage",operationID:operationID)
            return .init(value:result,vaultRevision:vault,operationID:operationID)
        }
    }
    private func checkAnnotationOwner(_ location: SemanticLocation, expected: BlockStoreRevision) throws {
        switch location {
        case .entity(let id): let owner=try entityInTransaction(id:id); guard owner.revision == expected else { throw KnowledgeStoreError.staleRevision }; guard owner.entity.lifecycle == .live else { throw KnowledgeStoreError.tombstoned(id) }
        case .object(let id): let owner=try objectInTransaction(id:id); guard owner.revision == expected else { throw KnowledgeStoreError.staleRevision }; guard owner.object.lifecycle == .live else { throw KnowledgeStoreError.tombstoned(id) }
        default: throw VaultError.invalid("Content annotations require compound page save.")
        }
    }
    public func saveAnnotation(_ annotation: SemanticAnnotation, condition: BlockStoreWriteCondition, expectedOwnerRevision: BlockStoreRevision, expectedReferentRevision: BlockStoreRevision?, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<SemanticAnnotationSnapshot> {
        try requireSemantic(); return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID); try checkAnnotationOwner(annotation.location,expected:expectedOwnerRevision)
            if annotation.referent.disposition != .unresolved {
                let id=annotation.referent.identity.id
                let revision = try ["question","definition"].contains(annotation.referent.identity.kind) ? objectInTransaction(id:id).revision : entityInTransaction(id:id).revision
                guard revision == expectedReferentRevision else { throw KnowledgeStoreError.staleRevision }
            }
            let expected: BlockStoreRevision?; switch condition { case .createOnly: expected=nil; case .replace(let revision): expected=revision }
            let result=try persistAnnotation(annotation,expected:expected)
            let vault=try recordKnowledgeOperation(result.annotation,revision:result.revision,kind:"semanticAnnotation",operationID:operationID)
            return .init(value:result,vaultRevision:vault,operationID:operationID)
        }
    }
    public func transitionAnnotation(id: UUID, to disposition: AnnotationDisposition, expected: BlockStoreRevision, expectedOwnerRevision: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<SemanticAnnotationSnapshot> {
        try requireSemantic(); return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            guard let old=try annotationInTransaction(id:id) else { throw KnowledgeStoreError.notFound(id) }
            try checkAnnotationOwner(old.annotation.location,expected:expectedOwnerRevision)
            var annotation=old.annotation; annotation.anchorDisposition=disposition; annotation.modifiedAt=Date()
            let result=try persistAnnotation(annotation,expected:expected)
            let vault=try recordKnowledgeOperation(result.annotation,revision:result.revision,kind:"semanticAnnotation",operationID:operationID)
            return .init(value:result,vaultRevision:vault,operationID:operationID)
        }
    }
    public func occurrences(entityID: UUID) throws -> [SemanticAnnotationSnapshot] {
        try requireSemantic(); return try readTransaction { _ = try entityInTransaction(id:entityID); return Array(try annotationRows().filter { $0.annotation.referent.identity.id == entityID && ["person","place","concept"].contains($0.annotation.referent.identity.kind) }.prefix(1000)) }
    }
    public func annotations(pageID: UUID, blockID: UUID? = nil) throws -> [SemanticAnnotationSnapshot] {
        try requireSemantic(); return try readTransaction { Array(try annotationRows(pageID:pageID).filter { blockID == nil || $0.annotation.location.blockID == blockID }.prefix(1000)) }
    }
    public func objects(pageID: UUID) throws -> [SemanticObjectSnapshot] {
        try requireSemantic(); return try readTransaction {
            let ids=Set(try annotationRows(pageID:pageID).filter { $0.annotation.referent.disposition != .unresolved && ["question","definition"].contains($0.annotation.referent.identity.kind) }.map { $0.annotation.referent.identity.id })
            return try ids.sorted { $0.uuidString < $1.uuidString }.prefix(1000).map { try objectInTransaction(id:$0) }
        }
    }
    public func questions(entityID: UUID, association: SemanticQuestionAssociation) throws -> [SemanticObjectSnapshot] {
        try requireSemantic(); return try readTransaction {
            _ = try entityInTransaction(id:entityID)
            var ids=Set<UUID>()
            switch association {
            case .explicit:
                let query=try statement("SELECT DISTINCT object_id FROM semantic_object_entities WHERE entity_id=? ORDER BY object_id LIMIT 10000",[.text(entityID.uuidString)]); defer { sqlite3_finalize(query) }
                while true { let step=sqlite3_step(query); if step == SQLITE_DONE { break }; guard step == SQLITE_ROW, let id=UUID(uuidString:text(query,0)) else { throw failure() }; ids.insert(id) }
            case .derivedOccurrences:
                let annotations=try annotationRows(); let blocks=Set(annotations.filter { $0.annotation.referent.identity.id == entityID && $0.annotation.anchorDisposition == .resolved }.compactMap { a -> String? in guard let page=a.annotation.location.pageID,let block=a.annotation.location.blockID else { return nil }; return page.uuidString+block.uuidString })
                for value in annotations where value.annotation.referent.identity.kind == "question" && value.annotation.referent.disposition != .unresolved && value.annotation.anchorDisposition == .resolved { if let page=value.annotation.location.pageID,let block=value.annotation.location.blockID,blocks.contains(page.uuidString+block.uuidString) { ids.insert(value.annotation.referent.identity.id) } }
            }
            return Array(try ids.sorted { $0.uuidString < $1.uuidString }.map { try objectInTransaction(id:$0) }.filter { $0.object.typeKey == "question" }.prefix(1000))
        }
    }
    public func annotationsNeedingReview() throws -> [SemanticAnnotationSnapshot] {
        try requireSemantic(); return try readTransaction { Array(try annotationRows().filter { $0.annotation.anchorDisposition != .resolved || $0.annotation.referent.disposition != .live }.prefix(1000)) }
    }
    public func committedSemanticAnnotationOperation(id: UUID) throws -> KnowledgeMutationResult<SemanticAnnotationSnapshot>? {
        try requireSemantic(); return try readTransaction {
            let q=try statement("SELECT result_payload,record_revision,vault_revision FROM knowledge_operations WHERE operation_id=? AND result_kind='semanticAnnotation'",[.text(id.uuidString)]); defer { sqlite3_finalize(q) }
            let step=sqlite3_step(q); if step == SQLITE_DONE { return nil }; guard step == SQLITE_ROW else { throw failure() }
            return .init(value:.init(annotation:try decoder.decode(SemanticAnnotation.self,from:blob(q,0)),revision:.init(token:blob(q,1))),vaultRevision:.init(token:blob(q,2)),operationID:id)
        }
    }
}
