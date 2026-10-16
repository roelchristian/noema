import Foundation
import Testing
@testable import VaultCore

private actor LifecycleMemoryLedger: AIWorkLedger {
    var rows: [AIWorkKey: AIWorkItem] = [:]
    var baseline: [AIContentChange]?
    func load(vaultID: UUID) -> [AIWorkItem] { rows.values.filter { $0.key.vaultID == vaultID } }
    func save(_ item: AIWorkItem) { rows[item.key] = item }
    func checkpoint(vaultID: UUID) -> [AIContentChange]? { baseline }
    func saveCheckpoint(vaultID: UUID, changes: [AIContentChange]) { baseline = changes }
}
private struct LifecyclePolicy: AIProcessingPolicyResolver {
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority { .blocked(.consent) }
    func validateExecution(lease: VaultSessionLease) throws { throw AIWorkFailure.consent }
}
private struct LifecycleSnapshot: AIWorkSnapshot {
    let revision: String
    let inputFingerprint: String
}
private struct LifecycleProcessor: AIWorkProcessor {
    var version = "1"
    var descriptor: AIProcessorDescriptor { .init(identifier: "test", version: version, targets: [.page], dependencies: [.body], provider: .cloud) }
    func prepare(_ item: AIWorkItem, lease: VaultSessionLease) async throws -> any AIWorkSnapshot {
        LifecycleSnapshot(revision: item.revision, inputFingerprint: item.revision)
    }
    func execute(_ snapshot: any AIWorkSnapshot, context: AIProcessingExecutionContext) async throws -> AIWorkOutcome {
        try context.validate()
        return .completed
    }
    func isCurrent(_ item: AIWorkItem, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async throws -> Bool { true }
}

@Suite struct AIProcessingCoordinatorTests {
    // A frozen clock prevents dispatch without wall-clock sleeps or external calls.
    private let clock = AIProcessingClock(now: { Date(timeIntervalSince1970: 100) }, sleep: { _ in throw CancellationError() })

    @Test func testBaselineCoalescingAndIdempotency() async throws {
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-ai-fixture"), generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let ledger = LifecycleMemoryLedger()
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: LifecyclePolicy(), clock: clock)
        await coordinator.register(LifecycleProcessor())
        let id = UUID()
        func change(_ revision: String) -> AIContentChange { .init(vaultID: session.vaultID, entityKind: .page, entityID: id, revision: revision) }
        try await coordinator.bind(lease: session.lease, inventory: [change("baseline")])
        let initial = await coordinator.workItems()
        #expect(initial.isEmpty)
        try await coordinator.receive(change("first"))
        try await coordinator.receive(change("latest"))
        let pending = await coordinator.workItems()
        #expect(pending.count == 1)
        #expect(pending.first?.revision == "latest")
        try await coordinator.receive(change("latest"))
        let repeated = await coordinator.workItems()
        #expect(repeated.first?.id == pending.first?.id)
        try await coordinator.suspend()
    }

    @Test func testVersionChangeResetsOnlyKnownWork() async throws {
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-ai-version"), generation: 1)
        let ledger = LifecycleMemoryLedger()
        let id = UUID()
        let change = AIContentChange(vaultID: session.vaultID, entityKind: .page, entityID: id, revision: "current")
        let key = AIWorkKey(vaultID: session.vaultID, entityKind: .page, entityID: id, processorID: "test")
        try await ledger.save(AIWorkItem(key: key, revision: "old", processorVersion: "1", state: .completed, attemptCount: 4, eligibleAt: clock.now(), inputFingerprint: "old"))
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: VaultAccessGate(initialState: .open(session)), policy: LifecyclePolicy(), clock: clock)
        await coordinator.register(LifecycleProcessor(version: "2"))
        try await coordinator.bind(lease: session.lease, inventory: [change])
        let work = await coordinator.workItems()
        #expect(work.count == 1)
        #expect(work.first?.processorVersion == "2")
        #expect(work.first?.revision == "current")
        #expect(work.first?.attemptCount == 0)
        #expect(work.first?.inputFingerprint == nil)
        try await coordinator.suspend()
    }

    @Test func testMetadataAndAIPublicationDoNotTriggerBodyProcessor() {
        let processor = LifecycleProcessor()
        let vault = UUID(), id = UUID()
        #expect(!(processor.isEligible(.init(vaultID: vault, entityKind: .page, entityID: id, revision: "1", dimensions: [.metadata]))))
        #expect(!(processor.isEligible(.init(vaultID: vault, entityKind: .page, entityID: id, revision: "2", origin: .aiPublication))))
        #expect(processor.isEligible(.init(vaultID: vault, entityKind: .page, entityID: id, revision: "3")))
    }
    @Test func testUnrelatedMetadataCommitPreservesPendingBodyWork() async throws {
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-ai-metadata"), generation: 1)
        let coordinator = AIProcessingCoordinator(ledger: LifecycleMemoryLedger(),
            gate: VaultAccessGate(initialState: .open(session)), policy: LifecyclePolicy(), clock: clock)
        await coordinator.register(LifecycleProcessor())
        try await coordinator.bind(lease: session.lease, inventory: [])
        let id = UUID()
        try await coordinator.receive(.init(vaultID: session.vaultID, entityKind: .page, entityID: id, revision: "body"))
        try await coordinator.receive(.init(vaultID: session.vaultID, entityKind: .page, entityID: id,
            revision: "metadata", dimensions: [.metadata]))
        let work = await coordinator.workItems()
        #expect(work.count == 1)
        #expect(work.first?.revision == "metadata")
        #expect(work.first?.state == .pending)
        try await coordinator.suspend()
    }

    @Test func testRestorationReevaluatesBodyProcessor() {
        #expect(LifecycleProcessor().isEligible(.init(vaultID: UUID(), entityKind: .page,
            entityID: UUID(), revision: "restored", kind: .restored, dimensions: [.lifecycle])))
    }

}

