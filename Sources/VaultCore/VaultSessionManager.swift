import Foundation

public enum VaultSessionPhase: String, Sendable, Equatable, CaseIterable {
    case closed
    case opening
    case open
    case locking
    case locked
    case unlocking
}

public struct VaultSession: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let vaultID: UUID
    public let root: URL
    public let vaultName: String
    public let generation: UInt64
    public var epoch: UInt64 { generation }

    public init(id: UUID = UUID(), vaultID: UUID, root: URL, vaultName: String? = nil, generation: UInt64) {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.id = id
        self.vaultID = vaultID
        self.root = normalizedRoot
        self.vaultName = vaultName ?? normalizedRoot.lastPathComponent
        self.generation = generation
    }
}

public enum VaultSessionState: Sendable, Equatable {
    case closed
    case opening(root: URL, generation: UInt64)
    case open(VaultSession)
    case locking(VaultSession)
    case locked(vaultID: UUID, root: URL, vaultName: String, generation: UInt64)
    case unlocking(vaultID: UUID, root: URL, vaultName: String, generation: UInt64)

    public var phase: VaultSessionPhase {
        switch self {
        case .closed: .closed
        case .opening: .opening
        case .open: .open
        case .locking: .locking
        case .locked: .locked
        case .unlocking: .unlocking
        }
    }

    public var activeSession: VaultSession? {
        if case .open(let session) = self { return session }
        return nil
    }

    public var root: URL? {
        switch self {
        case .closed: nil
        case .opening(let root, _): root
        case .open(let session), .locking(let session): session.root
        case .locked(_, let root, _, _), .unlocking(_, let root, _, _): root
        }
    }

    public var vaultID: UUID? {
        switch self {
        case .closed, .opening: nil
        case .open(let session), .locking(let session): session.vaultID
        case .locked(let vaultID, _, _, _), .unlocking(let vaultID, _, _, _): vaultID
        }
    }

    public var generation: UInt64 {
        switch self {
        case .closed: 0
        case .opening(_, let generation): generation
        case .open(let session), .locking(let session): session.generation
        case .locked(_, _, _, let generation), .unlocking(_, _, _, let generation): generation
        }
    }

    public var epoch: UInt64 { generation }

    public var isTransitioning: Bool {
        switch self {
        case .opening, .locking, .unlocking: true
        case .closed, .open, .locked: false
        }
    }
}

public enum VaultSessionError: Error, Sendable, Equatable, LocalizedError {
    case invalidTransition(from: VaultSessionPhase, action: String)
    case transitionInProgress(current: VaultSessionPhase, requested: String)
    case cancelled(action: String)
    case identityMismatch(expected: UUID, actual: UUID)
    case openFailed(root: URL, message: String)
    case unlockFailed(root: URL, message: String)
    case lockAborted(root: URL, message: String)
    case closeAborted(root: URL, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let action):
            "Cannot perform '\(action)' while vault session is \(from.rawValue)."
        case .transitionInProgress(let current, let requested):
            "Cannot start '\(requested)' while vault session is \(current.rawValue)."
        case .cancelled(let action):
            "Vault session '\(action)' was cancelled."
        case .identityMismatch(let expected, let actual):
            "Vault identity changed from \(expected.uuidString) to \(actual.uuidString)."
        case .openFailed(_, let message),
             .unlockFailed(_, let message),
             .lockAborted(_, let message),
             .closeAborted(_, let message):
            message
        }
    }
}

