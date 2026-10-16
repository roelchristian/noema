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
