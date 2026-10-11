import Foundation
import Synchronization

/// Capabilities token authorizing access to a specific open vault session and generation.
/// Note: Session leases enforce lifecycle and storage boundary isolation, not cryptographic protection.
public struct VaultSessionLease: Sendable, Equatable {
    public let sessionID: UUID
    public let vaultID: UUID
    public let root: URL
    public let generation: UInt64
    public var epoch: UInt64 { generation }

    public init(sessionID: UUID = UUID(), vaultID: UUID, root: URL, generation: UInt64) {
        self.sessionID = sessionID
        self.vaultID = vaultID
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.generation = generation
    }

    public init(session: VaultSession) {
        self.init(
            sessionID: session.id,
            vaultID: session.vaultID,
            root: session.root,
            generation: session.generation
        )
    }
}

extension VaultSession {
    public var lease: VaultSessionLease {
        VaultSessionLease(session: self)
    }
}

public enum VaultAccessError: Error, Sendable, Equatable, LocalizedError {
    case missingLease(operation: String)
    case sessionClosed(operation: String)
    case sessionLocked(vaultID: UUID, root: URL, operation: String)
    case sessionTransitioning(phase: VaultSessionPhase, operation: String)
    case staleLease(leaseGeneration: UInt64, activeGeneration: UInt64, operation: String)
    case invalidLeaseSession(expectedSessionID: UUID, actualSessionID: UUID, operation: String)
    case wrongVault(
        expectedVaultID: UUID?,
        expectedRoot: URL,
        actualVaultID: UUID?,
        actualRoot: URL,
        operation: String
    )

    public var errorDescription: String? {
        switch self {
        case .missingLease(let operation):
            "Protected vault operation '\(operation)' requires a valid session lease."
        case .sessionClosed(let operation):
            "Cannot perform '\(operation)' while the vault session is closed."
        case .sessionLocked(_, _, let operation):
            "Cannot perform '\(operation)' while the vault session is locked."
        case .sessionTransitioning(let phase, let operation):
            "Cannot perform '\(operation)' while the vault session is \(phase.rawValue)."
        case .staleLease(let leaseGeneration, let activeGeneration, let operation):
            "Stale session lease (generation \(leaseGeneration), active \(activeGeneration)) rejected for '\(operation)'."
        case .invalidLeaseSession(_, _, let operation):
            "Session lease does not match the active open session for '\(operation)'."
        case .wrongVault(_, let expectedRoot, _, let actualRoot, let operation):
            "Vault access mismatch for '\(operation)' (target: \(expectedRoot.lastPathComponent), lease/session: \(actualRoot.lastPathComponent))."
        }
    }
}

/// Descriptor for an operation admitted through the central lock admission barrier.
public struct VaultAdmittedOperation: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let sessionID: UUID
    public let vaultID: UUID
    public let root: URL
    public let generation: UInt64
    public let lease: VaultSessionLease
    public var epoch: UInt64 { generation }

    public init(
        id: UUID = UUID(),
        name: String,
        lease: VaultSessionLease
    ) {
        self.id = id
        self.name = name
        self.sessionID = lease.sessionID
        self.vaultID = lease.vaultID
        self.root = lease.root
        self.generation = lease.generation
        self.lease = lease
    }
}

public enum VaultOperationDisposition: String, Sendable, Equatable, CaseIterable {
    case completed
    case cancelled
    case abandoned
}

public struct VaultOperationRegistrySnapshot: Sendable, Equatable {
    public let isBarrierOpen: Bool
    public let phase: VaultSessionPhase
    public let sessionID: UUID?
    public let generation: UInt64
    public let activeOperations: [VaultAdmittedOperation]
    public let totalAdmittedCount: Int
    public let totalCompletedCount: Int
    public let totalCancelledCount: Int
    public let totalAbandonedCount: Int

    public var activeCount: Int { activeOperations.count }
}

public enum VaultOperationAdmissionError: Error, Sendable, Equatable, LocalizedError {
    case barrierClosed(
        phase: VaultSessionPhase,
        vaultID: UUID?,
        root: URL?,
        generation: UInt64,
        operation: String
    )
    case invalidLease(VaultAccessError)
    case duplicateOperationID(UUID, operation: String)
    case cancelled(operation: String)

    public var errorDescription: String? {
        switch self {
        case .barrierClosed(let phase, _, _, _, let operation):
            "Cannot admit operation '\(operation)' while lock barrier is closed (session is \(phase.rawValue))."
        case .invalidLease(let accessError):
            accessError.errorDescription
        case .duplicateOperationID(let id, let operation):
            "Operation '\(operation)' with ID \(id.uuidString) is already registered."
        case .cancelled(let operation):
            "Operation '\(operation)' was cancelled."
        }
    }
}

/// Tracks an admitted protected operation and guarantees registration release on completion, cancellation, or abandonment.
public final class VaultOperationRegistration: Sendable {
    public let descriptor: VaultAdmittedOperation
    private let state: Mutex<VaultOperationDisposition?>
    private let onFinish: @Sendable (UUID, UUID, VaultOperationDisposition) -> Void

    public var id: UUID { descriptor.id }
    public var name: String { descriptor.name }
    public var lease: VaultSessionLease { descriptor.lease }
    public var sessionID: UUID { descriptor.sessionID }
    public var vaultID: UUID { descriptor.vaultID }
    public var root: URL { descriptor.root }
    public var generation: UInt64 { descriptor.generation }
    public var epoch: UInt64 { descriptor.generation }

    init(
        descriptor: VaultAdmittedOperation,
        onFinish: @escaping @Sendable (UUID, UUID, VaultOperationDisposition) -> Void
    ) {
        self.descriptor = descriptor
        self.state = Mutex(nil)
        self.onFinish = onFinish
    }

    public var disposition: VaultOperationDisposition? {
        state.withLock { $0 }
    }

