import Foundation
import Synchronization
import Testing
@testable import VaultCore

/// Only the test releases timers. Virtual time never advances with wall-clock time.
private final class ProcessingTestClock: Sendable {
    struct Sleep: Sendable {
        let id: UUID
        let delay: TimeInterval
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State: Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        var sleeps: [Sleep] = []
        var stopped = false
    }
    private let state = Mutex(State())
    var clock: AIProcessingClock {
        AIProcessingClock(now: { self.state.withLock { $0.now } }, sleep: { delay in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let cancelled = self.state.withLock { state in
                        if state.stopped || Task.isCancelled { return true }
                        state.sleeps.append(Sleep(id: id, delay: delay,
                            deadline: state.now.addingTimeInterval(delay), continuation: continuation))
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let sleep = self.state.withLock { state -> Sleep? in
                    guard let index = state.sleeps.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.sleeps.remove(at: index)
                }
                sleep?.continuation.resume(throwing: CancellationError())
            }
        })
    }
    func waitForTimers(delay: TimeInterval, count: Int) async throws {
        while true {
            try Task.checkCancellation()
            let (pending, stopped) = state.withLock {
                ($0.sleeps.filter { $0.delay == delay }.count, $0.stopped)
            }
            if stopped { throw CancellationError() }
            if pending >= count { return }
            await Task.yield()
        }
    }
    func releaseNext(expectedDelay: TimeInterval) async throws {
        while true {
            try Task.checkCancellation()
            // Selection and removal are atomic with cancellation; a cancelled timer
            // can disappear while the driver is awaiting its registration.
            let sleep = state.withLock { state -> Sleep? in
                guard let index = state.sleeps.firstIndex(where: { $0.delay == expectedDelay }) else { return nil }
                let sleep = state.sleeps.remove(at: index)
                state.now = max(state.now, sleep.deadline)
                return sleep
            }
            if let sleep {
                #expect(sleep.delay == expectedDelay)
                sleep.continuation.resume()
                return
            }
            if state.withLock({ $0.stopped }) { throw CancellationError() }
            await Task.yield()
        }
    }
    func stop() {
        let sleeps = state.withLock { state in
            state.stopped = true
            let sleeps = state.sleeps; state.sleeps.removeAll(); return sleeps
        }
        for sleep in sleeps { sleep.continuation.resume(throwing: CancellationError()) }
    }
}

/// Yielding observes explicit barriers; the suite's time limit is only a hang watchdog.
private func processingWait(_ predicate: () async -> Bool) async throws {
    while !(await predicate()) {
        try Task.checkCancellation()
        await Task.yield()
    }
}

private actor ProcessingExecutionLedger: AIWorkLedger {
    private var rows: [AIWorkKey: AIWorkItem] = [:]
    private var checkpoints: [UUID: [AIContentChange]] = [:]
    func load(vaultID: UUID) -> [AIWorkItem] { rows.values.filter { $0.key.vaultID == vaultID } }
    func save(_ item: AIWorkItem) { rows[item.key] = item }
    func checkpoint(vaultID: UUID) -> [AIContentChange]? { checkpoints[vaultID] }
    func saveCheckpoint(vaultID: UUID, changes: [AIContentChange]) { checkpoints[vaultID] = changes }
}

private final class ProcessingExecutionPolicy: AIProcessingPolicyResolver, Sendable {
    private let permitted = Mutex(true)
    func setAllowed(_ allowed: Bool) { permitted.withLock { $0 = allowed } }
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority {
        permitted.withLock { $0 } ? .allowed : .blocked(.consent)
    }
    func validateExecution(lease: VaultSessionLease) throws {
        guard permitted.withLock({ $0 }) else { throw AIWorkFailure.authority }
    }
}

private struct ProcessingExecutionSnapshot: AIWorkSnapshot {
    let revision: String
    var inputFingerprint: String { "input-" + revision }
}

