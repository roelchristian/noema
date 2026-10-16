import Foundation
import SQLite3

// Only this actor uses the connection after initialization. SQLite owns its WAL/SHM files.
private final class AIActivityConnection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }; throw AIActivityStoreError.unavailable
        }
        self.pointer = pointer
    }
    deinit { sqlite3_close(pointer) }
}

/// App-local metadata, independent of canonical vault storage and search-index rebuilding.
public actor SQLiteAIActivityStore: AIActivityStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noema/Activity/activity.sqlite")
    }
    private let connection: AIActivityConnection
    private static let legacyColumns = "id,started_at,finished_at,vault_id,target_type,target_id,action,execution_mode,provider,model_id,status,failure_code,duration_ms,input_tokens,output_tokens,cached_input_tokens,estimated_cost_usd,request_count,content_size_bytes,outcome"
    private static let columns = legacyColumns + ",response_count"
    private static let activitySchema = """
    (
      id TEXT PRIMARY KEY, started_at REAL NOT NULL, finished_at REAL, vault_id TEXT,
      target_type TEXT CHECK(target_type IN ('page','source')), target_id TEXT,
      action TEXT NOT NULL CHECK(action IN ('summarizePage','summarizeSource','suggestTitle','classifyLCC','processSource','createPageFromSource','createPageFromTopic','composePage','validateConnection','embedDocument','embedHistoricalBatch','embedQuery')),
      execution_mode TEXT NOT NULL CHECK(execution_mode IN ('automatic','userInvoked')),
      provider TEXT NOT NULL CHECK(provider IN ('onDevice','openAI')), model_id TEXT CHECK(length(model_id)<=128),
      status TEXT NOT NULL CHECK(status IN ('running','completed','failed','cancelled','interrupted')),
      failure_code TEXT CHECK(failure_code IN ('cancelled','interrupted','unavailable','authorization','consent','network','invalidResponse','publication','unknown')),
      duration_ms INTEGER CHECK(duration_ms>=0), input_tokens INTEGER CHECK(input_tokens BETWEEN 0 AND 1000000000),
      output_tokens INTEGER CHECK(output_tokens BETWEEN 0 AND 1000000000), cached_input_tokens INTEGER CHECK(cached_input_tokens BETWEEN 0 AND input_tokens),
      estimated_cost_usd REAL CHECK(estimated_cost_usd BETWEEN 0 AND 1000000), request_count INTEGER NOT NULL CHECK(request_count BETWEEN 0 AND 1000000),
      content_size_bytes INTEGER CHECK(content_size_bytes BETWEEN 0 AND 1000000000),
      outcome TEXT NOT NULL CHECK(outcome IN ('published','suggested','rejected','notApplicable')),
      response_count INTEGER CHECK(response_count BETWEEN 0 AND request_count),
      CHECK((target_type IS NULL AND target_id IS NULL) OR (target_type IS NOT NULL AND target_id IS NOT NULL))
    )
    """
    public init(url: URL = SQLiteAIActivityStore.defaultURL, now: Date = Date(), retentionDays: Int? = 90) throws {
        guard retentionDays == nil || (1...3650).contains(retentionDays!) else { throw AIActivityStoreError.invalidRetention }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try AIActivityConnection(url: url)
        let db = connection.pointer
        sqlite3_busy_timeout(db, 2_000)
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK, let versionStatement else { throw AIActivityStoreError.unavailable }
        let result = sqlite3_step(versionStatement)
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard result == SQLITE_ROW else { throw AIActivityStoreError.unavailable }
        guard (0...3).contains(version) else { throw AIActivityStoreError.unsupportedSchema }
        // SQLite cannot extend a CHECK constraint in place. Rebuild inside the same
        // transaction, copy every metadata column, then recreate indexes after the old
        // table (and its indexes) is dropped. Fresh version-zero databases copy no rows.
        let migration = version < 3 ? """
        ALTER TABLE activity RENAME TO activity_previous;
        CREATE TABLE activity \(Self.activitySchema);
        INSERT INTO activity(\(Self.legacyColumns)) SELECT \(Self.legacyColumns) FROM activity_previous;
        DROP TABLE activity_previous;
        """ : ""
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS activity \(Self.activitySchema);
        \(migration)
        CREATE INDEX IF NOT EXISTS activity_time ON activity(started_at DESC,id DESC);
        CREATE INDEX IF NOT EXISTS activity_vault ON activity(vault_id,started_at DESC);
        CREATE INDEX IF NOT EXISTS activity_target ON activity(target_type,target_id,started_at DESC);
        CREATE INDEX IF NOT EXISTS activity_provider ON activity(provider,started_at DESC);
        CREATE INDEX IF NOT EXISTS activity_status ON activity(status,started_at DESC);
        CREATE TABLE IF NOT EXISTS activity_settings (key TEXT PRIMARY KEY,value INTEGER);
        PRAGMA user_version=3;
        COMMIT;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw AIActivityStoreError.unavailable }
        try Self.execute(db, "INSERT OR IGNORE INTO activity_settings(key,value) VALUES('retention_days',?)", [retentionDays.map(String.init)])
        guard now.timeIntervalSince1970.isFinite else { throw AIActivityStoreError.invalidMetadata }
        // A process restart cannot resume inference or publication authority from a historical row.
        // Production owns one connection through AIActivityRecorder.shared. Opening another store
        // for the same URL is a startup reconciliation, not support for multiple live writers.
        try Self.execute(db, "UPDATE activity SET status='interrupted',failure_code='interrupted',outcome='notApplicable',finished_at=?,duration_ms=CAST(MAX(0,(?-started_at)*1000) AS INTEGER) WHERE status='running'", [String(now.timeIntervalSince1970),String(now.timeIntervalSince1970)])
        try Self.execute(db, "DELETE FROM activity WHERE status!='running' AND started_at < ?-(SELECT value*86400 FROM activity_settings WHERE key='retention_days')", [String(now.timeIntervalSince1970)])
    }
    private var db: OpaquePointer { connection.pointer }
    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ values: [String?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AIActivityStoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index,value) in values.enumerated() {
            let code: Int32
            if let value { code = sqlite3_bind_text(statement,Int32(index+1),value,-1,transient) }
            else { code = sqlite3_bind_null(statement,Int32(index+1)) }
            guard code == SQLITE_OK else { throw AIActivityStoreError.unavailable }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AIActivityStoreError.unavailable }
    }
    private func statement(_ sql: String, _ values: [String?] = []) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw AIActivityStoreError.unavailable }
        for (index, value) in values.enumerated() {
            let code: Int32
            if let value { code = sqlite3_bind_text(s,Int32(index+1),value,-1,transient) }
            else { code = sqlite3_bind_null(s,Int32(index+1)) }
            guard code == SQLITE_OK else { sqlite3_finalize(s); throw AIActivityStoreError.unavailable }
        }
        return s
    }
    private func run(_ sql: String, _ values: [String?] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw AIActivityStoreError.unavailable }
    }
    public func insert(_ r: AIActivityRecord) throws {
        guard r.startedAt.timeIntervalSince1970.isFinite, r.finishedAt?.timeIntervalSince1970.isFinite != false else { throw AIActivityStoreError.invalidMetadata }
        let usage = r.provider == .openAI ? r.usage.map { AIActivityUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cachedInputTokens: $0.cachedInputTokens) } : nil
        let cost = r.provider == .openAI ? r.estimatedCostUSD.flatMap { $0.isFinite && (0...1_000_000).contains($0) ? $0 : nil } : nil
        try run("INSERT OR IGNORE INTO activity(\(Self.columns)) VALUES(\(Array(repeating: "?", count: 21).joined(separator: ",")))", [
            r.id.uuidString, String(r.startedAt.timeIntervalSince1970), r.finishedAt.map { String($0.timeIntervalSince1970) }, r.vaultID?.uuidString,
            r.target?.type.rawValue, r.target?.id.uuidString, r.action.rawValue, r.executionMode.rawValue, r.provider.rawValue,
            AIActivityRecord.validatedModelID(r.modelID), r.status.rawValue, r.failureCode?.rawValue, r.durationMilliseconds.map(String.init),
            usage?.inputTokens.map(String.init), usage?.outputTokens.map(String.init), usage?.cachedInputTokens.map(String.init), cost.map { String($0) },
            String(r.provider == .openAI ? min(1_000_000,max(0,r.requestCount)) : 0), r.contentSizeBytes.flatMap { (0...1_000_000_000).contains($0) ? String($0) : nil }, r.outcome.rawValue, r.providerResponseCount.map(String.init)
        ])
    }
    public func recordDispatch(_ id: UUID) throws {
        try run("UPDATE activity SET request_count=MIN(1000000,request_count+1) WHERE id=? AND status='running' AND provider='openAI'", [id.uuidString])
    }
    public func recordProviderResponse(_ id: UUID) async throws {
        try run("UPDATE activity SET response_count=MIN(request_count,response_count+1) WHERE id=? AND status='running' AND provider='openAI' AND response_count IS NOT NULL", [id.uuidString])
    }
    public func recordUsage(_ id: UUID, usage: AIActivityUsage, estimatedCostUSD: Double?) throws {
        let usage = AIActivityUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, cachedInputTokens: usage.cachedInputTokens)
        let cost = estimatedCostUSD.flatMap { $0.isFinite && (0...1_000_000).contains($0) ? $0 : nil }
        try run("UPDATE activity SET input_tokens=?,output_tokens=?,cached_input_tokens=?,estimated_cost_usd=? WHERE id=? AND status='running' AND provider='openAI'", [usage.inputTokens.map(String.init),usage.outputTokens.map(String.init),usage.cachedInputTokens.map(String.init),cost.map { String($0) },id.uuidString])
    }
    public func finish(_ id: UUID, at: Date, status: AIActivityStatus, outcome: AIActivityOutcome, failureCode: AIActivityFailureCode?) throws {
        guard status != .running, at.timeIntervalSince1970.isFinite else { throw AIActivityStoreError.invalidMetadata }
        try run("UPDATE activity SET status=?,outcome=?,failure_code=?,finished_at=?,duration_ms=CAST(MAX(0,(?-started_at)*1000) AS INTEGER) WHERE id=? AND status='running'", [status.rawValue,outcome.rawValue,failureCode?.rawValue,String(at.timeIntervalSince1970),String(at.timeIntervalSince1970),id.uuidString])
    }
    public func updateOutcome(_ id: UUID, outcome: AIActivityOutcome) throws {
        guard outcome == .published || outcome == .rejected else { return }
        try run("UPDATE activity SET outcome=? WHERE id=? AND status='completed' AND outcome='suggested'", [outcome.rawValue,id.uuidString])
    }
    private func filter(_ q: AIActivityQuery) -> (String,[String?]) {
        var clauses = [String](), values = [String?]()
        func add(_ clause: String, _ value: String?) { if let value { clauses.append(clause); values.append(value) } }
        add("vault_id=?",q.vaultID?.uuidString); add("target_type=?",q.target?.type.rawValue); add("target_id=?",q.target?.id.uuidString)
        add("provider=?",q.provider?.rawValue); add("action=?",q.action?.rawValue); add("status=?",q.status?.rawValue); add("outcome=?",q.outcome?.rawValue)
        add("started_at>=?",q.startedAfter.flatMap { $0.timeIntervalSince1970.isFinite ? String($0.timeIntervalSince1970) : nil })
        add("started_at<=?",q.startedBefore.flatMap { $0.timeIntervalSince1970.isFinite ? String($0.timeIntervalSince1970) : nil })
        return (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "),values)
    }
    public func query(_ query: AIActivityQuery = .init()) throws -> [AIActivityRecord] {
        let (filter, values) = filter(query)
        let s = try statement("SELECT \(Self.columns) FROM activity\(filter) ORDER BY started_at DESC,id DESC LIMIT ? OFFSET ?", values + [String(min(1000,max(1,query.limit))),String(max(0,query.offset))])
        defer { sqlite3_finalize(s) }
        var records = [AIActivityRecord](), code = sqlite3_step(s)
        while code == SQLITE_ROW { records.append(try decode(s)); code = sqlite3_step(s) }
        guard code == SQLITE_DONE else { throw AIActivityStoreError.unavailable }; return records
    }
    private func decode(_ s: OpaquePointer) throws -> AIActivityRecord {
        func text(_ index: Int32) -> String? { sqlite3_column_text(s,index).map { String(cString:$0) } }
        func number(_ index: Int32) -> Int? { sqlite3_column_type(s,index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s,index)) }
        func date(_ index: Int32) -> Date? { sqlite3_column_type(s,index) == SQLITE_NULL ? nil : Date(timeIntervalSince1970:sqlite3_column_double(s,index)) }
        guard let id = text(0).flatMap(UUID.init(uuidString:)), let start = date(1),
              let action = text(6).flatMap(AIActivityAction.init(rawValue:)), let mode = text(7).flatMap(AIActivityExecutionMode.init(rawValue:)),
              let provider = text(8).flatMap(AIActivityProvider.init(rawValue:)), let status = text(10).flatMap(AIActivityStatus.init(rawValue:)),
              let outcome = text(19).flatMap(AIActivityOutcome.init(rawValue:)) else { throw AIActivityStoreError.invalidMetadata }
        let target: AIActivityTarget?
        if let kind = text(4).flatMap(AIActivityTarget.Kind.init(rawValue:)), let targetID = text(5).flatMap(UUID.init(uuidString:)) { target = AIActivityTarget(type:kind,id:targetID) } else { target = nil }
        let usage = number(13) == nil && number(14) == nil && number(15) == nil ? nil : AIActivityUsage(inputTokens:number(13),outputTokens:number(14),cachedInputTokens:number(15))
        return AIActivityRecord(id:id,startedAt:start,finishedAt:date(2),vaultID:text(3).flatMap(UUID.init(uuidString:)),target:target,action:action,executionMode:mode,provider:provider,modelID:text(9),status:status,failureCode:text(11).flatMap(AIActivityFailureCode.init(rawValue:)),durationMilliseconds:number(12),usage:usage,estimatedCostUSD:sqlite3_column_type(s,16) == SQLITE_NULL ? nil : sqlite3_column_double(s,16),requestCount:number(17) ?? 0,contentSizeBytes:number(18),outcome:outcome,providerResponseCount:number(20))
    }
    public func count(_ query: AIActivityQuery = .init()) throws -> Int {
        let (filter,values) = filter(query); let s = try statement("SELECT COUNT(*) FROM activity\(filter)",values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw AIActivityStoreError.unavailable }; return Int(sqlite3_column_int64(s,0))
    }
    public func retentionDays() throws -> Int? {
        let s = try statement("SELECT value FROM activity_settings WHERE key='retention_days'"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw AIActivityStoreError.unavailable }
        return sqlite3_column_type(s,0) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s,0))
    }
    public func setRetentionDays(_ days: Int?) throws {
        guard days == nil || (1...3650).contains(days!) else { throw AIActivityStoreError.invalidRetention }
        try run("UPDATE activity_settings SET value=? WHERE key='retention_days'",[days.map(String.init)])
    }
    public func prune(before now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite else { throw AIActivityStoreError.invalidMetadata }
        guard let days = try retentionDays() else { return }
        try run("DELETE FROM activity WHERE status!='running' AND started_at<?",[String(now.addingTimeInterval(-Double(days)*86400).timeIntervalSince1970)])
    }
    public func clearHistory() throws { try run("DELETE FROM activity") }
}