    public var isActive: Bool {
        state.withLock { $0 == nil }
    }

    public func complete(disposition: VaultOperationDisposition = .completed) {
        let shouldNotify = state.withLock { current -> Bool in
            guard current == nil else { return false }
            current = disposition
            return true
        }
        if shouldNotify {
            onFinish(descriptor.id, descriptor.sessionID, disposition)
        }
    }

    public func cancel() {
        complete(disposition: .cancelled)
    }

    public func abandon() {
        complete(disposition: .abandoned)
    }

    /// Executes `body` with this registration bound as the active task-local admitted operation so
    /// already-admitted repository and content-store calls may finish while the lock barrier is draining.
    public func withScope<T>(
        completeOnExit: Bool = false,
        _ body: () async throws -> T
    ) async rethrows -> T {
        defer {
            if completeOnExit {
                complete(disposition: Task.isCancelled ? .cancelled : .completed)
            }
        }
        return try await VaultLockAdmissionBarrier.$currentOperationID.withValue(descriptor.id) {
            try await body()
        }
    }

    deinit {
        let shouldAbandon = state.withLock { current -> Bool in
            guard current == nil else { return false }
            current = .abandoned
            return true
        }
        if shouldAbandon {
            onFinish(descriptor.id, descriptor.sessionID, .abandoned)
        }
    }
}

/// Central lock admission barrier and operation registry synchronized with `VaultAccessGate` and `VaultSessionManager`.
public final class VaultLockAdmissionBarrier: Sendable {
    @TaskLocal public static var currentOperationID: UUID?

    private let gate: VaultAccessGate

    public init(gate: VaultAccessGate) {
        self.gate = gate
    }

    public var isOpen: Bool {
        gate.registrySnapshot().isBarrierOpen
    }

    public var activeOperations: [VaultAdmittedOperation] {
        gate.registrySnapshot().activeOperations
    }

    public var activeCount: Int {
        gate.registrySnapshot().activeCount
    }

    public func snapshot() -> VaultOperationRegistrySnapshot {
        gate.registrySnapshot()
    }

    public func admit(
        operation: String,
        lease: VaultSessionLease? = nil,
        targetRoot: URL? = nil,
        targetVaultID: UUID? = nil,
        id: UUID = UUID()
    ) throws -> VaultOperationRegistration {
        try gate.admitOperation(
            operation: operation,
            lease: lease,
            targetRoot: targetRoot,
            targetVaultID: targetVaultID,
            id: id
        )
    }

    public func withAdmittedOperation<T: Sendable>(
        _ operation: String,
        lease: VaultSessionLease? = nil,
        targetRoot: URL? = nil,
        targetVaultID: UUID? = nil,
        id: UUID = UUID(),
        body: @Sendable (VaultOperationRegistration) async throws -> T
    ) async throws -> T {
        let registration = try admit(
            operation: operation,
            lease: lease,
            targetRoot: targetRoot,
            targetVaultID: targetVaultID,
            id: id
        )
        do {
            let result = try await VaultLockAdmissionBarrier.$currentOperationID.withValue(registration.id) {
                try await body(registration)
            }
            registration.complete(disposition: Task.isCancelled ? .cancelled : .completed)
            return result
        } catch {
            if error is CancellationError || Task.isCancelled {
                registration.cancel()
            } else {
                registration.complete(disposition: .completed)
            }
            throw error
        }
    }

    public func awaitInFlightOperations(forSessionID sessionID: UUID? = nil) async throws {
        try await gate.awaitInFlightOperations(forSessionID: sessionID)
    }
}

/// Synchronously revalidates session leases when protected storage or repository I/O executes,
/// and atomically coordinates the lock admission barrier and active operation registry.
public final class VaultAccessGate: Sendable {
    private struct DrainWaiter: Sendable {
        let id: UUID
        let sessionID: UUID?
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct GateState: Sendable {
        var contentInvalidators: [UUID: (VaultSessionLease, @Sendable () -> Void)] = [:]
        var sessionState: VaultSessionState
        var highestGeneration: UInt64
        var trackedSessionID: UUID?
        var activeOperations: [UUID: VaultAdmittedOperation] = [:]
        var activeOrder: [UUID] = []
        var quiescenceOperations: [UUID: (sessionID: UUID, generation: UInt64)] = [:]
        var totalAdmittedCount: Int = 0
        var totalCompletedCount: Int = 0
        var totalCancelledCount: Int = 0
        var totalAbandonedCount: Int = 0
        var acceptedCompletionCount: Int = 0
        var rejectedCompletionRecords: [VaultStaleCompletionRecord] = []
        var drainWaiters: [UUID: DrainWaiter] = [:]
    }

    private let state: Mutex<GateState>

    public init(initialState: VaultSessionState = .closed) {
        let initialSessionID: UUID? = switch initialState {
        case .open(let session), .locking(let session): session.id
        default: nil
        }
        self.state = Mutex(GateState(
            sessionState: initialState,
            highestGeneration: initialState.generation,
            trackedSessionID: initialSessionID
        ))
    }

    public var admissionBarrier: VaultLockAdmissionBarrier {
        VaultLockAdmissionBarrier(gate: self)
    }

    public var staleResultGuard: VaultStaleResultGuard {
        VaultStaleResultGuard(gate: self)
    }

    public var currentState: VaultSessionState {
        state.withLock { $0.sessionState }
    }

    public var currentLease: VaultSessionLease? {
        state.withLock { $0.sessionState.activeSession?.lease }
    }

