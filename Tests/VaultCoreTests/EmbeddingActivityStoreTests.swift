import Foundation
import SQLite3
import Testing
@testable import VaultCore

@Suite struct EmbeddingActivityStoreTests {
    private func url() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/embedding-activity/store-fixtures/\(UUID())/activity.sqlite")
    }
    private func execute(_ url: URL, _ sql: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        #expect(sqlite3_open(url.path, &pointer) == SQLITE_OK)
        let db = try #require(pointer); defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    /// Frozen v2 fixture; never derive a migration fixture from the current production schema.
    private func createV2(_ url: URL) throws {
        try execute(url, """
        CREATE TABLE activity (
          id TEXT PRIMARY KEY, started_at REAL NOT NULL, finished_at REAL, vault_id TEXT,
          target_type TEXT CHECK(target_type IN ('page','source')), target_id TEXT,
          action TEXT NOT NULL CHECK(action IN ('summarizePage','summarizeSource','suggestTitle','classifyLCC','processSource','createPageFromSource','createPageFromTopic','composePage','validateConnection')),
          execution_mode TEXT NOT NULL CHECK(execution_mode IN ('automatic','userInvoked')),
          provider TEXT NOT NULL CHECK(provider IN ('onDevice','openAI')), model_id TEXT CHECK(length(model_id)<=128),
          status TEXT NOT NULL CHECK(status IN ('running','completed','failed','cancelled','interrupted')),
          failure_code TEXT CHECK(failure_code IN ('cancelled','interrupted','unavailable','authorization','consent','network','invalidResponse','publication','unknown')),
          duration_ms INTEGER CHECK(duration_ms>=0), input_tokens INTEGER CHECK(input_tokens BETWEEN 0 AND 1000000000),
          output_tokens INTEGER CHECK(output_tokens BETWEEN 0 AND 1000000000), cached_input_tokens INTEGER CHECK(cached_input_tokens BETWEEN 0 AND input_tokens),
          estimated_cost_usd REAL CHECK(estimated_cost_usd BETWEEN 0 AND 1000000), request_count INTEGER NOT NULL CHECK(request_count BETWEEN 0 AND 1000000),
          content_size_bytes INTEGER CHECK(content_size_bytes BETWEEN 0 AND 1000000000),
          outcome TEXT NOT NULL CHECK(outcome IN ('published','suggested','rejected','notApplicable')),
          CHECK((target_type IS NULL AND target_id IS NULL) OR (target_type IS NOT NULL AND target_id IS NOT NULL))
        );
        CREATE INDEX activity_time ON activity(started_at DESC,id DESC);
        CREATE INDEX activity_vault ON activity(vault_id,started_at DESC);
        CREATE INDEX activity_target ON activity(target_type,target_id,started_at DESC);
        CREATE INDEX activity_provider ON activity(provider,started_at DESC);
        CREATE INDEX activity_status ON activity(status,started_at DESC);
        CREATE TABLE activity_settings (key TEXT PRIMARY KEY,value INTEGER);
        INSERT INTO activity_settings VALUES('retention_days',NULL);
        PRAGMA user_version=2;
        """)
    }
    @Test func embeddingActivityV2MigrationPreservesHistoryRetentionAndUnknownResponseCount() async throws {
        let url = url(), id = UUID(), now = Date(timeIntervalSince1970: 2_000_000_000)
        try createV2(url)
        try execute(url, """
        INSERT INTO activity(id,started_at,finished_at,action,execution_mode,provider,model_id,status,request_count,input_tokens,output_tokens,estimated_cost_usd,outcome)
        VALUES('\(id.uuidString)',1999999990,1999999995,'composePage','userInvoked','openAI','legacy-model','completed',2,100,20,0.01,'published');
        """)
        var store: SQLiteAIActivityStore? = try SQLiteAIActivityStore(url: url, now: now)
        let row = try #require(try await store?.query().first)
        #expect(row.id == id)
        #expect(row.action == .composePage)
        #expect(row.usage?.inputTokens == 100)
        #expect(row.requestCount == 2)
        #expect(row.providerResponseCount == nil)
        #expect(row.embeddingUsageCoverage == nil)
        #expect(row.estimatedCostUSD == 0.01)
        #expect(try await store?.retentionDays() == nil)
        let record = AIActivityRecord(startedAt: now, action: .embedQuery, executionMode: .userInvoked,
            provider: .openAI, providerResponseCount: 0)
        try await store?.insert(record)
        try await store?.recordDispatch(record.id)
        try await store?.recordProviderResponse(record.id)
        try await store?.recordUsage(record.id, usage: .init(inputTokens: 7, outputTokens: 0), estimatedCostUSD: nil)
        store = nil
        let reopened = try SQLiteAIActivityStore(url: url, now: now)
        let interrupted = try #require(try await reopened.query(.init(action: .embedQuery)).first)
        #expect(interrupted.status == .interrupted)
        #expect(interrupted.requestCount == 1)
        #expect(interrupted.providerResponseCount == 1)
        #expect(interrupted.usage?.inputTokens == 7)
        #expect(interrupted.embeddingUsageCoverage == .complete)
        #expect(try await reopened.retentionDays() == nil)
        #expect(try await reopened.count() == 2)
    }

    @Test func embeddingActivityUsageCoverageDoesNotInventTotalTokensOrCost() async throws {
        let store = try SQLiteAIActivityStore(url: url()), recorder = AIActivityRecorder(store: store)
        let id = await recorder.begin(action: .embedHistoricalBatch, executionMode: .userInvoked,
            provider: .openAI, providerResponseCount: 0)
        await recorder.recordDispatch(id)
        await recorder.recordDispatch(id)
        await recorder.recordProviderResponse(id)
        await recorder.recordUsage(id, usage: .init(inputTokens: 11, outputTokens: 0))
        await recorder.finish(id, status: .completed)
        let row = try #require(try await recorder.query().first)
        #expect(row.embeddingUsageCoverage == .partial)
        #expect(row.usage?.inputTokens == 11)
        #expect(row.estimatedCostUSD == nil)
        #expect(row.outcome == .notApplicable)
        let old = AIActivityRecord(action: .summarizePage, executionMode: .userInvoked, provider: .openAI,
            usage: .init(inputTokens: 10, outputTokens: 4), requestCount: 1)
        let decoded = try JSONDecoder().decode(AIActivityRecord.self, from: JSONEncoder().encode(old))
        #expect(decoded == old)
        #expect(decoded.providerResponseCount == nil)
        #expect(decoded.embeddingUsageCoverage == nil)
    }
}
