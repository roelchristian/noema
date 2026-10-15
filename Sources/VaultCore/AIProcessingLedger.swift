import Foundation
import SQLite3

public enum AIWorkLedgerError: Error, Sendable {
    case unavailable, unsupportedSchema, invalidMetadata
}

// The actor exclusively owns this connection after initialization; SQLite owns WAL/SHM.
private final class AIWorkLedgerConnection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw AIWorkLedgerError.unavailable
        }
        self.pointer = pointer
    }
    deinit { sqlite3_close(pointer) }
}

/// Rebuildable technical metadata, never canonical content or execution authority.
/// Production owns one store per application; injected URLs are for isolated tests.
public actor SQLiteAIWorkLedger: AIWorkLedger {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noema/Processing/work.sqlite")
    }
    private let connection: AIWorkLedgerConnection
    private var db: OpaquePointer { connection.pointer }

    public init(url: URL = SQLiteAIWorkLedger.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try AIWorkLedgerConnection(url: url)
        let db = connection.pointer
        sqlite3_busy_timeout(db, 2_000)
        let version = try Self.query(db, "PRAGMA user_version").first.flatMap(Int.init) ?? -1
        guard version == 0 || version == 1 else { throw AIWorkLedgerError.unsupportedSchema }
        if version == 0 {
            // Never reinterpret an unrelated, unversioned database as a work ledger.
            let tables = try Self.query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            guard tables.isEmpty else { throw AIWorkLedgerError.unsupportedSchema }
        }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA temp_store=MEMORY;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS ai_work (
          vault_id TEXT NOT NULL, entity_kind TEXT NOT NULL CHECK(entity_kind IN ('page','source')),
          entity_id TEXT NOT NULL, processor_id TEXT NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY(vault_id,entity_kind,entity_id,processor_id)
        );
        CREATE TABLE IF NOT EXISTS ai_checkpoint_heads (vault_id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS ai_checkpoints (
          vault_id TEXT NOT NULL, entity_kind TEXT NOT NULL CHECK(entity_kind IN ('page','source')),
          entity_id TEXT NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY(vault_id,entity_kind,entity_id)
        );
        PRAGMA user_version=1;
        COMMIT;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw AIWorkLedgerError.unavailable
        }
    }

    public func load(vaultID: UUID) throws -> [AIWorkItem] {
        let records = try Self.query(db, "SELECT payload FROM ai_work WHERE vault_id=?", [vaultID.uuidString])
        var items = try records.map { try decode(AIWorkItem.self, $0) }
        guard items.allSatisfy({ $0.key.vaultID == vaultID }) else { throw AIWorkLedgerError.invalidMetadata }
        // A row is not a lease or consent receipt. Interrupted dispatch must obtain
        // a fresh snapshot and authority before replay; attempt counts are retained.
        try transaction {
            for index in items.indices where items[index].state == .running || items[index].state == .scheduled {
                // Running fingerprints describe an attempted input, not proof of publication.
                if items[index].state == .running { items[index].inputFingerprint = nil }
                items[index].state = .pending
                try save(items[index])
            }
        }
        return items
    }

    public func save(_ item: AIWorkItem) throws {
        guard item.attemptCount >= 0, item.eligibleAt.timeIntervalSince1970.isFinite,
              item.updatedAt.timeIntervalSince1970.isFinite,
              !item.key.processorID.isEmpty, item.key.processorID.utf8.count <= 256,
              item.processorVersion.utf8.count <= 128, item.revision.utf8.count <= 1024,
              (item.inputFingerprint?.utf8.count ?? 0) <= 256 else { throw AIWorkLedgerError.invalidMetadata }
        try Self.execute(db, "INSERT INTO ai_work(vault_id,entity_kind,entity_id,processor_id,payload) VALUES(?,?,?,?,?) ON CONFLICT(vault_id,entity_kind,entity_id,processor_id) DO UPDATE SET payload=excluded.payload", [
            item.key.vaultID.uuidString, item.key.entityKind.rawValue,
            item.key.entityID.uuidString, item.key.processorID, try encode(item)
        ])
    }

    public func checkpoint(vaultID: UUID) throws -> [AIContentChange]? {
        guard !(try Self.query(db, "SELECT vault_id FROM ai_checkpoint_heads WHERE vault_id=?", [vaultID.uuidString])).isEmpty else { return nil }
        let records = try Self.query(db, "SELECT payload FROM ai_checkpoints WHERE vault_id=?", [vaultID.uuidString])
        let changes = try records.map { try decode(AIContentChange.self, $0) }
        guard changes.allSatisfy({ $0.vaultID == vaultID }) else { throw AIWorkLedgerError.invalidMetadata }
        return changes
    }

    public func saveCheckpoint(vaultID: UUID, changes: [AIContentChange]) throws {
        guard changes.allSatisfy({ $0.vaultID == vaultID && $0.revision.utf8.count <= 1024 }) else { throw AIWorkLedgerError.invalidMetadata }
        // Preserve an explicit empty baseline and replace the complete metadata view
        // atomically. The coordinator writes jobs before advancing this checkpoint.
        let payloads = try changes.map { try encode($0) }
        try transaction {
            try Self.execute(db, "DELETE FROM ai_checkpoints WHERE vault_id=?", [vaultID.uuidString])
            for (change, payload) in zip(changes, payloads) {
                try Self.execute(db, "INSERT INTO ai_checkpoints(vault_id,entity_kind,entity_id,payload) VALUES(?,?,?,?) ON CONFLICT(vault_id,entity_kind,entity_id) DO UPDATE SET payload=excluded.payload", [vaultID.uuidString, change.entityKind.rawValue, change.entityID.uuidString, payload])
            }
            try Self.execute(db, "INSERT OR IGNORE INTO ai_checkpoint_heads(vault_id) VALUES(?)", [vaultID.uuidString])
        }
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try Self.execute(db, "BEGIN IMMEDIATE")
        do { try operation(); try Self.execute(db, "COMMIT") }
        catch { try? Self.execute(db, "ROLLBACK"); throw error }
    }
    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8) else { throw AIWorkLedgerError.invalidMetadata }
        return text
    }
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        guard text.utf8.count <= 16_384 else { throw AIWorkLedgerError.invalidMetadata }
        do { return try JSONDecoder().decode(type, from: Data(text.utf8)) }
        catch { throw AIWorkLedgerError.invalidMetadata }
    }
    private static func statement(_ db: OpaquePointer, _ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AIWorkLedgerError.unavailable }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(statement); throw AIWorkLedgerError.unavailable
            }
        }
        return statement
    }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ values: [String] = []) throws {
        let statement = try statement(db, sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AIWorkLedgerError.unavailable }
    }
    private static func query(_ db: OpaquePointer, _ sql: String, _ values: [String] = []) throws -> [String] {
        let statement = try statement(db, sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { throw AIWorkLedgerError.invalidMetadata }
            result.append(String(cString: value)); code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw AIWorkLedgerError.unavailable }
        return result
    }
}