    public func updateState(_ next: VaultSessionState) {
        let waitersToResume: [CheckedContinuation<Void, Error>] = state.withLock { gate in
            // Retirement is synchronous with session revocation. Handlers only discard memory;
            // they must not call back into the gate or execute I/O.
            for (id, entry) in gate.contentInvalidators where next.activeSession?.lease != entry.0 || next.phase != .open {
                entry.1()
                gate.contentInvalidators.removeValue(forKey: id)
            }
            gate.sessionState = next
            if next.generation > gate.highestGeneration {
                gate.highestGeneration = next.generation
            }

            switch next {
            case .open(let session):
                if gate.trackedSessionID != session.id {
                    let abandonedCount = gate.activeOperations.count
                    if abandonedCount > 0 {
                        gate.totalAbandonedCount += abandonedCount
                        gate.activeOperations.removeAll()
                        gate.activeOrder.removeAll()
                    }
                    gate.quiescenceOperations.removeAll()
                    gate.trackedSessionID = session.id
                    return Self.collectReadyWaiters(&gate)
                }
                gate.quiescenceOperations.removeAll()
                return []

            case .locking(let session):
                gate.trackedSessionID = session.id
                return Self.collectReadyWaiters(&gate)

            case .closed, .opening, .locked, .unlocking:
                let abandonedCount = gate.activeOperations.count
                if abandonedCount > 0 {
                    gate.totalAbandonedCount += abandonedCount
                    gate.activeOperations.removeAll()
                    gate.activeOrder.removeAll()
                }
                gate.quiescenceOperations.removeAll()
                gate.trackedSessionID = nil
                return Self.collectReadyWaiters(&gate)
            }
        }

        for continuation in waitersToResume {
            continuation.resume()
        }
    }

    /// Registers session-bound memory retirement without changing lifecycle/admission semantics.
    func registerContentInvalidator(lease: VaultSessionLease, invalidate: @escaping @Sendable () -> Void) -> UUID {
        state.withLock { gate in
            let id = UUID()
            if gate.sessionState.activeSession?.lease == lease, gate.sessionState.phase == .open {
                gate.contentInvalidators[id] = (lease, invalidate)
            } else { invalidate() }
            return id
        }
    }

    func removeContentInvalidator(_ id: UUID) {
        _ = state.withLock { $0.contentInvalidators.removeValue(forKey: id) }
    }

