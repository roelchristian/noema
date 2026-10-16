import Foundation

/// Disposable scheduling metadata, scoped to one admitted session. No production processors
/// are registered by default. Processors retain responsibility for conditional publication.
public actor AIProcessingCoordinator {
    private struct Target: Hashable { let kind: AIEntityKind; let id: UUID }
    private let ledger: any AIWorkLedger
    private let gate: VaultAccessGate
    private let policy: any AIProcessingPolicyResolver
    private let clock: AIProcessingClock
    private let configuration: AIProcessingConfiguration
    private var lifecycleID = UUID()
    private var activeAdmissions = 0
    private var lease: VaultSessionLease?
    private var processors: [String: any AIWorkProcessor] = [:]
    private var items: [AIWorkKey: AIWorkItem] = [:]
    private var inventory: [Target: AIContentChange] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var taskVersions: [UUID: UUID] = [:]
    private var invalidators: [UUID: UUID] = [:]
    private var busy: [AIWorkKey: UUID] = [:]
    private var providerUse: [AIProcessingProvider: Int] = [:]
    private var reason: AIWorkFailure?
    private var pausedProcessors: Set<String> = []
    private var completedCount = 0
    private var failedCount = 0
    private var lastSuccessfulAt: Date?
    private var workChangeHandler: (@Sendable (AIWorkItem) async -> Void)?

    /// Best-effort notification after durable writes. Consumers reread persisted state;
    /// this observer does not schedule inference or grant execution authority.
    public func setWorkChangeHandler(_ handler: (@Sendable (AIWorkItem) async -> Void)?) {
        workChangeHandler = handler
    }

    public init(ledger: any AIWorkLedger, gate: VaultAccessGate,
                policy: any AIProcessingPolicyResolver, clock: AIProcessingClock = .continuous,
                configuration: AIProcessingConfiguration = .init()) {
        self.ledger = ledger; self.gate = gate; self.policy = policy
        self.clock = clock; self.configuration = configuration
    }

    public func register(_ processor: any AIWorkProcessor) {
        processors[processor.descriptor.identifier] = processor
    }

    public func bind(lease next: VaultSessionLease, inventory current: [AIContentChange]) async throws {
        let bindingID = UUID()
        try await retire(reason: .authority, identity: bindingID)
        guard lifecycleID == bindingID else { throw CancellationError() }
        try validate(next)
        lease = next; reason = nil; completedCount = 0; failedCount = 0; lastSuccessfulAt = nil
        items = [:]; inventory = [:]
        pausedProcessors = try await ledger.pausedProcessors(vaultID: next.vaultID)
        try validateActive(next, identity: bindingID)
        let recovered = try await ledger.load(vaultID: next.vaultID)
        try validateActive(next, identity: bindingID)
        let previous = try await ledger.checkpoint(vaultID: next.vaultID)
        try validateActive(next, identity: bindingID)
        let actual = current.filter { $0.vaultID == next.vaultID }
        inventory = Dictionary(actual.map { (Target(kind: $0.entityKind, id: $0.entityID), $0) }, uniquingKeysWith: { _, last in last })
        for var item in recovered {
            guard let change = inventory[Target(kind: item.key.entityKind, id: item.key.entityID)],
                  change.kind != .removed,
                  let processor = processors[item.key.processorID] else { continue }
            if processor.descriptor.version != item.processorVersion {
                // Version selection is not renewed permission to submit recorded historical work.
                guard processor.descriptor.recoverOnVersionChange else { continue }
                // Only ledger-known targets are invalidated; never enrich a historical baseline.
                item = AIWorkItem(key: item.key, revision: change.revision,
                    processorVersion: processor.descriptor.version,
                    eligibleAt: clock.now().addingTimeInterval(configuration.recoveryDelay),
                    updatedAt: clock.now())
            } else if change.revision != item.revision { continue }
            // Historical work needs explicit batch admission after current control intent
            // and fresh authority have been resolved. Bind never replays it by itself.
            if item.batchID != nil { items[item.key] = item; continue }
            if [.running, .scheduled, .pending, .retryable, .suspended].contains(item.state) {
                if !pausedProcessors.contains(item.key.processorID) { item.id = UUID() }
                item.state = .pending
                item.eligibleAt = max(item.eligibleAt, clock.now().addingTimeInterval(configuration.recoveryDelay))
                items[item.key] = item
                try await persist(item); try validateActive(next, identity: bindingID)
                arm(item, lease: next)
            } else { items[item.key] = item }
        }
        // The first inventory is a baseline, not an instruction to enrich historical content.
        if let previous {
            let before = Dictionary(previous.map { (Target(kind: $0.entityKind, id: $0.entityID), $0.revision) }, uniquingKeysWith: { _, last in last })
            for change in actual where before[Target(kind: change.entityKind, id: change.entityID)] != change.revision {
                try await receive(change)
                try validateActive(next, identity: bindingID)
            }
            for old in previous where inventory[Target(kind: old.entityKind, id: old.entityID)] == nil {
                try await receive(AIContentChange(vaultID: old.vaultID, entityKind: old.entityKind,
                    entityID: old.entityID, revision: old.revision, kind: .removed,
                    origin: .externalReconciliation, dimensions: [.lifecycle]))
            }
        }
        try await ledger.saveCheckpoint(vaultID: next.vaultID, changes: Array(inventory.values))
        try validateActive(next, identity: bindingID)
    }

    public func receive(_ change: AIContentChange) async throws {
        guard let active = lease, active.vaultID == change.vaultID else { return }
        let admissionID = lifecycleID
        activeAdmissions += 1
        defer { activeAdmissions -= 1 }
        try validateActive(active, identity: admissionID)
        let target = Target(kind: change.entityKind, id: change.entityID)
        inventory[target] = change
        let previousItems = items
        let unfinished = Set(previousItems.values.filter {
            $0.key.entityKind == change.entityKind && $0.key.entityID == change.entityID
                && [.pending, .scheduled, .running, .retryable].contains($0.state)
        }.map { $0.key.processorID })
        // Every committed revision invalidates in-flight candidates, including uninterested changes.
        for old in Array(items.values) where old.key.entityKind == change.entityKind && old.key.entityID == change.entityID {
            if old.revision != change.revision || change.kind == .removed {
                tasks[old.id]?.cancel()
                if old.state != .completed { try await transition(old, to: .superseded) }
                try validateActive(active, identity: admissionID)
            }
        }
        if change.kind != .removed {
            for processor in Array(processors.values) where processor.descriptor.observesCommittedChanges
                && (processor.isEligible(change) || unfinished.contains(processor.descriptor.identifier)) {
                let descriptor = processor.descriptor
                let key = AIWorkKey(vaultID: change.vaultID, entityKind: change.entityKind,
                                    entityID: change.entityID, processorID: descriptor.identifier)
                let old = previousItems[key]
                if old?.revision == change.revision && old?.processorVersion == descriptor.version && change.kind != .reprocess { continue }
                tasks[old?.id ?? UUID()]?.cancel()
                let item = AIWorkItem(key: key, revision: change.revision, processorVersion: descriptor.version,
                    attemptCount: processor.isEligible(change) ? 0 : old?.attemptCount ?? 0,
                    eligibleAt: processor.isEligible(change) ? clock.now().addingTimeInterval(delay(change))
                        : max(old?.eligibleAt ?? clock.now(), clock.now().addingTimeInterval(delay(change))),
                    inputFingerprint: change.kind != .reprocess && old?.processorVersion == descriptor.version ? old?.inputFingerprint : nil,
                    updatedAt: clock.now())
                guard inventory[target]?.revision == change.revision else { continue }
                items[key] = item
                try await persist(item); try validateActive(active, identity: admissionID)
                // Concurrent commits may have overtaken this ledger write.
                guard inventory[target]?.revision == change.revision, items[key]?.id == item.id else { continue }
                arm(item, lease: active)
            }
        }
        // A checkpoint may include another commit only after all admitted jobs
        // for that commit have been persisted. Earlier checkpoints are safe to replay.
        if activeAdmissions == 1 {
            try await ledger.saveCheckpoint(vaultID: active.vaultID, changes: Array(inventory.values))
        }
    }

    /// Explicit historical admission uses the existing scheduler and fixed durable member ID.
    /// A batch row is not authority: processors/policy still revalidate at dispatch/publication.
    public func admitHistorical(_ candidate: AIWorkItem) async throws {
        guard let active = lease, let batchID = candidate.batchID,
              active.vaultID == candidate.key.vaultID,
              let processor = processors[candidate.key.processorID],
              !processor.descriptor.observesCommittedChanges,
              candidate.processorVersion == processor.descriptor.version,
              candidate.key.processorID == EmbeddingWorkProcessor.identifier + ".history." + batchID.uuidString,
              processor.descriptor.targets.contains(candidate.key.entityKind),
              let current = inventory[Target(kind: candidate.key.entityKind, id: candidate.key.entityID)],
              current.kind != .removed else { throw AIWorkFailure.authority }
        let admissionID = lifecycleID
        try validateActive(active, identity: admissionID)
        var incoming = candidate
        if current.revision != incoming.revision {
            guard incoming.key.entityKind == .source else { throw AIWorkFailure.validation }
            if current.revision.hasPrefix(incoming.revision + ":") { incoming.revision = current.revision }
            else { guard historicalRevisionMatches(incoming, current: current) else { throw AIWorkFailure.validation } }
        }
        let persisted = try await ledger.existingWorkItem(key: incoming.key)
        try validateActive(active, identity: admissionID)
        let prior = items[incoming.key] ?? persisted
        if let prior {
            guard prior.id == incoming.id, prior.batchID == batchID,
                  prior.processorVersion == incoming.processorVersion,
                  prior.revision == incoming.revision else { throw AIWorkFailure.validation }
            if [.completed, .cancellationRequested, .cancelled, .failed, .superseded].contains(prior.state) { items[prior.key] = prior; return }
            if tasks[prior.id] != nil { return }
            incoming = prior
        }
        incoming.state = .pending; incoming.failure = nil
        incoming.eligibleAt = clock.now(); incoming.updatedAt = clock.now()
        items[incoming.key] = incoming
        try await persist(incoming)
        try validateActive(active, identity: admissionID)
        guard let latest = inventory[Target(kind: incoming.key.entityKind, id: incoming.key.entityID)],
              historicalRevisionMatches(incoming, current: latest),
              items[incoming.key]?.id == incoming.id else { throw AIWorkFailure.validation }
        // Persistence suspends: another replay can arm this stable identity, or a
        // stop/completion can overtake admission. Never install a second timer.
        guard let admitted = items[incoming.key], admitted.state == .pending,
              tasks[admitted.id] == nil else { return }
        arm(admitted, lease: active)
    }

    /// Pause/cancel only captured work. Waiting for task acknowledgment keeps callers from
    /// presenting cancellation as complete while a provider may still be returning usage.
    public func pauseHistorical(batchID: UUID, retireAuthority: @Sendable () -> Void = {}) async throws {
        try await stopWork(batchID: batchID, processorID: nil, cancel: false, retireAuthority: retireAuthority)
    }
    public func cancelHistorical(batchID: UUID, retireAuthority: @Sendable () -> Void = {}) async throws {
        try await stopWork(batchID: batchID, processorID: nil, cancel: true, retireAuthority: retireAuthority)
    }
    public func pauseProcessor(_ processorID: String) async throws {
        guard let active = lease else { throw AIWorkFailure.authority }
        let identity = lifecycleID
        try validateActive(active, identity: identity)
        pausedProcessors.insert(processorID)
        try await ledger.setProcessorPaused(vaultID: active.vaultID, processorID: processorID, paused: true)
        try validateActive(active, identity: identity)
        try await stopWork(batchID: nil, processorID: processorID, cancel: false)
    }
    public func resumeProcessor(_ processorID: String) async throws {
        guard let active = lease else { throw AIWorkFailure.authority }
        let identity = lifecycleID
        try validateActive(active, identity: identity)
        try await ledger.setProcessorPaused(vaultID: active.vaultID, processorID: processorID, paused: false)
        try validateActive(active, identity: identity)
        pausedProcessors.remove(processorID)
        for var item in Array(items.values) where item.batchID == nil && item.key.processorID == processorID
            && [.suspended, .pending, .scheduled, .retryable].contains(item.state) {
            guard tasks[item.id] == nil else { continue }
            item.state = .pending; item.failure = nil; item.eligibleAt = clock.now()
            item.updatedAt = clock.now(); items[item.key] = item
            try await persist(item); try validateActive(active, identity: identity)
            arm(item, lease: active)
        }
    }
    public func cancelProcessorRemaining(_ processorID: String) async throws {
        try await stopWork(batchID: nil, processorID: processorID, cancel: true)
    }
    public func retryEligibleEmbeddingWork(processorID: String) async throws {
        guard let active = lease else { throw AIWorkFailure.authority }
        let identity = lifecycleID
        for var item in Array(items.values) where item.batchID == nil && item.key.processorID == processorID
            && [.failed, .blocked].contains(item.state) && item.failure?.permitsExplicitRetry == true {
            try validateActive(active, identity: identity)
            item.id = UUID(); item.state = .pending; item.attemptCount = 0
            item.failure = nil; item.inputFingerprint = nil; item.completionDisposition = nil
            item.eligibleAt = clock.now(); item.updatedAt = clock.now(); items[item.key] = item
            try await persist(item); try validateActive(active, identity: identity)
            arm(item, lease: active)
        }
    }
    public func retryHistorical(_ candidate: AIWorkItem, admit: Bool = true) async throws {
        guard candidate.batchID != nil, let active = lease else { throw AIWorkFailure.authority }
        let identity = lifecycleID
        try validateActive(active, identity: identity)
        let stored = try await ledger.existingWorkItem(key: candidate.key)
        try validateActive(active, identity: identity)
        if var prior = items[candidate.key] ?? stored, prior.id == candidate.id,
           prior.batchID == candidate.batchID, prior.revision == candidate.revision,
           prior.processorVersion == candidate.processorVersion, [.failed, .blocked, .suspended].contains(prior.state),
           prior.failure?.permitsExplicitRetry == true {
            prior.state = .suspended; prior.attemptCount = 0; prior.failure = nil
            prior.inputFingerprint = nil; prior.completionDisposition = nil
            prior.updatedAt = clock.now(); items[prior.key] = prior
            try await persist(prior); try validateActive(active, identity: identity)
        }
        if admit { try await admitHistorical(candidate) }
    }
    private func stopWork(batchID: UUID?, processorID: String?, cancel: Bool, retireAuthority: @Sendable () -> Void = {}) async throws {
        guard let active = lease else { throw AIWorkFailure.authority }
        let identity = lifecycleID
        try validateActive(active, identity: identity)
        let selected = items.values.filter {
            (batchID != nil ? $0.batchID == batchID : $0.batchID == nil && $0.key.processorID == processorID)
                && ([.pending, .scheduled, .running, .retryable, .blocked, .suspended].contains($0.state)
                    || (cancel && $0.state == .cancellationRequested))
        }
        let waiting = selected.compactMap { tasks[$0.id] }
        // Set intent synchronously before actor reentrancy or cancellation callbacks.
        for var item in selected {
            if cancel || ![.blocked, .suspended].contains(item.state) {
                item.state = cancel ? .cancellationRequested : .suspended
                item.failure = nil
            }
            item.updatedAt = clock.now(); items[item.key] = item
            tasks[item.id]?.cancel()
        }
        retireAuthority()
        for item in selected { if let updated = items[item.key] { try await persist(updated) } }
        for task in waiting { await task.value }
        if cancel {
            for item in selected { try await transition(item, to: .cancelled) }
        }
        try validateActive(active, identity: identity)
    }

    public func suspend(reason suspension: AIWorkFailure = .authority) async throws {
        try await retire(reason: suspension, identity: UUID())
    }
    private func retire(reason suspension: AIWorkFailure, identity: UUID) async throws {
        lifecycleID = identity
        lease = nil; reason = suspension
        inventory.removeAll()
        for task in tasks.values { task.cancel() }
        for item in Array(items.values) where [.pending, .scheduled, .running, .retryable].contains(item.state) {
            try await transition(item, to: .suspended, failure: suspension)
        }
    }

    /// Only reschedules already eligible jobs; provider availability never creates candidates.
    public func authorityChanged() async throws {
        guard let active = lease else { return }
        let authorityID = lifecycleID
        try validateActive(active, identity: authorityID)
        // Historical intent remains recoverable after revocation. Set suspension before
        // task cancellation so its catch cannot reinterpret revocation as user cancellation.
        var suspendedHistory: [AIWorkItem] = []
        for var item in Array(items.values) where item.batchID != nil
            && [.pending, .scheduled, .running, .retryable].contains(item.state) {
            item.state = .suspended; item.failure = .authority; item.updatedAt = clock.now()
            items[item.key] = item; suspendedHistory.append(item)
        }
        for task in tasks.values { task.cancel() }
        for item in suspendedHistory {
            try await persist(item); try validateActive(active, identity: authorityID)
        }
        for old in Array(items.values) where old.batchID == nil && [.blocked, .suspended, .pending, .scheduled, .running, .retryable].contains(old.state) {
            var item = old
            item.id = UUID(); item.state = .pending; item.failure = nil
            item.eligibleAt = clock.now(); item.updatedAt = clock.now()
            items[item.key] = item
            try await persist(item); try validateActive(active, identity: authorityID)
            guard items[item.key]?.id == item.id else { continue }
            arm(item, lease: active)
        }
        reason = nil
    }

    public func status() -> AIProcessingStatus {
        let visible = lease != nil && gate.currentLease == lease
        let activeWork = busy.filter { items[$0.key]?.id == $0.value }.map { $0.key }
        return AIProcessingStatus(pendingCount: visible ? items.values.filter { [.pending, .scheduled, .retryable].contains($0.state) && !pausedProcessors.contains($0.key.processorID) }.count : 0,
            runningCount: visible ? busy.count : 0, completedCount: completedCount, failedCount: failedCount,
            activeWork: visible ? activeWork : [], reason: visible ? reason : .authority,
            lastSuccessfulAt: lastSuccessfulAt)
    }
    public func workItems() -> [AIWorkItem] { Array(items.values) }

    private func validate(_ active: VaultSessionLease) throws {
        try gate.validate(lease: active, targetRoot: active.root, targetVaultID: active.vaultID, operation: "AIProcessing")
    }
    private func validateActive(_ active: VaultSessionLease, identity: UUID? = nil) throws {
        guard identity == nil || identity == lifecycleID else { throw CancellationError() }
        guard lease == active else { throw CancellationError() }
        try validate(active)
    }
    private func delay(_ change: AIContentChange) -> TimeInterval {
        if change.kind == .reprocess { return 0 }
        if change.entityKind == .page { return change.kind == .created ? configuration.newPageDelay : configuration.updatedPageDelay }
        return change.kind == .created ? configuration.newSourceDelay : configuration.updatedSourceDelay
    }
    private func arm(_ item: AIWorkItem, lease active: VaultSessionLease) {
        guard item.batchID != nil || !pausedProcessors.contains(item.key.processorID) else { return }
        let clock = self.clock
        let taskVersion = UUID()
        taskVersions[item.id] = taskVersion
        let task = Task { [weak self] in
            do {
                try await clock.sleep(max(0, item.eligibleAt.timeIntervalSince(clock.now())))
                try Task.checkCancellation()
                await self?.run(item, lease: active, taskVersion: taskVersion)
            } catch { await self?.discardTask(item.id, version: taskVersion) }
        }
        tasks[item.id] = task
        if let old = invalidators.removeValue(forKey: item.id) { gate.removeSessionInvalidator(old) }
        invalidators[item.id] = gate.registerSessionInvalidator(lease: active, invalidate: { task.cancel() })
    }
    private func discardTask(_ id: UUID, version: UUID? = nil) {
        guard version == nil || taskVersions[id] == version else { return }
        taskVersions.removeValue(forKey: id)
        tasks.removeValue(forKey: id)
        if let token = invalidators.removeValue(forKey: id) { gate.removeSessionInvalidator(token) }
    }
    private func persist(_ candidate: AIWorkItem) async throws {
        var value = candidate
        while true {
            try await ledger.save(value)
            // An injected ledger may suspend and let newer state overtake this write.
            guard let latest = items[candidate.key], latest != value else {
                if let handler = workChangeHandler {
                    let persisted = value
                    Task { await handler(persisted) }
                }
                return
            }
            value = latest
        }
    }
    private func transition(_ candidate: AIWorkItem, to state: AIWorkState, failure: AIWorkFailure? = nil) async throws {
        guard var item = items[candidate.key], item.id == candidate.id, item.state.permits(state) else { return }
        item.state = state; item.failure = failure; item.updatedAt = clock.now()
        items[item.key] = item
        try await persist(item)
    }

    private func run(_ candidate: AIWorkItem, lease active: VaultSessionLease, taskVersion: UUID) async {
        guard lease == active, items[candidate.key]?.id == candidate.id,
              let processor = processors[candidate.key.processorID] else { discardTask(candidate.id, version: taskVersion); return }
        let completionTicket = gate.issueCompletionTicket(kind: .aiProcessing, lease: active,
            token: candidate.id, targetID: candidate.key.entityID)
        let provider = processor.descriptor.provider
        guard busy[candidate.key] == nil, providerUse[provider, default: 0] < 1 else {
            var waiting = candidate; waiting.eligibleAt = clock.now().addingTimeInterval(1)
            arm(waiting, lease: active); return
        }
        busy[candidate.key] = candidate.id; providerUse[provider, default: 0] += 1
        defer {
            busy.removeValue(forKey: candidate.key); providerUse[provider, default: 0] -= 1
            discardTask(candidate.id, version: taskVersion)
        }
        do {
            try validateActive(active); try Task.checkCancellation()
            try await transition(candidate, to: .scheduled)
            try validateCandidate(candidate, lease: active)
            guard var attempt = items[candidate.key], attempt.attemptCount < configuration.maximumAttempts else {
                failedCount += 1
                try await transition(candidate, to: .failed, failure: .attemptsExhausted); return
            }
            attempt.attemptCount += 1; items[attempt.key] = attempt
            try await persist(attempt)
            try validateCandidate(candidate, lease: active)
            let snapshot = try await processor.prepare(candidate, lease: active)
            try validateCandidate(candidate, lease: active)
            guard snapshot.revision == candidate.revision,
                  try await processor.isCurrent(candidate, snapshot: snapshot, lease: active) else {
                try await transition(candidate, to: .superseded); return
            }
            try validateCandidate(candidate, lease: active)
            switch await policy.authorize(processor.descriptor, snapshot: snapshot, lease: active) {
            case .blocked(let failure):
                reason = failure; try await transition(candidate, to: .blocked, failure: failure); return
            case .allowed: break
            }
            try validateCandidate(candidate, lease: active)
            try policy.validateExecution(lease: active)
            var running = items[candidate.key]!
            running.state = .running
            if provider == .cloud { running.possibleTransmittedUsage = true }
            // A previous successful fingerprint is preserved across revision changes.
            let alreadyProcessed = candidate.inputFingerprint == snapshot.inputFingerprint
            // Persist only previously successful fingerprints; interrupted/failed attempts
            // must not be mistaken for deduplication evidence after a restart.
            running.updatedAt = clock.now(); items[running.key] = running
            try await persist(running)
            try validateCandidate(candidate, lease: active)
            let gate = self.gate; let policy = self.policy
            let context = AIProcessingExecutionContext(lease: active, validate: {
                _ = try gate.validateCompletion(completionTicket, expectedToken: candidate.id,
                    expectedTargetID: candidate.key.entityID, checkTargetID: true,
                    operation: "AIProcessing.publish").get()
                try Task.checkCancellation()
                try gate.validate(lease: active, targetRoot: active.root, targetVaultID: active.vaultID, operation: "AIProcessing.publish")
                try policy.validateExecution(lease: active)
            })
            try context.validate()
            let outcome: AIWorkOutcome = alreadyProcessed ? .skipped : try await processor.execute(snapshot, context: context)
            try validateCandidate(candidate, lease: active)
            try context.validate()
            guard try await processor.isCurrent(candidate, snapshot: snapshot, lease: active) else {
                try await transition(candidate, to: .superseded); return
            }
            try validateCandidate(candidate, lease: active)
            switch outcome {
            case .completed, .skipped:
                if var item = items[candidate.key], item.id == candidate.id {
                    item.inputFingerprint = snapshot.inputFingerprint
                    switch outcome { case .skipped: item.completionDisposition = .skipped; default: item.completionDisposition = .completed }
                    items[item.key] = item
                }
                try await transition(candidate, to: .completed)
                try validateCandidate(candidate, lease: active)
                completedCount += 1; lastSuccessfulAt = clock.now(); reason = nil
            case .retryable(let failure): try await retry(candidate, failure: failure, lease: active)
            case .blocked(let failure): reason = failure; try await transition(candidate, to: .blocked, failure: failure)
            case .failed(let failure): failedCount += 1; try await transition(candidate, to: .failed, failure: failure)
            }
        } catch is CancellationError {
            let retired = lease != active || gate.currentLease != active
            if items[candidate.key].map({ ![.suspended, .cancellationRequested].contains($0.state) }) == true {
                try? await transition(candidate, to: retired ? .suspended : .cancelled)
            }
        } catch {
            guard lease == active, items[candidate.key]?.id == candidate.id,
                  items[candidate.key].map({ ![.suspended, .cancellationRequested, .cancelled].contains($0.state) }) == true else { return }
            // Unknown errors are terminal, never interpreted as permission to incur another request.
            let failure = (error as? AIWorkFailure) ?? .validation
            if processor is EmbeddingWorkProcessor, [.authority, .consent].contains(failure) {
                reason = failure
                try? await transition(candidate, to: .blocked, failure: failure)
            } else if failure == .transient { try? await retry(candidate, failure: failure, lease: active) }
            else { failedCount += 1; try? await transition(candidate, to: .failed, failure: failure) }
        }
    }
    /// Metadata-only reopen can omit the previously observed original digest. Retain
    /// that exact evidence: the real Source processor checks the digest before inference
    /// and again at publication. This does not bless a ledger hash as current content.
    private func historicalRevisionMatches(_ item: AIWorkItem, current: AIContentChange) -> Bool {
        current.revision == item.revision || (item.batchID != nil && item.key.entityKind == .source
            && item.revision.hasPrefix(current.revision + ":"))
    }

    private func validateCandidate(_ item: AIWorkItem, lease active: VaultSessionLease) throws {
        try Task.checkCancellation(); try validateActive(active)
        guard items[item.key]?.id == item.id,
              items[item.key].map({ [.pending, .scheduled, .running, .retryable, .completed].contains($0.state) }) == true,
              processors[item.key.processorID]?.descriptor.version == item.processorVersion,
              inventory[Target(kind: item.key.entityKind, id: item.key.entityID)].map({ historicalRevisionMatches(item, current: $0) }) == true,
              inventory[Target(kind: item.key.entityKind, id: item.key.entityID)]?.kind != .removed else { throw CancellationError() }
    }
    private func retry(_ candidate: AIWorkItem, failure: AIWorkFailure, lease active: VaultSessionLease) async throws {
        try validateCandidate(candidate, lease: active)
        guard failure == .transient, var item = items[candidate.key] else {
            try await transition(candidate, to: .blocked, failure: failure); return
        }
        guard item.attemptCount < configuration.maximumAttempts else {
            failedCount += 1; try await transition(candidate, to: .failed, failure: .attemptsExhausted); return
        }
        if item.batchID == nil { item.id = UUID() }
        item.state = .retryable; item.failure = failure
        item.eligibleAt = clock.now().addingTimeInterval(min(configuration.maximumRetryDelay,
            configuration.initialRetryDelay * pow(2, Double(max(0, item.attemptCount - 1)))))
        // Failed inputs must never satisfy successful-input deduplication on retry.
        item.inputFingerprint = nil; item.updatedAt = clock.now(); items[item.key] = item
        try await persist(item); try validateCandidate(item, lease: active)
        // The fresh identity keeps the completing task from retiring the retry timer.
        arm(item, lease: active)
    }
}
