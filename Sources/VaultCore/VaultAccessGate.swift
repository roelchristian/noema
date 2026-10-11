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

/// Synchronously revalidates session leases when protected storage or repository I/O executes.
public final class VaultAccessGate: Sendable {
    private struct GateState: Sendable {
        var sessionState: VaultSessionState
        var highestGeneration: UInt64
    }

    private let state: Mutex<GateState>

    public init(initialState: VaultSessionState = .closed) {
        self.state = Mutex(GateState(sessionState: initialState, highestGeneration: initialState.generation))
    }

    public var currentState: VaultSessionState {
        state.withLock { $0.sessionState }
    }

    public var currentLease: VaultSessionLease? {
        state.withLock { $0.sessionState.activeSession?.lease }
    }

    public func updateState(_ next: VaultSessionState) {
        state.withLock { gate in
            gate.sessionState = next
            if next.generation > gate.highestGeneration {
                gate.highestGeneration = next.generation
            }
        }
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