    public func issueLease(for targetRoot: URL? = nil, vaultID: UUID? = nil) throws -> VaultSessionLease {
        let normalizedTarget = targetRoot?.standardizedFileURL.resolvingSymlinksInPath()
        return try state.withLock { gate in
            switch gate.sessionState {
            case .closed:
                throw VaultAccessError.sessionClosed(operation: "issueLease")
            case .locked(let lockedID, let root, _, _):
                if let normalizedTarget, normalizedTarget != root {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: vaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: lockedID,
                        actualRoot: root,
                        operation: "issueLease"
                    )
                }
                throw VaultAccessError.sessionLocked(vaultID: lockedID, root: root, operation: "issueLease")
            case .locking(let session):
                if let normalizedTarget, normalizedTarget != session.root {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: vaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: session.vaultID,
                        actualRoot: session.root,
                        operation: "issueLease"
                    )
                }
                throw VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: "issueLease")
            case .opening(let root, _):
                if let normalizedTarget, normalizedTarget != root {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: vaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: nil,
                        actualRoot: root,
                        operation: "issueLease"
                    )
                }
                throw VaultAccessError.sessionTransitioning(phase: .opening, operation: "issueLease")
            case .unlocking(let unlockingID, let root, _, _):
                if let normalizedTarget, normalizedTarget != root {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: vaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: unlockingID,
                        actualRoot: root,
                        operation: "issueLease"
                    )
                }
                throw VaultAccessError.sessionTransitioning(phase: .unlocking, operation: "issueLease")
            case .open(let session):
                if let normalizedTarget, normalizedTarget != session.root {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: vaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: session.vaultID,
                        actualRoot: session.root,
                        operation: "issueLease"
                    )
                }
                if let vaultID, vaultID != session.vaultID {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: vaultID,
                        expectedRoot: normalizedTarget ?? session.root,
                        actualVaultID: session.vaultID,
                        actualRoot: session.root,
                        operation: "issueLease"
                    )
                }
                return session.lease
            }
        }
    }

    public func validate(
        lease: VaultSessionLease?,
        targetRoot: URL,
        targetVaultID: UUID? = nil,
        operation: String
    ) throws {
        guard let lease else {
            throw VaultAccessError.missingLease(operation: operation)
        }
        let normalizedTarget = targetRoot.standardizedFileURL.resolvingSymlinksInPath()

        if lease.root != normalizedTarget || (targetVaultID != nil && lease.vaultID != targetVaultID) {
            throw VaultAccessError.wrongVault(
                expectedVaultID: targetVaultID,
                expectedRoot: normalizedTarget,
                actualVaultID: lease.vaultID,
                actualRoot: lease.root,
                operation: operation
            )
        }

        try state.withLock { gate in
            switch gate.sessionState {
            case .closed:
                if gate.highestGeneration > 0 && lease.generation < gate.highestGeneration {
                    throw VaultAccessError.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: gate.highestGeneration,
                        operation: operation
                    )
                }
                throw VaultAccessError.sessionClosed(operation: operation)

            case .locked(let lockedID, let lockedRoot, _, let lockedGen):
                if lease.generation != lockedGen {
                    throw VaultAccessError.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: max(lockedGen, gate.highestGeneration),
                        operation: operation
                    )
                }
                if lockedRoot != normalizedTarget || (targetVaultID != nil && lockedID != targetVaultID) {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: targetVaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: lockedID,
                        actualRoot: lockedRoot,
                        operation: operation
                    )
                }
                throw VaultAccessError.sessionLocked(vaultID: lockedID, root: lockedRoot, operation: operation)

            case .locking(let session):
                if lease.generation != session.generation {
                    throw VaultAccessError.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: max(session.generation, gate.highestGeneration),
                        operation: operation
                    )
                }
                if session.root != normalizedTarget || (targetVaultID != nil && session.vaultID != targetVaultID) {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: targetVaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: session.vaultID,
                        actualRoot: session.root,
                        operation: operation
                    )
                }
                if lease.sessionID != session.id {
                    throw VaultAccessError.invalidLeaseSession(
                        expectedSessionID: session.id,
                        actualSessionID: lease.sessionID,
                        operation: operation
                    )
                }
                if let activeOpID = VaultLockAdmissionBarrier.currentOperationID {
                    if let registered = gate.activeOperations[activeOpID],
                       registered.sessionID == session.id,
                       registered.generation == session.generation {
                        return
                    }
                    if let quiescenceOp = gate.quiescenceOperations[activeOpID],
                       quiescenceOp.sessionID == session.id,
                       quiescenceOp.generation == session.generation {
                        return
                    }
                }
                throw VaultAccessError.sessionLocked(vaultID: session.vaultID, root: session.root, operation: operation)

            case .opening(let openingRoot, let candidateGen):
                if lease.generation < gate.highestGeneration {
                    throw VaultAccessError.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: candidateGen,
                        operation: operation
                    )
                }
                if openingRoot != normalizedTarget {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: targetVaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: nil,
                        actualRoot: openingRoot,
                        operation: operation
                    )
                }
                throw VaultAccessError.sessionTransitioning(phase: .opening, operation: operation)

            case .unlocking(let unlockingID, let unlockingRoot, _, let candidateGen):
                if lease.generation < gate.highestGeneration {
                    throw VaultAccessError.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: candidateGen,
                        operation: operation
                    )
                }
                if unlockingRoot != normalizedTarget || (targetVaultID != nil && unlockingID != targetVaultID) {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: targetVaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: unlockingID,
                        actualRoot: unlockingRoot,
                        operation: operation
                    )
                }
                throw VaultAccessError.sessionTransitioning(phase: .unlocking, operation: operation)

            case .open(let activeSession):
                if lease.generation != activeSession.generation {
                    throw VaultAccessError.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: activeSession.generation,
                        operation: operation
                    )
                }
                if activeSession.root != normalizedTarget
                    || (targetVaultID != nil && activeSession.vaultID != targetVaultID)
                    || lease.vaultID != activeSession.vaultID
                    || lease.root != activeSession.root {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: targetVaultID ?? lease.vaultID,
                        expectedRoot: normalizedTarget,
                        actualVaultID: activeSession.vaultID,
                        actualRoot: activeSession.root,
                        operation: operation
                    )
                }
                if lease.sessionID != activeSession.id {
                    throw VaultAccessError.invalidLeaseSession(
                        expectedSessionID: activeSession.id,
                        actualSessionID: lease.sessionID,
                        operation: operation
                    )
                }
            }
        }
    }

    public func registrySnapshot() -> VaultOperationRegistrySnapshot {
        state.withLock { gate in
            let ordered = gate.activeOrder.compactMap { gate.activeOperations[$0] }
            let isOpen: Bool = if case .open = gate.sessionState { true } else { false }
            return VaultOperationRegistrySnapshot(
                isBarrierOpen: isOpen,
                phase: gate.sessionState.phase,
                sessionID: gate.trackedSessionID,
                generation: gate.sessionState.generation,
                activeOperations: ordered,
                totalAdmittedCount: gate.totalAdmittedCount,
                totalCompletedCount: gate.totalCompletedCount,
                totalCancelledCount: gate.totalCancelledCount,
                totalAbandonedCount: gate.totalAbandonedCount
            )
        }
    }

    public func admitOperation(
        operation: String,
        lease: VaultSessionLease? = nil,
        targetRoot: URL? = nil,
        targetVaultID: UUID? = nil,
        id: UUID = UUID()
    ) throws -> VaultOperationRegistration {
        if Task.isCancelled {
            throw VaultOperationAdmissionError.cancelled(operation: operation)
        }
        let normalizedTarget = targetRoot?.standardizedFileURL.resolvingSymlinksInPath()

        let descriptor: VaultAdmittedOperation = try state.withLock { gate in
            if let lease {
                let checkRoot = normalizedTarget ?? lease.root
                if lease.root != checkRoot || (targetVaultID != nil && lease.vaultID != targetVaultID) {
                    throw VaultOperationAdmissionError.invalidLease(.wrongVault(
                        expectedVaultID: targetVaultID,
                        expectedRoot: checkRoot,
                        actualVaultID: lease.vaultID,
                        actualRoot: lease.root,
                        operation: operation
                    ))
                }
            }

            switch gate.sessionState {
            case .open(let activeSession):
                let resolvedLease = lease ?? activeSession.lease
                let checkRoot = normalizedTarget ?? resolvedLease.root
                if resolvedLease.generation != activeSession.generation {
                    throw VaultOperationAdmissionError.invalidLease(.staleLease(
                        leaseGeneration: resolvedLease.generation,
                        activeGeneration: activeSession.generation,
                        operation: operation
                    ))
                }
                if activeSession.root != checkRoot
                    || (targetVaultID != nil && activeSession.vaultID != targetVaultID)
                    || resolvedLease.vaultID != activeSession.vaultID
                    || resolvedLease.root != activeSession.root {
                    throw VaultOperationAdmissionError.invalidLease(.wrongVault(
                        expectedVaultID: targetVaultID ?? resolvedLease.vaultID,
                        expectedRoot: checkRoot,
                        actualVaultID: activeSession.vaultID,
                        actualRoot: activeSession.root,
                        operation: operation
                    ))
                }
                if resolvedLease.sessionID != activeSession.id {
                    throw VaultOperationAdmissionError.invalidLease(.invalidLeaseSession(
                        expectedSessionID: activeSession.id,
                        actualSessionID: resolvedLease.sessionID,
                        operation: operation
                    ))
                }
                if gate.activeOperations[id] != nil {
                    throw VaultOperationAdmissionError.duplicateOperationID(id, operation: operation)
                }
                let admitted = VaultAdmittedOperation(id: id, name: operation, lease: resolvedLease)
                gate.trackedSessionID = activeSession.id
                gate.activeOperations[id] = admitted
                gate.activeOrder.append(id)
                gate.totalAdmittedCount += 1
                return admitted

            case .locking(let session):
                if let lease {
                    if lease.generation != session.generation {
                        throw VaultOperationAdmissionError.invalidLease(.staleLease(
                            leaseGeneration: lease.generation,
                            activeGeneration: max(session.generation, gate.highestGeneration),
                            operation: operation
                        ))
                    }
                    let checkRoot = normalizedTarget ?? lease.root
                    if session.root != checkRoot
                        || (targetVaultID != nil && session.vaultID != targetVaultID)
                        || lease.vaultID != session.vaultID
                        || lease.root != session.root {
                        throw VaultOperationAdmissionError.invalidLease(.wrongVault(
                            expectedVaultID: targetVaultID ?? lease.vaultID,
                            expectedRoot: checkRoot,
                            actualVaultID: session.vaultID,
                            actualRoot: session.root,
                            operation: operation
                        ))
                    }
                }
                throw VaultOperationAdmissionError.barrierClosed(
                    phase: .locking,
                    vaultID: session.vaultID,
                    root: session.root,
                    generation: session.generation,
                    operation: operation
                )

            case .locked(let lockedID, let lockedRoot, _, let lockedGen):
                if let lease, lease.generation != lockedGen {
                    throw VaultOperationAdmissionError.invalidLease(.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: max(lockedGen, gate.highestGeneration),
                        operation: operation
                    ))
                }
                throw VaultOperationAdmissionError.barrierClosed(
                    phase: .locked,
                    vaultID: lockedID,
                    root: lockedRoot,
                    generation: lockedGen,
                    operation: operation
                )

            case .closed:
                if let lease, gate.highestGeneration > 0 && lease.generation < gate.highestGeneration {
                    throw VaultOperationAdmissionError.invalidLease(.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: gate.highestGeneration,
                        operation: operation
                    ))
                }
                throw VaultOperationAdmissionError.barrierClosed(
                    phase: .closed,
                    vaultID: nil,
                    root: nil,
                    generation: gate.highestGeneration,
                    operation: operation
                )

            case .opening(let openingRoot, let candidateGen):
                if let lease, lease.generation < gate.highestGeneration {
                    throw VaultOperationAdmissionError.invalidLease(.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: candidateGen,
                        operation: operation
                    ))
                }
                throw VaultOperationAdmissionError.barrierClosed(
                    phase: .opening,
                    vaultID: nil,
                    root: openingRoot,
                    generation: candidateGen,
                    operation: operation
                )

            case .unlocking(let unlockingID, let unlockingRoot, _, let candidateGen):
                if let lease, lease.generation < gate.highestGeneration {
                    throw VaultOperationAdmissionError.invalidLease(.staleLease(
                        leaseGeneration: lease.generation,
                        activeGeneration: candidateGen,
                        operation: operation
                    ))
                }
                throw VaultOperationAdmissionError.barrierClosed(
                    phase: .unlocking,
                    vaultID: unlockingID,
                    root: unlockingRoot,
                    generation: candidateGen,
                    operation: operation
                )
            }
        }

        return VaultOperationRegistration(descriptor: descriptor) { [weak self] opID, sessionID, disposition in
            self?.finishOperation(id: opID, sessionID: sessionID, disposition: disposition)
        }
    }

    private func finishOperation(id: UUID, sessionID: UUID, disposition: VaultOperationDisposition) {
        let waitersToResume: [CheckedContinuation<Void, Error>] = state.withLock { gate in
            guard let existing = gate.activeOperations.removeValue(forKey: id),
                  existing.sessionID == sessionID else {
                return []
            }
            gate.activeOrder.removeAll { $0 == id }
            switch disposition {
            case .completed:
                gate.totalCompletedCount += 1
            case .cancelled:
                gate.totalCancelledCount += 1
            case .abandoned:
                gate.totalAbandonedCount += 1
            }
            return Self.collectReadyWaiters(&gate)
        }

        for continuation in waitersToResume {
            continuation.resume()
        }
    }

    private static func hasMatchingActiveOperations(in gate: GateState, sessionID: UUID?) -> Bool {
        guard let sessionID else {
            return !gate.activeOperations.isEmpty
        }
        return gate.activeOperations.values.contains { $0.sessionID == sessionID }
    }

    private static func collectReadyWaiters(_ gate: inout GateState) -> [CheckedContinuation<Void, Error>] {
        var readyIDs: [UUID] = []
        var readyContinuations: [CheckedContinuation<Void, Error>] = []
        for (waiterID, waiter) in gate.drainWaiters {
            if !hasMatchingActiveOperations(in: gate, sessionID: waiter.sessionID) {
                readyIDs.append(waiterID)
                readyContinuations.append(waiter.continuation)
            }
        }
        for waiterID in readyIDs {
            gate.drainWaiters.removeValue(forKey: waiterID)
        }
        return readyContinuations
    }

    public func awaitInFlightOperations(forSessionID sessionID: UUID? = nil) async throws {
        if Task.isCancelled {
            throw VaultOperationAdmissionError.cancelled(operation: "awaitInFlightOperations")
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let shouldResumeImmediately: Result<Void, Error>? = state.withLock { gate in
                    if Task.isCancelled {
                        return .failure(VaultOperationAdmissionError.cancelled(operation: "awaitInFlightOperations"))
                    }
                    if !Self.hasMatchingActiveOperations(in: gate, sessionID: sessionID) {
                        return .success(())
                    }
                    gate.drainWaiters[waiterID] = DrainWaiter(
                        id: waiterID,
                        sessionID: sessionID,
                        continuation: continuation
                    )
                    return nil
                }
                if let shouldResumeImmediately {
                    continuation.resume(with: shouldResumeImmediately)
                }
            }
        } onCancel: {
            let cancelledWaiter: CheckedContinuation<Void, Error>? = state.withLock { gate in
                gate.drainWaiters.removeValue(forKey: waiterID)?.continuation
            }
            cancelledWaiter?.resume(throwing: VaultOperationAdmissionError.cancelled(operation: "awaitInFlightOperations"))
        }
    }

    func registerQuiescenceScope(id: UUID, session: VaultSession) {
        state.withLock { gate in
            gate.quiescenceOperations[id] = (sessionID: session.id, generation: session.generation)
        }
    }

    func unregisterQuiescenceScope(id: UUID, sessionID: UUID) {
        state.withLock { gate in
            if gate.quiescenceOperations[id]?.sessionID == sessionID {
                gate.quiescenceOperations.removeValue(forKey: id)
            }
        }
    }

    public var acceptedCompletionCount: Int {
        state.withLock { $0.acceptedCompletionCount }
    }

    public var rejectedCompletionCount: Int {
        state.withLock { $0.rejectedCompletionRecords.count }
    }

    public var rejectedCompletionRecords: [VaultStaleCompletionRecord] {
        state.withLock { $0.rejectedCompletionRecords }
    }

    public func issueCompletionTicket(
        kind: VaultCompletionKind,
        lease: VaultSessionLease? = nil,
        token: UUID = UUID(),
        targetID: UUID? = nil,
        capturedText: String? = nil
    ) -> VaultCompletionTicket {
        let resolvedLease: VaultSessionLease? = state.withLock { gate in
            if let lease { return lease }
            return gate.sessionState.activeSession?.lease
        }
        return VaultCompletionTicket(
            lease: resolvedLease,
            kind: kind,
            token: token,
            targetID: targetID,
            capturedText: capturedText
        )
    }

    public func validateCompletion(
        _ ticket: VaultCompletionTicket?,
        expectedToken: UUID? = nil,
        expectedTargetID: UUID? = nil,
        checkTargetID: Bool = false,
        currentText: String? = nil,
        operation: String? = nil
    ) -> Result<VaultSession?, VaultStaleCompletionError> {
        let opName = operation ?? (ticket?.kind.rawValue ?? "completion")
        guard let ticket else {
            return recordRejectedCompletion(
                kind: .lifecycle,
                operation: opName,
                reason: .missingTicket,
                ticketGeneration: 0
            )
        }

        return state.withLock { gate in
            let activeGen = max(gate.sessionState.generation, gate.highestGeneration)
            func reject(_ reason: VaultStaleCompletionReason) -> Result<VaultSession?, VaultStaleCompletionError> {
                let record = VaultStaleCompletionRecord(
                    kind: ticket.kind,
                    operation: opName,
                    reason: reason,
                    ticketGeneration: ticket.generation,
                    activeGeneration: activeGen
                )
                gate.rejectedCompletionRecords.append(record)
                return .failure(.rejected(kind: ticket.kind, operation: opName, reason: reason))
            }

            // If the ticket is bound to a session lease or the gate has tracked any session lifecycle state,
            // revalidate session phase, identity, root, and monotonic generation/epoch first.
            var validatedSession: VaultSession? = nil
            if ticket.lease != nil || gate.sessionState != .closed || gate.highestGeneration > 0 {
                guard let lease = ticket.lease else {
                    if gate.highestGeneration > 0 {
                        return reject(.staleEpoch(ticketGeneration: 0, activeGeneration: activeGen))
                    }
                    return reject(.missingTicket)
                }

                switch gate.sessionState {
                case .closed:
                    return reject(.sessionClosed)

                case .locked(let lockedID, let lockedRoot, _, let lockedGen):
                    if lease.vaultID != lockedID || lease.root != lockedRoot {
                        return reject(.wrongVault(
                            ticketVaultID: lease.vaultID,
                            ticketRoot: lease.root,
                            activeVaultID: lockedID,
                            activeRoot: lockedRoot
                        ))
                    }
                    if lease.generation != lockedGen {
                        return reject(.staleEpoch(ticketGeneration: lease.generation, activeGeneration: activeGen))
                    }
                    return reject(.sessionLocked(vaultID: lockedID, root: lockedRoot, generation: lockedGen))

                case .locking(let session):
                    if lease.vaultID != session.vaultID || lease.root != session.root {
                        return reject(.wrongVault(
                            ticketVaultID: lease.vaultID,
                            ticketRoot: lease.root,
                            activeVaultID: session.vaultID,
                            activeRoot: session.root
                        ))
                    }
                    if lease.generation != session.generation {
                        return reject(.staleEpoch(ticketGeneration: lease.generation, activeGeneration: activeGen))
                    }
                    return reject(.sessionLocked(vaultID: session.vaultID, root: session.root, generation: session.generation))

                case .opening(_, let candidateGen):
                    if lease.generation < candidateGen {
                        return reject(.staleEpoch(ticketGeneration: lease.generation, activeGeneration: candidateGen))
                    }
                    return reject(.sessionTransitioning(phase: .opening, generation: candidateGen))

                case .unlocking(_, _, _, let candidateGen):
                    if lease.generation < candidateGen {
                        return reject(.staleEpoch(ticketGeneration: lease.generation, activeGeneration: candidateGen))
                    }
                    return reject(.sessionTransitioning(phase: .unlocking, generation: candidateGen))

                case .open(let activeSession):
                    if lease.vaultID != activeSession.vaultID || lease.root != activeSession.root {
                        return reject(.wrongVault(
                            ticketVaultID: lease.vaultID,
                            ticketRoot: lease.root,
                            activeVaultID: activeSession.vaultID,
                            activeRoot: activeSession.root
                        ))
                    }
                    if lease.generation != activeSession.generation {
                        return reject(.staleEpoch(
                            ticketGeneration: lease.generation,
                            activeGeneration: activeSession.generation
                        ))
                    }
                    if lease.sessionID != activeSession.id {
                        return reject(.sessionMismatch(
                            ticketSessionID: lease.sessionID,
                            activeSessionID: activeSession.id
                        ))
                    }
                    validatedSession = activeSession
                }
            }

            if let expectedToken, ticket.token != expectedToken {
                return reject(.tokenMismatch(expectedToken: expectedToken, actualToken: ticket.token))
            }
            if checkTargetID, ticket.targetID != expectedTargetID {
                return reject(.targetMismatch(expectedTargetID: expectedTargetID, actualTargetID: ticket.targetID))
            }
            if let capturedText = ticket.capturedText, let currentText, capturedText != currentText {
                return reject(.contentChanged)
            }

            gate.acceptedCompletionCount += 1
            return .success(validatedSession)
        }
    }

    private func recordRejectedCompletion(
        kind: VaultCompletionKind,
        operation: String,
        reason: VaultStaleCompletionReason,
        ticketGeneration: UInt64
    ) -> Result<VaultSession?, VaultStaleCompletionError> {
        state.withLock { gate in
            let activeGen = max(gate.sessionState.generation, gate.highestGeneration)
            gate.rejectedCompletionRecords.append(VaultStaleCompletionRecord(
                kind: kind,
                operation: operation,
                reason: reason,
                ticketGeneration: ticketGeneration,
                activeGeneration: activeGen
            ))
            return .failure(.rejected(kind: kind, operation: operation, reason: reason))
        }
    }
}

