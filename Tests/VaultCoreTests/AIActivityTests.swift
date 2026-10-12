import Foundation
import SQLite3
import Testing
@testable import VaultCore

@Suite struct AIActivityTests {
    private func database() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noema-activity-tests-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return directory.appendingPathComponent("activity.sqlite")
    }
    private func sql(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path,&db) == SQLITE_OK)
        let pointer = try #require(db); defer { sqlite3_close(pointer) }
        #expect(sqlite3_exec(pointer,sql,nil,nil,nil) == SQLITE_OK)
    }
    private func scalar(_ url: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let pointer = try #require(db); defer { sqlite3_close(pointer) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK)
        let prepared = try #require(statement); defer { sqlite3_finalize(prepared) }
        #expect(sqlite3_step(prepared) == SQLITE_ROW)
        return Int(sqlite3_column_int64(prepared, 0))
    }
    /// Frozen v1 schema: migration tests must not derive their fixture from v2.
    private func createV1Database(_ url: URL) throws {
        try sql(url, """
        CREATE TABLE activity (
          id TEXT PRIMARY KEY, started_at REAL NOT NULL, finished_at REAL, vault_id TEXT,
          target_type TEXT CHECK(target_type IN ('page','source')), target_id TEXT,
          action TEXT NOT NULL CHECK(action IN ('summarizePage','summarizeSource','suggestTitle','classifyLCC','processSource','createPageFromSource','createPageFromTopic','validateConnection')),
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
        PRAGMA user_version=1;
        """)
    }
    @Test func concurrentDispatchAndExactlyOnceFinalization() async throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let store = try SQLiteAIActivityStore(url:url)
        let recorder = AIActivityRecorder(store:store)
        let id = await recorder.begin(action:.summarizePage,executionMode:.userInvoked,provider:.openAI,modelID:"test-model")
        await withTaskGroup(of:Void.self) { group in
            for _ in 0..<40 { group.addTask { await recorder.recordDispatch(id) } }
        }
        await recorder.recordUsage(id,usage:.init(inputTokens:200,outputTokens:50,cachedInputTokens:100),estimatedCostUSD:0.002)
        await recorder.finish(id,status:.completed,outcome:.published)
        await withTaskGroup(of:Void.self) { group in
            for _ in 0..<40 { group.addTask { await recorder.finish(id,status:.failed,failureCode:.network); await recorder.recordDispatch(id) } }
        }
        // A second begin with the same logical identity cannot overwrite a terminal result.
        await recorder.begin(id:id,action:.summarizeSource,executionMode:.automatic,provider:.onDevice)
        let rows = try await recorder.query()
        let row = try #require(rows.first)
        #expect(rows.count == 1); #expect(row.status == .completed); #expect(row.outcome == .published)
        #expect(row.requestCount == 40); #expect(row.action == .summarizePage)
        #expect(row.usage?.cachedInputTokens == 100); #expect(row.estimatedCostUSD == 0.002)
        #expect(row.durationMilliseconds != nil)
    }
    @Test func startupReconcilesInterruptedAndPreservesTerminalRows() async throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970:2_000_000_000)
        var first: SQLiteAIActivityStore? = try SQLiteAIActivityStore(url:url,now:now)
        let running = AIActivityRecord(startedAt:now,action:.classifyLCC,executionMode:.automatic,provider:.onDevice)
        let finished = AIActivityRecord(startedAt:now,action:.classifyLCC,executionMode:.automatic,provider:.onDevice,status:.completed)
        try await first?.insert(running); try await first?.insert(finished); first = nil
        let reopened = try SQLiteAIActivityStore(url:url,now:now.addingTimeInterval(3))
        let rows = try await reopened.query()
        let interrupted = try #require(rows.first { $0.id == running.id })
        #expect(interrupted.status == .interrupted); #expect(interrupted.failureCode == .interrupted)
        #expect(interrupted.durationMilliseconds == 3000)
        #expect(rows.first { $0.id == finished.id }?.status == .completed)
    }
    @Test func queriesPaginateAndFilterWithoutContent() async throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let store = try SQLiteAIActivityStore(url:url)
        let vault = UUID(), otherVault = UUID(), target = AIActivityTarget(type:.page,id:UUID()), now = Date()
        for index in 0..<8 {
            try await store.insert(AIActivityRecord(startedAt:now.addingTimeInterval(Double(index)),vaultID:index < 6 ? vault : otherVault,target:target,action:.suggestTitle,executionMode:.userInvoked,provider:index.isMultiple(of:2) ? .openAI : .onDevice,status:.completed,outcome:.suggested))
        }
        let first = try await store.query(.init(vaultID:vault,limit:2))
        let next = try await store.query(.init(vaultID:vault,limit:2,offset:2))
        #expect(first.count == 2); #expect(next.count == 2)
        #expect(Set(first.map(\.id)).isDisjoint(with:next.map(\.id)))
        #expect(first[1].startedAt > next[0].startedAt)
        #expect(try await store.count(.init(vaultID:vault,provider:.openAI,action:.suggestTitle,outcome:.suggested)) == 3)
        #expect(try await store.count(.init(target:target)) == 8)
        #expect(try await store.count(.init(startedAfter:now.addingTimeInterval(7))) == 1)
    }
    @Test func migrationRetentionAndClearDoNotRestoreInFlightRows() async throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        try sql(url,"PRAGMA user_version=0")
        let now = Date()
        let store = try SQLiteAIActivityStore(url:url,now:now)
        #expect(try await store.retentionDays() == 90)
        let old = AIActivityRecord(startedAt:now.addingTimeInterval(-91*86400),action:.processSource,executionMode:.automatic,provider:.onDevice,status:.completed)
        let active = AIActivityRecord(startedAt:old.startedAt,action:.processSource,executionMode:.automatic,provider:.onDevice)
        try await store.insert(old); try await store.insert(active)
        try await store.prune(before:now)
        #expect(try await store.count(.init()) == 1)
        try await store.setRetentionDays(nil)
        try await store.insert(old); try await store.prune(before:now)
        #expect(try await store.count(.init()) == 2)
        try await store.clearHistory()
        try await store.finish(active.id,at:now,status:.completed,outcome:.published,failureCode:nil)
        #expect(try await store.count(.init()) == 0)
        try await store.setRetentionDays(30)
        let reopened = try SQLiteAIActivityStore(url:url,now:now)
        #expect(try await reopened.retentionDays() == 30)
        do { try await reopened.setRetentionDays(0); Issue.record("Invalid retention accepted") } catch {}
    }
    @Test func v1MigrationPreservesMetadataSettingsAndIndexesAndAcceptsComposition() async throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try createV1Database(url)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-100 * 86400), finish = start.addingTimeInterval(3)
        let id = UUID(), vault = UUID(), target = UUID(), running = UUID()
        try sql(url, """
        INSERT INTO activity VALUES('\(id.uuidString)',\(start.timeIntervalSince1970),\(finish.timeIntervalSince1970),'\(vault.uuidString)','page','\(target.uuidString)','createPageFromTopic','userInvoked','openAI','test-model','completed',NULL,3000,100,20,10,0.01,2,999,'published');
        INSERT INTO activity(id,started_at,action,execution_mode,provider,status,request_count,outcome) VALUES('\(running.uuidString)',\(now.timeIntervalSince1970),'summarizeSource','automatic','onDevice','running',0,'notApplicable');
        """)
        var store: SQLiteAIActivityStore? = try SQLiteAIActivityStore(url: url, now: now)
        let migrated = try #require(try await store?.query(.init()).first { $0.id == id })
        #expect(migrated == AIActivityRecord(id: id, startedAt: start, finishedAt: finish,
            vaultID: vault, target: .init(type: .page, id: target), action: .createPageFromTopic,
            executionMode: .userInvoked, provider: .openAI, modelID: "test-model", status: .completed,
            durationMilliseconds: 3000, usage: .init(inputTokens: 100, outputTokens: 20, cachedInputTokens: 10),
            estimatedCostUSD: 0.01, requestCount: 2, contentSizeBytes: 999, outcome: .published))
        #expect(try await store?.retentionDays() == nil)
        #expect(try await store?.query(.init()).first { $0.id == running }?.status == .interrupted)
        let composed = AIActivityRecord(startedAt: now, action: .composePage, executionMode: .userInvoked, provider: .openAI)
        try await store?.insert(composed)
        // Migration only reconciles during opening; a newly inserted operation stays running.
        #expect(try await store?.query(.init(action: .composePage)).first?.status == .running)
        try await store?.finish(composed.id, at: now, status: .completed, outcome: .published, failureCode: nil)
        #expect(try scalar(url, "PRAGMA user_version") == 2)
        #expect(try scalar(url, "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('activity_time','activity_vault','activity_target','activity_provider','activity_status')") == 5)
        try await store?.setRetentionDays(30)
        store = nil
        let reopened = try SQLiteAIActivityStore(url: url, now: now)
        #expect(try await reopened.retentionDays() == 30)
        #expect(try await reopened.query(.init(action: .composePage)).first?.id == composed.id)
        #expect(try await reopened.query(.init()).allSatisfy { $0.id != id })
    }
    @Test func failedV1MigrationRollsBackOriginalTableAndVersion() throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try createV1Database(url)
        try sql(url, """
        PRAGMA ignore_check_constraints=ON;
        INSERT INTO activity(id,started_at,action,execution_mode,provider,status,request_count,outcome) VALUES('\(UUID().uuidString)',2000000000,'invalidAction','automatic','onDevice','completed',0,'notApplicable');
        PRAGMA ignore_check_constraints=OFF;
        """)
        #expect(throws: AIActivityStoreError.unavailable) { try SQLiteAIActivityStore(url: url) }
        #expect(try scalar(url, "PRAGMA user_version") == 1)
        #expect(try scalar(url, "SELECT COUNT(*) FROM activity WHERE action='invalidAction'") == 1)
        #expect(try scalar(url, "SELECT COUNT(*) FROM sqlite_master WHERE name='activity_previous'") == 0)
        #expect(try scalar(url, "SELECT COUNT(*) FROM sqlite_master WHERE name='activity_time'") == 1)
    }
    @Test(arguments: [3, 99, -1]) func rejectsUnsupportedSchema(version: Int) throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        try sql(url,"PRAGMA user_version=\(version)")
        #expect(throws:AIActivityStoreError.unsupportedSchema) { try SQLiteAIActivityStore(url:url) }
        #expect(try scalar(url, "PRAGMA user_version") == version)
    }
    @Test func metadataValidationAndExportExcludePayloads() async throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let store = try SQLiteAIActivityStore(url:url), recorder = AIActivityRecorder(store:store)
        let secret = "Bearer sk-private\nUser document text and response payload"
        let id = await recorder.begin(action:.summarizePage,executionMode:.userInvoked,provider:.openAI,modelID:secret,contentSizeBytes:-1)
        await recorder.recordUsage(id,usage:.init(inputTokens:-1,outputTokens:10,cachedInputTokens:20),estimatedCostUSD:.infinity)
        await recorder.finish(id,status:.failed,failureCode:.invalidResponse)
        let row = try #require(try await recorder.query().first)
        #expect(row.modelID == nil); #expect(row.contentSizeBytes == nil)
        #expect(row.usage?.inputTokens == nil); #expect(row.usage?.cachedInputTokens == nil); #expect(row.estimatedCostUSD == nil)
        let bytes = try await recorder.exportMetadata()
        let export = String(decoding:bytes,as:UTF8.self)
        #expect(!export.contains("sk-private")); #expect(!export.contains("document text"))
        let persisted = try Data(contentsOf:url)
        #expect(persisted.range(of:Data(secret.utf8)) == nil)
        let keys = try #require((JSONSerialization.jsonObject(with:bytes) as? [[String:Any]])?.first).keys
        #expect(Set(keys).isDisjoint(with:["title","body","prompt","response","credential","consentReceipt","capability"]))
    }
    @Test func onDeviceNeverAcquiresCloudUsageAndSuggestionsFinalizeOnce() async throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let store = try SQLiteAIActivityStore(url:url)
        let r = AIActivityRecord(action:.suggestTitle,executionMode:.automatic,provider:.onDevice,usage:.init(inputTokens:100,outputTokens:10),estimatedCostUSD:0.5,requestCount:4)
        #expect(r.requestCount == 0); #expect(r.usage == nil); #expect(r.estimatedCostUSD == nil)
        try await store.insert(r); try await store.recordDispatch(r.id)
        try await store.recordUsage(r.id,usage:.init(inputTokens:200,outputTokens:20),estimatedCostUSD:1)
        try await store.finish(r.id,at:Date(),status:.completed,outcome:.suggested,failureCode:nil)
        try await store.updateOutcome(r.id,outcome:.published); try await store.updateOutcome(r.id,outcome:.rejected)
        let row = try #require(try await store.query().first)
        #expect(row.requestCount == 0); #expect(row.usage == nil); #expect(row.estimatedCostUSD == nil)
        #expect(row.status == .completed); #expect(row.outcome == .published)
        // Synthesized Codable can bypass an initializer; the persistence boundary revalidates too.
        let cloud = AIActivityRecord(action:.suggestTitle,executionMode:.automatic,provider:.openAI,usage:.init(inputTokens:100,outputTokens:10),estimatedCostUSD:0.5,requestCount:4)
        var object = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(cloud)) as? [String:Any])
        object["provider"] = "onDevice"; object["modelID"] = "credential\nprivate-body"
        let decoded = try JSONDecoder().decode(AIActivityRecord.self,from:JSONSerialization.data(withJSONObject:object))
        #expect(decoded.requestCount == 4)
        try await store.insert(decoded)
        let sanitized = try #require(try await store.query().first { $0.id == cloud.id })
        #expect(sanitized.requestCount == 0); #expect(sanitized.usage == nil); #expect(sanitized.estimatedCostUSD == nil)
        #expect(sanitized.modelID == nil)
    }
    @Test func recordingUnavailableNeverThrowsIntoOperation() async throws {
        let recorder = AIActivityRecorder(store:FailingActivityStore())
        let fixed = UUID()
        let id = await recorder.begin(id:fixed,action:.summarizePage,executionMode:.userInvoked,provider:.openAI)
        await recorder.recordDispatch(id); await recorder.recordUsage(id,usage:.init(inputTokens:1,outputTokens:2))
        await recorder.finish(id,status:.completed,outcome:.published); await recorder.updateOutcome(id,outcome:.rejected)
        #expect(id == fixed); #expect(await recorder.recordingUnavailable)
        do { _ = try await recorder.query(); Issue.record("Failed store should report history unavailable") } catch {}
    }
    @Test func sqliteOpenFailureIsBestEffortAndPreservesExistingFile() async throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let marker = Data("not-a-database-preserve-this-file".utf8)
        try marker.write(to:url)
        let recorder = AIActivityRecorder(url:url)
        let id = await recorder.begin(action:.processSource,executionMode:.automatic,provider:.onDevice)
        await recorder.finish(id,status:.completed,outcome:.published)
        #expect(await recorder.recordingUnavailable)
        #expect(try Data(contentsOf:url) == marker)
        do { _ = try await recorder.query(); Issue.record("Invalid database should report unavailable") } catch {}
    }
}