private actor ProcessingExecutionProcessor: AIWorkProcessor {
    enum Step: Sendable { case result(AIWorkOutcome), failure(AIWorkFailure) }
    nonisolated let descriptor: AIProcessorDescriptor
    private let steps: [Step]
    private let holdExecution: Bool
    private let validateInsideProcessor: Bool
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var retired = false
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentRevision: String? = "1"
    private var prepareFailure: AIWorkFailure?
    private(set) var preparations = 0
    private(set) var executions = 0
    private(set) var finished = 0
    init(provider: AIProcessingProvider = .cloud, steps: [Step] = [.result(.completed)],
         holdExecution: Bool = false, validateInsideProcessor: Bool = true) {
        descriptor = .init(identifier: "execution-" + provider.rawValue, version: "1", targets: [.page], dependencies: [.body], provider: provider)
        precondition(!steps.isEmpty)
        self.steps = steps; self.holdExecution = holdExecution
        self.validateInsideProcessor = validateInsideProcessor
    }
    func setCurrentRevision(_ revision: String?) { currentRevision = revision }
    func failPreparation(_ failure: AIWorkFailure) { prepareFailure = failure }
    func prepare(_ item: AIWorkItem, lease: VaultSessionLease) async throws -> any AIWorkSnapshot {
        preparations += 1
        if let prepareFailure { throw prepareFailure }
        return ProcessingExecutionSnapshot(revision: item.revision)
    }
    func execute(_ snapshot: any AIWorkSnapshot, context: AIProcessingExecutionContext) async throws -> AIWorkOutcome {
        executions += 1
        let number = executions
        defer {
            finished += 1
            if finished == executions {
                let waiters = retirementWaiters
                retirementWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        // Intentionally lacks a cancellation handler: late completions must still be rejected.
        if holdExecution && !retired { await withCheckedContinuation { continuations[number] = $0 } }
        if validateInsideProcessor { try context.validate() }
        switch steps[min(number - 1, steps.count - 1)] {
        case .result(let result): return result
        case .failure(let failure): throw failure
        }
    }
    func isCurrent(_ item: AIWorkItem, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async throws -> Bool {
        currentRevision == snapshot.revision
    }
    func release(_ number: Int) { continuations.removeValue(forKey: number)?.resume() }
    func releaseAll() async {
        retired = true
        let waiting = Array(continuations.values)
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
        // Await the resumed invocations rather than leaving cleanup work behind
        // when the test body throws or its watchdog cancels it.
        if finished != executions {
            await withCheckedContinuation { retirementWaiters.append($0) }
        }
    }
}

private struct ProcessingExecutionFixture: Sendable {
    let session: VaultSession
    let gate: VaultAccessGate
    let clock: ProcessingTestClock
    let ledger: ProcessingExecutionLedger
    let policy: ProcessingExecutionPolicy
    let coordinator: AIProcessingCoordinator
    let targetID = UUID()
    private static func make(processor: ProcessingExecutionProcessor,
                     configuration: AIProcessingConfiguration = .init()) async throws -> Self {
        let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-processing-execution"), generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let clock = ProcessingTestClock(), ledger = ProcessingExecutionLedger(), policy = ProcessingExecutionPolicy()
        let coordinator = AIProcessingCoordinator(ledger: ledger, gate: gate, policy: policy, clock: clock.clock, configuration: configuration)
        await coordinator.register(processor)
        try await coordinator.bind(lease: session.lease, inventory: [])
        return Self(session: session, gate: gate, clock: clock, ledger: ledger, policy: policy, coordinator: coordinator)
    }
    static func withFixture(processor: ProcessingExecutionProcessor,
                            configuration: AIProcessingConfiguration = .init(),
                            additionalProcessors: [ProcessingExecutionProcessor] = [],
                            operation: (Self) async throws -> Void) async throws {
        let fixture = try await make(processor: processor, configuration: configuration)
        for additional in additionalProcessors { await fixture.coordinator.register(additional) }
        let processors = [processor] + additionalProcessors
        do {
            try await operation(fixture)
        } catch {
            await fixture.cleanUp(processors: processors)
            throw error
        }
        await fixture.cleanUp(processors: processors)
    }
    private func cleanUp(processors: [ProcessingExecutionProcessor]) async {
        // Revoke admission before any await. The stopped clock rejects timers
        // registered by an already-resuming coordinator task during teardown.
        gate.updateState(.closed)
        clock.stop()
        try? await coordinator.suspend()
        for processor in processors { await processor.releaseAll() }
    }
    func change(_ revision: String = "1", kind: AIChangeKind = .reprocess) -> AIContentChange {
        .init(vaultID: session.vaultID, entityKind: .page, entityID: targetID, revision: revision, kind: kind,
            dimensions: kind == .removed ? [.lifecycle] : [.body])
    }
    func waitFor(_ state: AIWorkState, attempt: Int? = nil) async throws -> AIWorkItem {
        while true {
            try Task.checkCancellation()
            if let item = await coordinator.workItems().first(where: {
                $0.state == state && (attempt == nil || $0.attemptCount == attempt)
            }) { return item }
            await Task.yield()
        }
    }
    func start() async throws {
        try await coordinator.receive(change())
        try await clock.releaseNext(expectedDelay: 0)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AIProcessingExecutionTests {
    @Test func transientOutcomesBackOffAndStopAtAttemptLimit() async throws {
        let processor = ProcessingExecutionProcessor(steps: [.result(.retryable(.transient))])
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            for (attempt, delay) in [(1, 30.0), (2, 60.0), (3, 120.0)] {
                let retry = try await fixture.waitFor(.retryable, attempt: attempt)
                #expect(retry.inputFingerprint == nil)
                #expect(retry.eligibleAt.timeIntervalSince(retry.updatedAt) == delay)
                #expect(await processor.executions == attempt)
                try await fixture.clock.releaseNext(expectedDelay: delay)
            }
            let failed = try await fixture.waitFor(.failed, attempt: 4)
            #expect(failed.failure == .attemptsExhausted)
            #expect(await processor.executions == 4)
            #expect(await fixture.coordinator.status().failedCount == 1)
        }
    }

    @Test func thrownTransientFailureRetriesThenRecordsSuccess() async throws {
        let processor = ProcessingExecutionProcessor(steps: [.failure(.transient), .result(.completed)])
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            _ = try await fixture.waitFor(.retryable, attempt: 1)
            try await fixture.clock.releaseNext(expectedDelay: 30)
            let completed = try await fixture.waitFor(.completed, attempt: 2)
            #expect(completed.inputFingerprint == "input-1")
            try await processingWait { await fixture.coordinator.status().completedCount == 1 }
            #expect(await processor.executions == 2)
        }
    }

    @Test func exponentialBackoffClampsToConfiguredMaximum() async throws {
        var configuration = AIProcessingConfiguration()
        configuration.initialRetryDelay = 600; configuration.maximumRetryDelay = 900
        let processor = ProcessingExecutionProcessor(steps: [.result(.retryable(.transient))])
        try await ProcessingExecutionFixture.withFixture(processor: processor, configuration: configuration) { fixture in
            try await fixture.start()
            for (attempt, delay) in [(1, 600.0), (2, 900.0), (3, 900.0)] {
                _ = try await fixture.waitFor(.retryable, attempt: attempt)
                try await fixture.clock.releaseNext(expectedDelay: delay)
            }
            _ = try await fixture.waitFor(.failed, attempt: 4)
            #expect(await processor.executions == 4)
        }
    }

    @Test(arguments: [AIWorkFailure.consent, .authority, .unsupported, .corruptContent, .validation])
    func nonTransientThrownFailuresNeverRetry(_ failure: AIWorkFailure) async throws {
        let processor = ProcessingExecutionProcessor(steps: [.failure(failure)])
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            let failed = try await fixture.waitFor(.failed, attempt: 1)
            #expect(failed.failure == failure)
            #expect(await processor.executions == 1)
            #expect(await fixture.coordinator.status().pendingCount == 0)
        }
    }

    @Test func nonTransientRetryDispositionBlocksWithoutRetrying() async throws {
        let processor = ProcessingExecutionProcessor(steps: [.result(.retryable(.consent))])
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            let blocked = try await fixture.waitFor(.blocked, attempt: 1)
            #expect(blocked.failure == .consent)
            #expect(await processor.executions == 1)
        }
    }

    @Test func transientSnapshotPreparationFailureAlsoHasBoundedAttempts() async throws {
        let processor = ProcessingExecutionProcessor()
        await processor.failPreparation(.transient)
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            for (attempt, delay) in [(1, 30.0), (2, 60.0), (3, 120.0)] {
                _ = try await fixture.waitFor(.retryable, attempt: attempt)
                try await fixture.clock.releaseNext(expectedDelay: delay)
            }
            _ = try await fixture.waitFor(.failed, attempt: 4)
            #expect(await processor.preparations == 4)
            #expect(await processor.executions == 0)
        }
    }

    @Test func revokedAuthorityBlocksQueuedRetryUntilExplicitAuthorityChange() async throws {
        let processor = ProcessingExecutionProcessor(steps: [.result(.retryable(.transient)), .result(.completed)])
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            _ = try await fixture.waitFor(.retryable, attempt: 1)
            fixture.policy.setAllowed(false)
            try await fixture.clock.releaseNext(expectedDelay: 30)
            _ = try await fixture.waitFor(.blocked, attempt: 2)
            #expect(await processor.executions == 1)
            fixture.policy.setAllowed(true)
            #expect(await fixture.coordinator.workItems().first?.state == .blocked)
            try await fixture.coordinator.authorityChanged()
            try await fixture.clock.releaseNext(expectedDelay: 0)
            _ = try await fixture.waitFor(.completed, attempt: 3)
            #expect(await processor.executions == 2)
        }
    }

    @Test func lockRejectsLateCompletionIgnoringCancellation() async throws {
        let processor = ProcessingExecutionProcessor(holdExecution: true, validateInsideProcessor: false)
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            try await processingWait { await processor.executions == 1 }
            fixture.gate.updateState(.locking(fixture.session))
            await processor.release(1)
            _ = try await fixture.waitFor(.suspended)
            #expect(await fixture.coordinator.status().completedCount == 0)
            #expect(await fixture.coordinator.status().lastSuccessfulAt == nil)
        }
    }

    @Test func changedAuthoritativeRevisionRejectsCompletionWithoutNotification() async throws {
        let processor = ProcessingExecutionProcessor(holdExecution: true, validateInsideProcessor: false)
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            try await processingWait { await processor.executions == 1 }
            await processor.setCurrentRevision("2")
            await processor.release(1)
            _ = try await fixture.waitFor(.superseded)
            #expect(await fixture.coordinator.status().completedCount == 0)
        }
    }

    @Test func saveDuringExecutionRejectsOldResultAndRunsLatestRevision() async throws {
        let processor = ProcessingExecutionProcessor(holdExecution: true, validateInsideProcessor: false)
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            try await processingWait { await processor.executions == 1 }
            await processor.setCurrentRevision("2")
            try await fixture.coordinator.receive(fixture.change("2", kind: .updated))
            await processor.release(1)
            try await processingWait { await fixture.coordinator.status().runningCount == 0 }
            #expect(await fixture.coordinator.status().completedCount == 0)
            try await fixture.clock.releaseNext(expectedDelay: 15)
            try await processingWait { await processor.executions == 2 }
            await processor.release(2)
            let completed = try await fixture.waitFor(.completed)
            #expect(completed.revision == "2")
            #expect(completed.inputFingerprint == "input-2")
        }
    }

    @Test func deletionDuringExecutionNeverAcceptsLateResult() async throws {
        let processor = ProcessingExecutionProcessor(holdExecution: true, validateInsideProcessor: false)
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            try await processingWait { await processor.executions == 1 }
            await processor.setCurrentRevision(nil)
            try await fixture.coordinator.receive(fixture.change(kind: .removed))
            await processor.release(1)
            try await processingWait { await fixture.coordinator.status().runningCount == 0 }
            #expect(await fixture.coordinator.workItems().first?.state == .superseded)
            #expect(await fixture.coordinator.status().completedCount == 0)
            #expect(await processor.executions == 1)
        }
    }

    @Test func vaultSwitchIsolatesLateCompletionFromNewSession() async throws {
        let processor = ProcessingExecutionProcessor(holdExecution: true, validateInsideProcessor: false)
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            try await processingWait { await processor.executions == 1 }
            let next = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/noema-processing-next"), generation: 2)
            fixture.gate.updateState(.open(next))
            try await fixture.coordinator.bind(lease: next.lease, inventory: [])
            await processor.release(1)
            try await processingWait { await processor.finished == 1 }
            try await processingWait { await fixture.coordinator.status().runningCount == 0 }
            #expect(await fixture.coordinator.workItems().isEmpty)
            #expect(await fixture.coordinator.status().completedCount == 0)
            #expect(await fixture.coordinator.status().lastSuccessfulAt == nil)
        }
    }
}