/// Classification of asynchronous completion boundaries guarded against stale publication.
public enum VaultCompletionKind: String, Sendable, Equatable, CaseIterable {
    case search
    case preview
    case sourceLoading
    case indexing
    case aiProcessing
    case pageMutation
    case trashMutation
    case refresh
    case lifecycle
}

/// Generation and session-identity token captured when an asynchronous operation is scheduled,
/// and revalidated before any resulting state publication occurs.
public struct VaultCompletionTicket: Sendable, Equatable {
    public let lease: VaultSessionLease?
    public let kind: VaultCompletionKind
    public let token: UUID
    public let targetID: UUID?
    public let capturedText: String?

    public var sessionID: UUID? { lease?.sessionID }
    public var vaultID: UUID? { lease?.vaultID }
    public var root: URL? { lease?.root }
    public var generation: UInt64 { lease?.generation ?? 0 }
    public var epoch: UInt64 { generation }

    public init(
        lease: VaultSessionLease?,
        kind: VaultCompletionKind = .lifecycle,
        token: UUID = UUID(),
        targetID: UUID? = nil,
        capturedText: String? = nil
    ) {
        self.lease = lease
        self.kind = kind
        self.token = token
        self.targetID = targetID
        self.capturedText = capturedText
    }

    public init(
        session: VaultSession,
        kind: VaultCompletionKind = .lifecycle,
        token: UUID = UUID(),
        targetID: UUID? = nil,
        capturedText: String? = nil
    ) {
        self.init(
            lease: session.lease,
            kind: kind,
            token: token,
            targetID: targetID,
            capturedText: capturedText
        )
    }
}

