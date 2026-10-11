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
    @Test func rejectsFutureSchema() throws {
        let url = try database(); defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        try sql(url,"PRAGMA user_version=99")
        #expect(throws:AIActivityStoreError.unsupportedSchema) { try SQLiteAIActivityStore(url:url) }
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