extension AIProcessingExecutionTests {
    @Test func missingGrantNeverDispatchesAnExecution() async throws {
        let processor = ProcessingExecutionProcessor()
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            fixture.policy.setAllowed(false)
            try await fixture.start()
            let blocked = try await fixture.waitFor(.blocked, attempt: 1)
            #expect(blocked.failure == .consent)
            #expect(await processor.executions == 0)
            #expect(await fixture.coordinator.status().completedCount == 0)
        }
    }

    @Test func revokedPolicyRejectsAlreadyRunningCompletion() async throws {
        let processor = ProcessingExecutionProcessor(holdExecution: true, validateInsideProcessor: false)
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            try await fixture.start()
            try await processingWait { await processor.executions == 1 }
            fixture.policy.setAllowed(false)
            await processor.release(1)
            let failed = try await fixture.waitFor(.failed)
            #expect(failed.failure == .authority)
            #expect(await fixture.coordinator.status().completedCount == 0)
            #expect(await fixture.coordinator.status().lastSuccessfulAt == nil)
        }
    }

    @Test func recoveredExhaustedWorkDoesNotPrepareOrExecuteAgain() async throws {
        let processor = ProcessingExecutionProcessor()
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            let key = AIWorkKey(vaultID: fixture.session.vaultID, entityKind: .page,
                entityID: fixture.targetID, processorID: processor.descriptor.identifier)
            let item = AIWorkItem(key: key, revision: "1", processorVersion: "1", state: .running,
                attemptCount: 4, eligibleAt: fixture.clock.clock.now())
            await fixture.ledger.save(item)
            let inventory = [fixture.change(kind: .updated)]
            await fixture.ledger.saveCheckpoint(vaultID: fixture.session.vaultID, changes: inventory)
            try await fixture.coordinator.bind(lease: fixture.session.lease, inventory: inventory)
            try await fixture.clock.releaseNext(expectedDelay: 30)
            let failed = try await fixture.waitFor(.failed, attempt: 4)
            #expect(failed.failure == .attemptsExhausted)
            #expect(await processor.preparations == 0)
            #expect(await processor.executions == 0)
        }
    }

    @Test func restartRetainsAttemptBudgetAndReauthorizesRetry() async throws {
        let processor = ProcessingExecutionProcessor()
        try await ProcessingExecutionFixture.withFixture(processor: processor) { fixture in
            let key = AIWorkKey(vaultID: fixture.session.vaultID, entityKind: .page,
                entityID: fixture.targetID, processorID: processor.descriptor.identifier)
            await fixture.ledger.save(.init(key: key, revision: "1", processorVersion: "1", state: .retryable,
                attemptCount: 2, eligibleAt: fixture.clock.clock.now().addingTimeInterval(60), failure: .transient))
            fixture.policy.setAllowed(false)
            let inventory = [fixture.change(kind: .updated)]
            await fixture.ledger.saveCheckpoint(vaultID: fixture.session.vaultID, changes: inventory)
            try await fixture.coordinator.bind(lease: fixture.session.lease, inventory: inventory)
            try await fixture.clock.releaseNext(expectedDelay: 60)
            let blocked = try await fixture.waitFor(.blocked, attempt: 3)
            #expect(blocked.failure == .consent)
            #expect(await processor.executions == 0)
        }
    }

    @Test func cloudAndOnDeviceCanRunTogetherButSameProviderIsSerialized() async throws {
        let cloud = ProcessingExecutionProcessor(holdExecution: true)
        let local = ProcessingExecutionProcessor(provider: .onDevice, holdExecution: true)
        try await ProcessingExecutionFixture.withFixture(processor: cloud, additionalProcessors: [local]) { fixture in
            try await fixture.coordinator.receive(fixture.change())
            // Processor registration order is deliberately irrelevant: both independent slots admit.
            try await fixture.clock.releaseNext(expectedDelay: 0)
            try await fixture.clock.releaseNext(expectedDelay: 0)
            try await processingWait {
                let cloudCount = await cloud.executions
                let localCount = await local.executions
                return cloudCount == 1 && localCount == 1
            }
            #expect(await fixture.coordinator.status().runningCount == 2)

            let other = AIContentChange(vaultID: fixture.session.vaultID, entityKind: .page,
                entityID: UUID(), revision: "1", kind: .reprocess)
            try await fixture.coordinator.receive(other)
            try await fixture.clock.releaseNext(expectedDelay: 0)
            try await fixture.clock.releaseNext(expectedDelay: 0)
            #expect(await cloud.executions == 1)
            #expect(await local.executions == 1)
            // Both contenders must have observed occupied slots before either running
            // processor is released. Otherwise a contender could skip its capacity timer.
            try await fixture.clock.waitForTimers(delay: 1, count: 2)
            #expect(await fixture.coordinator.status().runningCount == 2)
            await cloud.release(1); await local.release(1)
            try await processingWait { await fixture.coordinator.status().runningCount == 0 }
            try await fixture.clock.releaseNext(expectedDelay: 1)
            try await fixture.clock.releaseNext(expectedDelay: 1)
            try await processingWait {
                let cloudCount = await cloud.executions
                let localCount = await local.executions
                return cloudCount == 2 && localCount == 2
            }
            #expect(await fixture.coordinator.status().runningCount == 2)
            await cloud.release(2); await local.release(2)
            try await processingWait { await fixture.coordinator.status().completedCount == 4 }
        }
    }
}