/// Specific reason an asynchronous completion was rejected at a state-publication boundary.
public enum VaultStaleCompletionReason: Sendable, Equatable {
    case missingTicket
    case sessionClosed
    case sessionLocked(vaultID: UUID, root: URL, generation: UInt64)
    case sessionTransitioning(phase: VaultSessionPhase, generation: UInt64)
    case staleEpoch(ticketGeneration: UInt64, activeGeneration: UInt64)
    case wrongVault(ticketVaultID: UUID?, ticketRoot: URL?, activeVaultID: UUID, activeRoot: URL)
    case sessionMismatch(ticketSessionID: UUID, activeSessionID: UUID)
    case tokenMismatch(expectedToken: UUID, actualToken: UUID)
    case targetMismatch(expectedTargetID: UUID?, actualTargetID: UUID?)
    case contentChanged
}

public enum VaultStaleCompletionError: Error, Sendable, Equatable, LocalizedError {
    case rejected(kind: VaultCompletionKind, operation: String, reason: VaultStaleCompletionReason)

    public var errorDescription: String? {
        switch self {
        case .rejected(let kind, let operation, let reason):
            "Stale \(kind.rawValue) completion rejected for '\(operation)': \(String(describing: reason))."
        }
    }
}

public struct VaultStaleCompletionRecord: Sendable, Equatable {
    public let kind: VaultCompletionKind
    public let operation: String
    public let reason: VaultStaleCompletionReason
    public let ticketGeneration: UInt64
    public let activeGeneration: UInt64
}