/// Manages the six-state vault session lifecycle (`closed`, `opening`, `open`, `locking`, `locked`, `unlocking`)
/// independently of SwiftUI and `AppModel`. Serializes transitions and publishes read-only state observations.
/// Note: Session locking is lifecycle state isolation, not cryptographic protection.
public actor VaultSessionManager {
    public nonisolated let accessGate: VaultAccessGate
    public private(set) var state: VaultSessionState = .closed
    public private(set) var generation: UInt64 = 0
    public private(set) var inFlightWaiterCount: Int = 0
    public var epoch: UInt64 { generation }

    private var observers: [UUID: AsyncStream<VaultSessionState>.Continuation] = [:]
    private var activeTransitionID: UUID?
    private var activeOpenTask: (id: UUID, root: URL, task: Task<VaultSession, Error>)?
    private var activeLockTask: (id: UUID, task: Task<Void, Error>)?
    private var activeUnlockTask: (id: UUID, task: Task<VaultSession, Error>)?
    private var activeCloseTask: (id: UUID, task: Task<Void, Error>)?

    public init(accessGate: VaultAccessGate = VaultAccessGate()) {
        self.accessGate = accessGate
    }

    public var currentSession: VaultSession? { state.activeSession }

    public nonisolated var currentLease: VaultSessionLease? { accessGate.currentLease }

    public func issueLease(for root: URL? = nil, vaultID: UUID? = nil) throws -> VaultSessionLease {
        try accessGate.issueLease(for: root, vaultID: vaultID)
    }

    /// Opens a vault session (if not already open for `root`), issues a session lease, and returns a
    /// `FileVaultRepository` whose storage and actor operations are gated by `accessGate` and `lease`.
    public func openRepository(
        root: URL,
        create: Bool = false,
        storageProvider: VaultStorageProvider = .plaintext,
        willExecuteIO: (@Sendable (String) -> Void)? = nil
    ) async throws -> (session: VaultSession, lease: VaultSessionLease, repository: FileVaultRepository) {
        let normalizedRoot = Self.normalize(root)
        let session = try await open(root: normalizedRoot) { targetRoot in
            if create {
                let initialized = try FileVaultRepository.open(root: targetRoot, create: true, storageProvider: storageProvider)
                return initialized.manifest.id
            }
            return try FileVaultRepository.inspectManifest(at: targetRoot, storageProvider: storageProvider).id
        }
        let lease = session.lease
        let repository = try FileVaultRepository.open(
            root: normalizedRoot,
            create: false,
            storageProvider: storageProvider,
            sessionLease: lease,
            accessGate: accessGate,
            willExecuteIO: willExecuteIO
        )
        return (session, lease, repository)
    }

    /// Returns a read-only stream of session states, immediately emitting the current state upon subscription
    /// followed by every subsequent state change in transition order.
    public func observations() -> AsyncStream<VaultSessionState> {
        let id = UUID()
        let initial = state
        return AsyncStream { continuation in
            continuation.yield(initial)
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func setState(_ next: VaultSessionState) {
        guard state != next else { return }
        state = next
        accessGate.updateState(next)
        for continuation in observers.values {
            continuation.yield(next)
        }
    }

    private static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static let defaultVaultLoader: @Sendable (URL) async throws -> UUID = { url in
        try FileVaultRepository.inspectManifest(at: url).id
    }

    /// Opens a vault from `.closed`. Duplicate requests for the same URL while `.opening` or `.open`
    /// coalesce or return the existing session without advancing the generation.
    @discardableResult
    public func open(
        root: URL,
        loader: @escaping @Sendable (URL) async throws -> UUID = VaultSessionManager.defaultVaultLoader
    ) async throws -> VaultSession {
        let targetRoot = Self.normalize(root)

        if activeCloseTask != nil {
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: "open")
        }

        switch state {
        case .open(let existing):
            if existing.root == targetRoot {
                return existing
            }
            throw VaultSessionError.invalidTransition(from: .open, action: "open")

        case .opening(let inFlightRoot, _):
            if inFlightRoot == targetRoot, let inFlight = activeOpenTask {
                return try await awaitOpenTask(inFlight.task, id: inFlight.id)
            }
            throw VaultSessionError.transitionInProgress(current: .opening, requested: "open")

        case .locking, .unlocking:
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: "open")

        case .locked:
            throw VaultSessionError.invalidTransition(from: .locked, action: "open")

        case .closed:
            if Task.isCancelled {
                throw VaultSessionError.cancelled(action: "open")
            }
            let transitionID = UUID()
            let candidateGeneration = generation &+ 1
            activeTransitionID = transitionID
            setState(.opening(root: targetRoot, generation: candidateGeneration))

            let task = Task<VaultSession, Error> {
                try Task.checkCancellation()
                let vaultID = try await loader(targetRoot)
                try Task.checkCancellation()
                return VaultSession(
                    id: UUID(),
                    vaultID: vaultID,
                    root: targetRoot,
                    vaultName: targetRoot.lastPathComponent,
                    generation: candidateGeneration
                )
            }
            activeOpenTask = (transitionID, targetRoot, task)
            return try await awaitOpenTask(task, id: transitionID)
        }
    }

    private func awaitOpenTask(_ task: Task<VaultSession, Error>, id: UUID) async throws -> VaultSession {
        inFlightWaiterCount += 1
        defer { inFlightWaiterCount -= 1 }
        do {
            let session = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { await self.handleCancellation(id: id) }
            }
            if activeTransitionID == id {
                activeTransitionID = nil
                activeOpenTask = nil
                generation = session.generation
                setState(.open(session))
            }
            guard case .open(let committed) = state else {
                throw VaultSessionError.cancelled(action: "open")
            }
            return committed
        } catch {
            let root = activeOpenTask?.root ?? state.root ?? URL(fileURLWithPath: "/")
            if activeTransitionID == id {
                activeTransitionID = nil
                activeOpenTask = nil
                setState(.closed)
            }
            if error is CancellationError || Task.isCancelled {
                throw VaultSessionError.cancelled(action: "open")
            }
            if let sessionError = error as? VaultSessionError {
                throw sessionError
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw VaultSessionError.openFailed(root: root, message: message)
        }
    }

    /// Transitions an `.open` session through `.locking` to `.locked`.
    /// Duplicate calls while `.locking` or `.locked` are coalesced or idempotent.
    public func lock(
        teardown: @escaping @Sendable (VaultSession) async throws -> Void = { _ in }
    ) async throws {
        if activeCloseTask != nil {
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: "lock")
        }

        switch state {
        case .locked:
            return

        case .locking:
            if let inFlight = activeLockTask {
                try await awaitLockTask(inFlight.task, id: inFlight.id)
                return
            }
            throw VaultSessionError.transitionInProgress(current: .locking, requested: "lock")

        case .opening, .unlocking:
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: "lock")

        case .closed:
            throw VaultSessionError.invalidTransition(from: .closed, action: "lock")

        case .open(let session):
            if Task.isCancelled {
                throw VaultSessionError.cancelled(action: "lock")
            }
            let transitionID = UUID()
            activeTransitionID = transitionID
            setState(.locking(session))

            let task = Task<Void, Error> {
                try Task.checkCancellation()
                try await teardown(session)
                try Task.checkCancellation()
            }
            activeLockTask = (transitionID, task)
            try await awaitLockTask(task, id: transitionID)
        }
    }

    private func awaitLockTask(_ task: Task<Void, Error>, id: UUID) async throws {
        guard case .locking(let session) = state else { return }
        inFlightWaiterCount += 1
        defer { inFlightWaiterCount -= 1 }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { await self.handleCancellation(id: id) }
            }
            if activeTransitionID == id {
                activeTransitionID = nil
                activeLockTask = nil
                setState(.locked(
                    vaultID: session.vaultID,
                    root: session.root,
                    vaultName: session.vaultName,
                    generation: session.generation
                ))
            }
            guard case .locked = state else {
                throw VaultSessionError.cancelled(action: "lock")
            }
        } catch {
            if activeTransitionID == id {
                activeTransitionID = nil
                activeLockTask = nil
                setState(.open(session))
            }
            if error is CancellationError || Task.isCancelled {
                throw VaultSessionError.cancelled(action: "lock")
            }
            if let sessionError = error as? VaultSessionError {
                throw sessionError
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw VaultSessionError.lockAborted(root: session.root, message: message)
        }
    }

    /// Transitions a `.locked` session through `.unlocking` to `.open` with a newly incremented generation.
    @discardableResult
    public func unlock(
        loader: @escaping @Sendable (URL) async throws -> UUID = VaultSessionManager.defaultVaultLoader
    ) async throws -> VaultSession {
        if activeCloseTask != nil {
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: "unlock")
        }

        switch state {
        case .unlocking:
            if let inFlight = activeUnlockTask {
                return try await awaitUnlockTask(inFlight.task, id: inFlight.id)
            }
            throw VaultSessionError.transitionInProgress(current: .unlocking, requested: "unlock")

        case .opening, .locking:
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: "unlock")

        case .closed, .open:
            throw VaultSessionError.invalidTransition(from: state.phase, action: "unlock")

        case .locked(let lockedVaultID, let root, let vaultName, let lockedGeneration):
            if Task.isCancelled {
                throw VaultSessionError.cancelled(action: "unlock")
            }
            let transitionID = UUID()
            let candidateGeneration = generation &+ 1
            activeTransitionID = transitionID
            setState(.unlocking(
                vaultID: lockedVaultID,
                root: root,
                vaultName: vaultName,
                generation: candidateGeneration
            ))

            let task = Task<VaultSession, Error> {
                try Task.checkCancellation()
                let resolvedID = try await loader(root)
                try Task.checkCancellation()
                guard resolvedID == lockedVaultID else {
                    throw VaultSessionError.identityMismatch(expected: lockedVaultID, actual: resolvedID)
                }
                return VaultSession(
                    id: UUID(),
                    vaultID: resolvedID,
                    root: root,
                    vaultName: vaultName,
                    generation: candidateGeneration
                )
            }
            activeUnlockTask = (transitionID, task)
            return try await awaitUnlockTask(
                task,
                id: transitionID,
                fallback: (lockedVaultID, root, vaultName, lockedGeneration)
            )
        }
    }

    private func awaitUnlockTask(
        _ task: Task<VaultSession, Error>,
        id: UUID,
        fallback: (vaultID: UUID, root: URL, vaultName: String, generation: UInt64)? = nil
    ) async throws -> VaultSession {
        inFlightWaiterCount += 1
        defer { inFlightWaiterCount -= 1 }
        let lockedFallback: (vaultID: UUID, root: URL, vaultName: String, generation: UInt64)? = fallback ?? {
            if case .unlocking(let vID, let root, let name, _) = state {
                return (vID, root, name, generation)
            }
            return nil
        }()

        do {
            let session = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { await self.handleCancellation(id: id) }
            }
            if activeTransitionID == id {
                activeTransitionID = nil
                activeUnlockTask = nil
                generation = session.generation
                setState(.open(session))
            }
            guard case .open(let committed) = state else {
                throw VaultSessionError.cancelled(action: "unlock")
            }
            return committed
        } catch {
            if activeTransitionID == id, let lockedFallback {
                activeTransitionID = nil
                activeUnlockTask = nil
                setState(.locked(
                    vaultID: lockedFallback.vaultID,
                    root: lockedFallback.root,
                    vaultName: lockedFallback.vaultName,
                    generation: lockedFallback.generation
                ))
            }
            if error is CancellationError || Task.isCancelled {
                throw VaultSessionError.cancelled(action: "unlock")
            }
            if let sessionError = error as? VaultSessionError {
                throw sessionError
            }
            let root = lockedFallback?.root ?? state.root ?? URL(fileURLWithPath: "/")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw VaultSessionError.unlockFailed(root: root, message: message)
        }
    }

    /// Closes an `.open` or `.locked` session and returns to `.closed`.
    /// Calling `close()` when already `.closed` is a no-op.
    public func close(
        teardown: @escaping @Sendable (VaultSession?) async throws -> Void = { _ in }
    ) async throws {
        if let inFlightClose = activeCloseTask {
            try await inFlightClose.task.value
            return
        }

        switch state {
        case .closed:
            return

        case .opening, .locking, .unlocking:
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: "close")

        case .locked(_, let root, _, _):
            if Task.isCancelled {
                throw VaultSessionError.cancelled(action: "close")
            }
            let transitionID = UUID()
            let task = Task<Void, Error> {
                try Task.checkCancellation()
                try await teardown(nil)
                try Task.checkCancellation()
            }
            activeCloseTask = (transitionID, task)
            do {
                try await task.value
                activeCloseTask = nil
                setState(.closed)
            } catch {
                activeCloseTask = nil
                if error is CancellationError || Task.isCancelled {
                    throw VaultSessionError.cancelled(action: "close")
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw VaultSessionError.closeAborted(root: root, message: message)
            }

        case .open(let session):
            if Task.isCancelled {
                throw VaultSessionError.cancelled(action: "close")
            }
            let transitionID = UUID()
            let task = Task<Void, Error> {
                try Task.checkCancellation()
                try await teardown(session)
                try Task.checkCancellation()
            }
            activeCloseTask = (transitionID, task)
            do {
                try await task.value
                activeCloseTask = nil
                setState(.closed)
            } catch {
                activeCloseTask = nil
                if error is CancellationError || Task.isCancelled {
                    throw VaultSessionError.cancelled(action: "close")
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw VaultSessionError.closeAborted(root: session.root, message: message)
            }
        }
    }

    /// Explicitly cancels an in-flight `.opening`, `.locking`, or `.unlocking` transition.
    public func cancelActiveTransition() {
        guard let id = activeTransitionID else { return }
        handleCancellation(id: id)
    }

    private func handleCancellation(id: UUID) {
        guard activeTransitionID == id else { return }
        activeTransitionID = nil

        if let openTask = activeOpenTask, openTask.id == id {
            openTask.task.cancel()
            activeOpenTask = nil
            setState(.closed)
            return
        }

        if let lockTask = activeLockTask, lockTask.id == id {
            lockTask.task.cancel()
            activeLockTask = nil
            if case .locking(let session) = state {
                setState(.open(session))
            }
            return
        }

        if let unlockTask = activeUnlockTask, unlockTask.id == id {
            unlockTask.task.cancel()
            activeUnlockTask = nil
            if case .unlocking(let vaultID, let root, let vaultName, _) = state {
                setState(.locked(vaultID: vaultID, root: root, vaultName: vaultName, generation: generation))
            }
            return
        }
    }
}