extension AIProcessingCoordinatorTests {
    @Test func pausedIncrementalJobIdentitySurvivesReopenWithoutDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let session = VaultSession(vaultID: UUID(), root: directory, generation: 1)
        let processor = LifecycleProcessor()
        let change = AIContentChange(vaultID: session.vaultID, entityKind: .page, entityID: UUID(), revision: "current")
        let item = AIWorkItem(key: .init(vaultID: session.vaultID, entityKind: .page, entityID: change.entityID,
            processorID: processor.descriptor.identifier), revision: change.revision,
            processorVersion: processor.descriptor.version, state: .suspended, eligibleAt: clock.now())
        try await ledger.save(item)
        try await ledger.setProcessorPaused(vaultID: session.vaultID, processorID: processor.descriptor.identifier, paused: true)
        try await ledger.saveCheckpoint(vaultID: session.vaultID, changes: [change])
        let reopened = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let coordinator = AIProcessingCoordinator(ledger: reopened, gate: VaultAccessGate(initialState: .open(session)),
            policy: LifecyclePolicy(), clock: clock)
        await coordinator.register(processor)
        try await coordinator.bind(lease: session.lease, inventory: [change])
        #expect(await coordinator.workItems().first?.id == item.id)
        #expect(await coordinator.status().pendingCount == 0)
        #expect(await coordinator.status().runningCount == 0)
        #expect(try await reopened.pausedProcessors(vaultID: session.vaultID).contains(processor.descriptor.identifier))
        try await coordinator.resumeProcessor(processor.descriptor.identifier)
        #expect(await coordinator.workItems().first?.id == item.id)
        #expect(try await reopened.pausedProcessors(vaultID: session.vaultID).isEmpty)
        try await coordinator.suspend()
    }
}

