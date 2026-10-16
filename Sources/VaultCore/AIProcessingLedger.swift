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
        guard version == 0 || version == 1 || version == 2 || version == 3 else { throw AIWorkLedgerError.unsupportedSchema }
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
        CREATE TABLE IF NOT EXISTS ai_processor_controls (
          vault_id TEXT NOT NULL, processor_id TEXT NOT NULL, PRIMARY KEY(vault_id,processor_id)
        );
        CREATE TABLE IF NOT EXISTS embedding_batches (
          batch_id TEXT PRIMARY KEY, vault_id TEXT NOT NULL, payload TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS embedding_batch_members (
          batch_id TEXT NOT NULL, entity_kind TEXT NOT NULL CHECK(entity_kind IN ('page','source')),
          entity_id TEXT NOT NULL, work_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY(batch_id,entity_kind,entity_id)
        );
        CREATE INDEX IF NOT EXISTS embedding_batch_admission ON embedding_batch_members(batch_id,state,entity_kind,entity_id);
        PRAGMA user_version=3;
        COMMIT;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw AIWorkLedgerError.unavailable
        }
    }

    public func pausedProcessors(vaultID: UUID) async throws -> Set<String> {
        Set(try Self.query(db, "SELECT processor_id FROM ai_processor_controls WHERE vault_id=?", [vaultID.uuidString]))
    }
    public func setProcessorPaused(vaultID: UUID, processorID: String, paused: Bool) async throws {
        guard !processorID.isEmpty, processorID.utf8.count <= 256 else { throw AIWorkLedgerError.invalidMetadata }
        if paused {
            try Self.execute(db, "INSERT OR IGNORE INTO ai_processor_controls(vault_id,processor_id) VALUES(?,?)", [vaultID.uuidString, processorID])
        } else {
            try Self.execute(db, "DELETE FROM ai_processor_controls WHERE vault_id=? AND processor_id=?", [vaultID.uuidString, processorID])
        }
    }

    public func load(vaultID: UUID) throws -> [AIWorkItem] {
        let records = try Self.query(db, "SELECT payload FROM ai_work WHERE vault_id=?", [vaultID.uuidString])
        var items = try records.map { try decode(AIWorkItem.self, $0) }
        guard items.allSatisfy({ $0.key.vaultID == vaultID }) else { throw AIWorkLedgerError.invalidMetadata }
        // A row is not a lease or consent receipt. Interrupted dispatch must obtain
        // a fresh snapshot and authority before replay; attempt counts are retained.
        try transaction {
            for index in items.indices where items[index].state == .running || items[index].state == .scheduled || items[index].state == .cancellationRequested {
                // Running fingerprints describe an attempted input, not proof of publication.
                if items[index].state == .running { items[index].inputFingerprint = nil }
                items[index].state = items[index].state == .cancellationRequested ? .cancelled
                    : (items[index].batchID == nil ? .pending : .suspended)
                try save(items[index])
            }
        }
        return items
    }

    /// Read-only observation must never turn a live running/scheduled job into pending.
    public func snapshotWorkItems(vaultID: UUID) throws -> [AIWorkItem] {
        let rows = try Self.queryRows(db, "SELECT vault_id,entity_kind,entity_id,processor_id,payload FROM ai_work WHERE vault_id=?", [vaultID.uuidString], columns: 5)
        return try rows.map { row in
            let item = try decode(AIWorkItem.self, row[4])
            guard row[0] == item.key.vaultID.uuidString, row[1] == item.key.entityKind.rawValue,
                  row[2] == item.key.entityID.uuidString, row[3] == item.key.processorID,
                  item.key.vaultID == vaultID else { throw AIWorkLedgerError.invalidMetadata }
            return item
        }
    }

    public func existingWorkItem(key: AIWorkKey) async throws -> AIWorkItem? {
        let rows = try Self.queryRows(db, "SELECT vault_id,entity_kind,entity_id,processor_id,payload FROM ai_work WHERE vault_id=? AND entity_kind=? AND entity_id=? AND processor_id=?",
            [key.vaultID.uuidString, key.entityKind.rawValue, key.entityID.uuidString, key.processorID], columns: 5)
        guard let row = rows.first else { return nil }
        let item = try decode(AIWorkItem.self, row[4])
        guard item.key == key, row[0] == key.vaultID.uuidString, row[1] == key.entityKind.rawValue,
              row[2] == key.entityID.uuidString, row[3] == key.processorID else { throw AIWorkLedgerError.invalidMetadata }
        return item
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

    /// Atomically captures selected metadata-only inventory and durable admission intent.
    /// The existing coordinator is the only consumer allowed to schedule these members.
    @discardableResult
    public func createEmbeddingBatch(_ batch: EmbeddingBackfillBatch,
                                     inventory: [AIContentChange]) throws -> EmbeddingBackfillBatch {
        guard inventory.allSatisfy({ $0.vaultID == batch.vaultID && !$0.revision.isEmpty && $0.revision.utf8.count <= 1024 }) else {
            throw AIWorkLedgerError.invalidMetadata
        }
        let selected = inventory.filter { batch.scopes.contains($0.entityKind) && $0.kind != .removed }
        let identities = selected.map { $0.entityKind.rawValue + ":" + $0.entityID.uuidString }
        guard Set(identities).count == selected.count else { throw AIWorkLedgerError.invalidMetadata }
        if let existing = try embeddingBatch(id: batch.id) {
            guard existing.vaultID == batch.vaultID, existing.generation == batch.generation,
                  existing.scopes == batch.scopes, existing.mode == batch.mode, existing.createdAt == batch.createdAt else {
                throw AIWorkLedgerError.invalidMetadata
            }
            // Repeating creation cannot change captured scope/revisions or revive work.
            let members = try allEmbeddingBatchMembers(batchID: batch.id)
            let captured = Set(members.map { $0.entityKind.rawValue + ":" + $0.entityID.uuidString + ":" + $0.revision })
            let requested = Set(selected.map { $0.entityKind.rawValue + ":" + $0.entityID.uuidString + ":" + $0.revision })
            guard captured == requested else { throw AIWorkLedgerError.invalidMetadata }
            return existing
        }
        let payload = try encode(batch)
        let members = selected.map { EmbeddingBackfillMember(batchID: batch.id, change: $0) }
        try transaction {
            try Self.execute(db, "INSERT INTO embedding_batches(batch_id,vault_id,payload) VALUES(?,?,?)",
                             [batch.id.uuidString, batch.vaultID.uuidString, payload])
            for member in members { try saveEmbeddingMember(member) }
        }
        return batch
    }

    public func embeddingBatch(id: UUID) throws -> EmbeddingBackfillBatch? {
        guard let row = try Self.queryRows(db, "SELECT batch_id,vault_id,payload FROM embedding_batches WHERE batch_id=?", [id.uuidString], columns: 3).first else { return nil }
        let batch = try decode(EmbeddingBackfillBatch.self, row[2])
        guard batch.id == id, row[0] == batch.id.uuidString, row[1] == batch.vaultID.uuidString else { throw AIWorkLedgerError.invalidMetadata }
        return batch
    }

    public func embeddingBatches(vaultID: UUID) throws -> [EmbeddingBackfillBatch] {
        let rows = try Self.queryRows(db, "SELECT batch_id,vault_id,payload FROM embedding_batches WHERE vault_id=? ORDER BY batch_id", [vaultID.uuidString], columns: 3)
        let batches = try rows.map { row in
            let batch = try decode(EmbeddingBackfillBatch.self, row[2])
            guard batch.vaultID == vaultID, row[0] == batch.id.uuidString, row[1] == batch.vaultID.uuidString else { throw AIWorkLedgerError.invalidMetadata }
            return batch
        }
        return batches.sorted { $0.createdAt < $1.createdAt }
    }

    /// Bounded inventory pages, never eager body/original loading.
    public func embeddingBatchMembers(batchID: UUID, limit: Int = 128, offset: Int = 0) throws -> [EmbeddingBackfillMember] {
        guard (1...128).contains(limit), offset >= 0 else { throw AIWorkLedgerError.invalidMetadata }
        let rows = try Self.queryRows(db, "SELECT batch_id,entity_kind,entity_id,work_id,state,payload FROM embedding_batch_members WHERE batch_id=? ORDER BY entity_kind,entity_id LIMIT ? OFFSET ?",
                                     [batchID.uuidString, String(limit), String(offset)], columns: 6)
        return try validateEmbeddingMembers(rows, batchID: batchID)
    }

    /// Reoffers the same work UUID until durable job admission is acknowledged. A crash
    /// between coordinator persistence and acknowledgment therefore cannot invent a second job.
    public func pendingEmbeddingAdmissions(batchID: UUID, limit: Int = 32) throws -> [EmbeddingBackfillMember] {
        guard (1...128).contains(limit) else { throw AIWorkLedgerError.invalidMetadata }
        guard let batch = try embeddingBatch(id: batchID), batch.state == .active else { return [] }
        let rows = try Self.queryRows(db, "SELECT batch_id,entity_kind,entity_id,work_id,state,payload FROM embedding_batch_members WHERE batch_id=? AND state='pending' ORDER BY entity_kind,entity_id LIMIT ?",
                                     [batchID.uuidString, String(limit)], columns: 6)
        let members = try validateEmbeddingMembers(rows, batchID: batchID)
        guard members.allSatisfy({ $0.state == .pending }) else { throw AIWorkLedgerError.invalidMetadata }
        return members
    }

    public func markEmbeddingMemberAdmitted(batchID: UUID, workID: UUID) throws {
        guard var member = try embeddingMember(batchID: batchID, workID: workID) else { throw AIWorkLedgerError.invalidMetadata }
        guard member.state == .pending else { return }
        guard let batch = try embeddingBatch(id: batchID), batch.state == .active else { throw AIWorkLedgerError.invalidMetadata }
        member.state = .admitted
        try saveEmbeddingMember(member)
    }

    /// State is control intent only. It confers no cloud approval or publication authority.
    public func setEmbeddingBatchState(batchID: UUID, state: EmbeddingBackfillState) throws {
        guard var batch = try embeddingBatch(id: batchID) else { throw AIWorkLedgerError.invalidMetadata }
        if [.cancelled, .completed, .incompatible].contains(batch.state), state != batch.state { throw AIWorkLedgerError.invalidMetadata }
        if batch.state == .cancellationRequested, ![.cancellationRequested, .cancelled].contains(state) { throw AIWorkLedgerError.invalidMetadata }
        if state == .completed {
            let members = try allEmbeddingBatchMembers(batchID: batchID)
            guard members.allSatisfy({ [.completed, .skipped].contains($0.state) }) else { throw AIWorkLedgerError.invalidMetadata }
        }
        batch.state = state
        try Self.execute(db, "UPDATE embedding_batches SET payload=? WHERE batch_id=?", [try encode(batch), batchID.uuidString])
    }

    /// Exact work identity prevents stale callbacks from updating a different admission.
    public func updateEmbeddingMember(batchID: UUID, workID: UUID, state: EmbeddingBackfillMemberState,
                                      failure: AIWorkFailure? = nil) throws {
        guard var member = try embeddingMember(batchID: batchID, workID: workID) else { throw AIWorkLedgerError.invalidMetadata }
        if member.state.isTerminal, state != member.state { throw AIWorkLedgerError.invalidMetadata }
        member.state = state; member.failure = failure
        try saveEmbeddingMember(member)
    }

    /// Call only after coordinator cancellation acknowledgment. Completed, skipped,
    /// unavailable and failed outcomes remain distinguishable from cancelled work.
    @discardableResult
    public func cancelEmbeddingMembers(batchID: UUID) throws -> Int {
        guard let batch = try embeddingBatch(id: batchID),
              [.cancellationRequested, .cancelled].contains(batch.state) else { throw AIWorkLedgerError.invalidMetadata }
        let members = try allEmbeddingBatchMembers(batchID: batchID)
        var count = 0
        try transaction {
            for var member in members where !member.state.isTerminal {
                member.state = .cancelled; member.failure = nil
                try saveEmbeddingMember(member); count += 1
            }
        }
        return count
    }

    /// Explicit retry preserves captured identity/revision and never revives successful or cancelled work.
    @discardableResult
    public func retryEmbeddingMembers(batchID: UUID) throws -> Int {
        guard let batch = try embeddingBatch(id: batchID),
              ![.cancelled, .cancellationRequested, .completed, .incompatible].contains(batch.state) else {
            throw AIWorkLedgerError.invalidMetadata
        }
        let members = try allEmbeddingBatchMembers(batchID: batchID)
        var count = 0
        try transaction {
            for var member in members where [.blocked, .interrupted, .failed, .unavailable].contains(member.state) {
                guard member.state == .interrupted || member.failure?.permitsExplicitRetry == true else { continue }
                member.state = .pending; member.failure = nil
                try saveEmbeddingMember(member); count += 1
            }
        }
        return count
    }

    private func embeddingMember(batchID: UUID, workID: UUID) throws -> EmbeddingBackfillMember? {
        let rows = try Self.queryRows(db, "SELECT batch_id,entity_kind,entity_id,work_id,state,payload FROM embedding_batch_members WHERE batch_id=? AND work_id=?", [batchID.uuidString, workID.uuidString], columns: 6)
        let member = try validateEmbeddingMembers(rows, batchID: batchID).first
        guard member == nil || member?.workID == workID else { throw AIWorkLedgerError.invalidMetadata }
        return member
    }
    private func allEmbeddingBatchMembers(batchID: UUID) throws -> [EmbeddingBackfillMember] {
        try validateEmbeddingMembers(Self.queryRows(db, "SELECT batch_id,entity_kind,entity_id,work_id,state,payload FROM embedding_batch_members WHERE batch_id=?", [batchID.uuidString], columns: 6), batchID: batchID)
    }
    private func validateEmbeddingMembers(_ rows: [[String]], batchID: UUID) throws -> [EmbeddingBackfillMember] {
        guard let batch = try embeddingBatch(id: batchID) else {
            if rows.isEmpty { return [] }; throw AIWorkLedgerError.invalidMetadata
        }
        return try rows.map { row in
            let member = try decode(EmbeddingBackfillMember.self, row[5])
            guard member.batchID == batchID, member.vaultID == batch.vaultID, batch.scopes.contains(member.entityKind),
                  !member.revision.isEmpty, member.revision.utf8.count <= 1024,
                  row[0] == member.batchID.uuidString, row[1] == member.entityKind.rawValue,
                  row[2] == member.entityID.uuidString, row[3] == member.workID.uuidString,
                  row[4] == member.state.rawValue else { throw AIWorkLedgerError.invalidMetadata }
            return member
        }
    }
    private func saveEmbeddingMember(_ member: EmbeddingBackfillMember) throws {
        try Self.execute(db, "INSERT INTO embedding_batch_members(batch_id,entity_kind,entity_id,work_id,state,payload) VALUES(?,?,?,?,?,?) ON CONFLICT(batch_id,entity_kind,entity_id) DO UPDATE SET state=excluded.state,payload=excluded.payload",
            [member.batchID.uuidString, member.entityKind.rawValue, member.entityID.uuidString,
             member.workID.uuidString, member.state.rawValue, try encode(member)])
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
    private static func queryRows(_ db: OpaquePointer, _ sql: String, _ values: [String], columns: Int) throws -> [[String]] {
        let statement = try statement(db, sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            var row: [String] = []
            for index in 0..<columns {
                guard let value = sqlite3_column_text(statement, Int32(index)) else { throw AIWorkLedgerError.invalidMetadata }
                row.append(String(cString: value))
            }
            result.append(row); code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw AIWorkLedgerError.unavailable }
        return result
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