/// Synchronously issues and revalidates `VaultCompletionTicket` tokens against `VaultAccessGate`
/// at asynchronous completion boundaries, even if cooperative task cancellation was ignored.
public struct VaultStaleResultGuard: Sendable {
    public let gate: VaultAccessGate

    public init(gate: VaultAccessGate) {
        self.gate = gate
    }

    public var acceptedCount: Int { gate.acceptedCompletionCount }
    public var rejectedCount: Int { gate.rejectedCompletionCount }
    public var rejectedRecords: [VaultStaleCompletionRecord] { gate.rejectedCompletionRecords }

    public func issueTicket(
        kind: VaultCompletionKind,
        lease: VaultSessionLease? = nil,
        token: UUID = UUID(),
        targetID: UUID? = nil,
        capturedText: String? = nil
    ) -> VaultCompletionTicket {
        gate.issueCompletionTicket(
            kind: kind,
            lease: lease,
            token: token,
            targetID: targetID,
            capturedText: capturedText
        )
    }

    public func validate(
        _ ticket: VaultCompletionTicket?,
        expectedToken: UUID? = nil,
        expectedTargetID: UUID? = nil,
        checkTargetID: Bool = false,
        currentText: String? = nil,
        operation: String? = nil
    ) -> Result<VaultSession?, VaultStaleCompletionError> {
        gate.validateCompletion(
            ticket,
            expectedToken: expectedToken,
            expectedTargetID: expectedTargetID,
            checkTargetID: checkTargetID,
            currentText: currentText,
            operation: operation
        )
    }