/// Holds actor suspension points explicitly, without scheduler timing or provider calls.
private actor CoordinatorReviewBarrier {
    private var arrivals = 0
    private var isOpen = false
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func enter() async {
        arrivals += 1
        let ready = observers.filter { arrivals >= $0.0 }
        observers.removeAll { arrivals >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        if isOpen { return }
        await withCheckedContinuation { releases.append($0) }
    }
    func waitForArrivals(_ count: Int) async {
        if arrivals < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }
    func count() -> Int { arrivals }
    func releaseAll() {
        isOpen = true
        let pending = releases; releases = []
        for continuation in pending { continuation.resume() }
    }
}
private actor CoordinatorReviewLedger: AIWorkLedger {
    let saveBarrier: CoordinatorReviewBarrier?
    let pauseBarrier: CoordinatorReviewBarrier?
    private var rows: [AIWorkKey: AIWorkItem] = [:]
    private var pauses: [UUID: Set<String>] = [:]
    init(saveBarrier: CoordinatorReviewBarrier? = nil, pauseBarrier: CoordinatorReviewBarrier? = nil) {
        self.saveBarrier = saveBarrier; self.pauseBarrier = pauseBarrier
    }
    func existingWorkItem(key: AIWorkKey) async -> AIWorkItem? { rows[key] }
    func load(vaultID: UUID) -> [AIWorkItem] { rows.values.filter { $0.key.vaultID == vaultID } }
    func save(_ item: AIWorkItem) async {
        rows[item.key] = item
        if let saveBarrier { await saveBarrier.enter() }
    }
    func pausedProcessors(vaultID: UUID) async -> Set<String> { pauses[vaultID] ?? [] }
    func setProcessorPaused(vaultID: UUID, processorID: String, paused: Bool) async {
        if paused { pauses[vaultID, default: []].insert(processorID) }
        else { pauses[vaultID, default: []].remove(processorID) }
        if let pauseBarrier { await pauseBarrier.enter() }
    }
    func checkpoint(vaultID: UUID) -> [AIContentChange]? { nil }
    func saveCheckpoint(vaultID: UUID, changes: [AIContentChange]) {}
}
private struct CoordinatorReviewHistoricalProcessor: AIWorkProcessor {
    let batchID: UUID
    var descriptor: AIProcessorDescriptor {
        .init(identifier: EmbeddingWorkProcessor.identifier + ".history." + batchID.uuidString,
              version: "review", targets: [.page], dependencies: [.body], provider: .cloud,
              recoverOnVersionChange: false, observesCommittedChanges: false)
    }
    func prepare(_ item: AIWorkItem, lease: VaultSessionLease) async throws -> any AIWorkSnapshot {
        LifecycleSnapshot(revision: item.revision, inputFingerprint: item.revision)
    }
    func execute(_ snapshot: any AIWorkSnapshot, context: AIProcessingExecutionContext) async throws -> AIWorkOutcome { .completed }
    func isCurrent(_ item: AIWorkItem, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async throws -> Bool { true }
}

extension AIProcessingCoordinatorTests {
    @Test(.timeLimit(.minutes(1))) func concurrentHistoricalReplayArmsOneTimer() async throws {
        let saves = CoordinatorReviewBarrier(), timers = CoordinatorReviewBarrier()
        let ledger = CoordinatorReviewLedger(saveBarrier: saves)
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-review-admission"), generation: 1)
        let processor = CoordinatorReviewHistoricalProcessor(batchID: UUID())
        let change = AIContentChange(vaultID: session.vaultID, entityKind: .page, entityID: UUID(), revision: "captured")
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: VaultAccessGate(initialState: .open(session)),
            policy: LifecyclePolicy(), clock: .init(now: { Date(timeIntervalSince1970: 100) }, sleep: { _ in
                await timers.enter(); throw CancellationError()
            }))
        await coordinator.register(processor)
        try await coordinator.bind(lease: session.lease, inventory: [change])
        let candidate = AIWorkItem(key: .init(vaultID: session.vaultID, entityKind: .page, entityID: change.entityID,
            processorID: processor.descriptor.identifier), revision: change.revision, processorVersion: "review",
            eligibleAt: Date(timeIntervalSince1970: 100), batchID: processor.batchID)
        let first = Task { try await coordinator.admitHistorical(candidate) }
        await saves.waitForArrivals(1)
        let second = Task { try await coordinator.admitHistorical(candidate) }
        await saves.waitForArrivals(2)
        await saves.releaseAll()
        try await first.value; try await second.value
        await timers.waitForArrivals(1)
        #expect(await coordinator.workItems().first?.attemptCount == 0)
        // Stop waits for the installed timer's acknowledgment. Opening the clock
        // barrier lets it finish without provider inference or wall-clock sleeps.
        let stopping = Task { try await coordinator.pauseHistorical(batchID: processor.batchID) }
        await timers.releaseAll()
        try await stopping.value
        #expect(await timers.count() == 1)
        try await coordinator.suspend()
    }

    @Test(.timeLimit(.minutes(1))) func stalePauseCannotSuspendReplacementBinding() async throws {
        let pause = CoordinatorReviewBarrier()
        let ledger = CoordinatorReviewLedger(pauseBarrier: pause)
        let first = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-review-pause-first"), generation: 1)
        let second = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-review-pause-second"), generation: 2)
        let gate = VaultAccessGate(initialState: .open(first))
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: LifecyclePolicy(), clock: clock)
        await coordinator.register(LifecycleProcessor())
        try await coordinator.bind(lease: first.lease, inventory: [])
        let pausing = Task { try await coordinator.pauseProcessor("test") }
        await pause.waitForArrivals(1)
        gate.updateState(.open(second))
        try await coordinator.bind(lease: second.lease, inventory: [])
        try await coordinator.receive(.init(vaultID: second.vaultID, entityKind: .page, entityID: UUID(), revision: "new"))
        await pause.releaseAll()
        do { try await pausing.value; Issue.record("Retired pause unexpectedly succeeded") }
        catch is CancellationError {}
        catch { Issue.record("Unexpected pause error: \(error)") }
        #expect(await coordinator.workItems().first?.state == .pending)
        #expect(await ledger.pausedProcessors(vaultID: first.vaultID).contains("test"))
        #expect(await ledger.pausedProcessors(vaultID: second.vaultID).isEmpty)
        try await coordinator.suspend()
    }
}