private actor FailingActivityStore: AIActivityStore {
    func insert(_ record:AIActivityRecord) throws { throw AIActivityStoreError.unavailable }
    func recordDispatch(_ id:UUID) throws { throw AIActivityStoreError.unavailable }
    func recordUsage(_ id:UUID,usage:AIActivityUsage,estimatedCostUSD:Double?) throws { throw AIActivityStoreError.unavailable }
    func finish(_ id:UUID,at:Date,status:AIActivityStatus,outcome:AIActivityOutcome,failureCode:AIActivityFailureCode?) throws { throw AIActivityStoreError.unavailable }
    func updateOutcome(_ id:UUID,outcome:AIActivityOutcome) throws { throw AIActivityStoreError.unavailable }
    func query(_ query:AIActivityQuery) throws -> [AIActivityRecord] { throw AIActivityStoreError.unavailable }
    func count(_ query:AIActivityQuery) throws -> Int { throw AIActivityStoreError.unavailable }
    func retentionDays() throws -> Int? { throw AIActivityStoreError.unavailable }
    func setRetentionDays(_ days:Int?) throws { throw AIActivityStoreError.unavailable }
    func prune(before now:Date) throws { throw AIActivityStoreError.unavailable }
    func clearHistory() throws { throw AIActivityStoreError.unavailable }
}
