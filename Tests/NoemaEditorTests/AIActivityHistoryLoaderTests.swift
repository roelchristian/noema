import Foundation
import Testing
import VaultCore
@testable import noema

@Suite @MainActor struct AIActivityHistoryLoaderTests {
    @Test func delayedReadCannotRestoreClearedHistory() async throws {
        let gate = HistoryReadGate()
        let store = HistoryReadStore(gate: gate)
        let recorder = AIActivityRecorder(store: store)
        let loader = AIActivityHistoryLoader()
        let first = Task { await loader.load(recorder: recorder, query: .init()) }
        await gate.waitUntilEntered()
        loader.invalidate()
        try await recorder.clearHistory()
        #expect(await loader.load(recorder: recorder, query: .init()))
        #expect(loader.records.isEmpty && loader.total == 0)
        await gate.release()
        #expect(await first.value == false)
        #expect(loader.records.isEmpty && loader.total == 0 && !loader.loading)
    }

    @Test func latestRefreshOwnsTheSnapshotEvenWhenEarlierReadReturnsLast() async throws {
        let gate = HistoryReadGate()
        let store = HistoryReadStore(gate: gate)
        let recorder = AIActivityRecorder(store: store)
        let loader = AIActivityHistoryLoader()
        let first = Task { await loader.load(recorder: recorder, query: .init()) }
        await gate.waitUntilEntered()
        #expect(await loader.load(recorder: recorder, query: .init(provider: .openAI)))
        let latest = loader.records
        #expect(latest.count == 1 && latest.first?.provider == .openAI)
        await gate.release()
        #expect(await first.value == false)
        #expect(loader.records == latest && loader.total == 1 && !loader.loading)
    }
}

private actor HistoryReadGate {
    private var entered = false
    private var admission: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        admission?.resume(); admission = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { admission = $0 }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

/// Returns the first pre-mutation snapshot late, matching an asynchronous SQLite
/// query whose result is suspended while a newer query or Clear History completes.
private actor HistoryReadStore: AIActivityStore {
    let gate: HistoryReadGate
    private var queried = false
    private var records = [
        AIActivityRecord(action: .summarizePage, executionMode: .userInvoked, provider: .onDevice),
        AIActivityRecord(action: .summarizePage, executionMode: .userInvoked, provider: .openAI)
    ]
    init(gate: HistoryReadGate) { self.gate = gate }
    func query(_ query: AIActivityQuery) async throws -> [AIActivityRecord] {
        let snapshot = matching(query)
        if !queried { queried = true; await gate.pause() }
        return snapshot
    }
    func count(_ query: AIActivityQuery) async throws -> Int { matching(query).count }
    private func matching(_ query: AIActivityQuery) -> [AIActivityRecord] {
        records.filter { query.provider == nil || $0.provider == query.provider }
    }
    func clearHistory() async throws { records = [] }
    func insert(_ record: AIActivityRecord) async throws { records.append(record) }
    func recordDispatch(_ id: UUID) async throws {}
    func recordUsage(_ id: UUID, usage: AIActivityUsage, estimatedCostUSD: Double?) async throws {}
    func finish(_ id: UUID, at: Date, status: AIActivityStatus, outcome: AIActivityOutcome, failureCode: AIActivityFailureCode?) async throws {}
    func updateOutcome(_ id: UUID, outcome: AIActivityOutcome) async throws {}
    func retentionDays() async throws -> Int? { 90 }
    func setRetentionDays(_ days: Int?) async throws {}
    func prune(before now: Date) async throws {}
}