    public func isValid(
        _ ticket: VaultCompletionTicket?,
        expectedToken: UUID? = nil,
        expectedTargetID: UUID? = nil,
        checkTargetID: Bool = false,
        currentText: String? = nil,
        operation: String? = nil
    ) -> Bool {
        if case .success = validate(
            ticket,
            expectedToken: expectedToken,
            expectedTargetID: expectedTargetID,
            checkTargetID: checkTargetID,
            currentText: currentText,
            operation: operation
        ) {
            return true
        }
        return false
    }

    @discardableResult
    public func requireValid(
        _ ticket: VaultCompletionTicket?,
        expectedToken: UUID? = nil,
        expectedTargetID: UUID? = nil,
        checkTargetID: Bool = false,
        currentText: String? = nil,
        operation: String? = nil
    ) throws -> VaultSession? {
        try validate(
            ticket,
            expectedToken: expectedToken,
            expectedTargetID: expectedTargetID,
            checkTargetID: checkTargetID,
            currentText: currentText,
            operation: operation
        ).get()
    }
}

/// Decorates a `VaultContentStore` so every protected read and write revalidates its session lease
/// against `VaultAccessGate` at the moment synchronous I/O executes.
/// Manifest inspection (`inspectManifestData()`) remains available outside the protected content API
/// so a vault's `vault.json` can be inspected to open or unlock a session.
public final class GatedVaultContentStore: VaultContentStore, Sendable {
    public let base: any VaultContentStore
    public let root: URL
    public let gate: VaultAccessGate
    private let boundVaultID: Mutex<UUID?>
    private let leaseProvider: @Sendable () -> VaultSessionLease?
    private let willExecuteIO: (@Sendable (String) -> Void)?

    public init(
        base: any VaultContentStore,
        root: URL,
        vaultID: UUID? = nil,
        gate: VaultAccessGate,
        lease: VaultSessionLease? = nil,
        willExecuteIO: (@Sendable (String) -> Void)? = nil
    ) {
        self.base = base
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.gate = gate
        self.boundVaultID = Mutex(vaultID ?? lease?.vaultID)
        self.leaseProvider = { lease }
        self.willExecuteIO = willExecuteIO
    }

    public init(
        base: any VaultContentStore,
        root: URL,
        vaultID: UUID? = nil,
        gate: VaultAccessGate,
        leaseProvider: @escaping @Sendable () -> VaultSessionLease?,
        willExecuteIO: (@Sendable (String) -> Void)? = nil
    ) {
        self.base = base
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.gate = gate
        self.boundVaultID = Mutex(vaultID)
        self.leaseProvider = leaseProvider
        self.willExecuteIO = willExecuteIO
    }

    public var vaultID: UUID? {
        boundVaultID.withLock { $0 }
    }

    public func bindVaultID(_ id: UUID) {
        boundVaultID.withLock { $0 = id }
    }

    public func validateAccess(operation: String) throws {
        willExecuteIO?(operation)
        let targetVaultID = boundVaultID.withLock { $0 }
        try gate.validate(
            lease: leaseProvider(),
            targetRoot: root,
            targetVaultID: targetVaultID,
            operation: operation
        )
    }

    /// Reads `vault.json` for manifest inspection during vault open/unlock outside the protected content API.
    func inspectManifestData() throws -> Data {
        try base.read(at: "vault.json")
    }

    public func createDirectory(at path: String) throws {
        try validateAccess(operation: "createDirectory \(path)")
        try base.createDirectory(at: path)
    }

    public func read(at path: String) throws -> Data {
        try validateAccess(operation: "read \(path)")
        return try base.read(at: path)
    }

    public func changeToken(at path: String) throws -> VaultContentChangeToken? {
        try validateAccess(operation: "changeToken \(path)")
        let token = try base.changeToken(at: path)
        try validateAccess(operation: "changeToken.complete \(path)")
        return token
    }

    public func snapshot(at path: String) throws -> VaultContentSnapshot {
        try validateAccess(operation: "snapshot \(path)")
        return try base.snapshot(at: path)
    }

    public func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        try validateAccess(operation: "write \(path)")
        try base.write(data, at: path, condition: condition)
    }

    public func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        try validateAccess(operation: "move \(source) -> \(destination)")
        try base.move(from: source, to: destination, expected: expected)
    }

    public func delete(at path: String, expected: VaultContentSnapshot) throws {
        try validateAccess(operation: "delete \(path)")
        try base.delete(at: path, expected: expected)
    }
}

extension VaultStorageProvider {
    /// Returns a storage provider that wraps stores in `GatedVaultContentStore` bound to `gate` and `lease`.
    public func gated(
        by gate: VaultAccessGate,
        lease: VaultSessionLease?,
        vaultID: UUID? = nil,
        willExecuteIO: (@Sendable (String) -> Void)? = nil
    ) -> VaultStorageProvider {
        let underlying = self
        return VaultStorageProvider { root in
            let store = try underlying.makeStore(root: root)
            return GatedVaultContentStore(
                base: store,
                root: root,
                vaultID: vaultID ?? lease?.vaultID,
                gate: gate,
                lease: lease,
                willExecuteIO: willExecuteIO
            )
        }
    }
}
