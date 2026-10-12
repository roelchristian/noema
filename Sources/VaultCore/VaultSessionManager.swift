import Foundation
import Synchronization
import NativeAuthentication

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

    public var sessionID: UUID? {
        switch self {
        case .open(let session), .locking(let session): session.id
        case .closed, .opening, .locked, .unlocking: nil
        }
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
    case unexpectedFinalState(action: String, expected: VaultSessionPhase, actual: VaultSessionPhase)
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
        case .unexpectedFinalState(let action, let expected, let actual):
            "Vault session '\(action)' finished in \(actual.rawValue); expected \(expected.rawValue)."
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
    public nonisolated let quiescenceCoordinator: VaultSaveQuiescenceCoordinator
    public private(set) var state: VaultSessionState = .closed
    public private(set) var generation: UInt64 = 0
    public private(set) var inFlightWaiterCount: Int = 0
    public var epoch: UInt64 { generation }

    private let authenticator: any NativeAuthenticating
    private let accessPolicy: VaultAccessPolicyStore
    private let beforeAccessCommit: (@Sendable (VaultSession) async -> Void)?
    private let authenticationPending = Mutex(false)
    private var authenticationObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private struct AccessAttempt {
        let id: UUID
        let root: URL
        let vaultID: UUID
        let action: String
        let state: VaultSessionState
        let generation: UInt64
        let policy: VaultAccessPolicySnapshot
        let task: Task<Void, Never>
        let completion: AsyncThrowingStream<Void, Error>.Continuation
    }
    private var activeAccessAttempt: AccessAttempt?

    private var observers: [UUID: AsyncStream<VaultSessionState>.Continuation] = [:]
    private struct AccessCommitBinding: Sendable {
        let root: URL
        let vaultID: UUID
        let policy: VaultAccessPolicySnapshot
        let storageProvider: VaultStorageProvider
    }
    private var activeTransitionID: UUID?
    private var activeOpenTask: (id: UUID, root: URL, task: Task<VaultSession, Error>, binding: AccessCommitBinding?)?
    private var activeLockTask: (id: UUID, task: Task<Void, Error>)?
    private var activeUnlockTask: (id: UUID, task: Task<VaultSession, Error>, binding: AccessCommitBinding?)?
    private var activeCloseTask: (id: UUID, task: Task<Void, Error>)?

    public init(accessGate: VaultAccessGate = VaultAccessGate()) {
        self.accessGate = accessGate
        self.quiescenceCoordinator = VaultSaveQuiescenceCoordinator(accessGate: accessGate)
        self.authenticator = LocalNativeAuthenticator()
        self.accessPolicy = .standard
        self.beforeAccessCommit = nil
    }

    /// Deterministic fixtures cannot be selected by production clients.
    init(
        accessGate: VaultAccessGate = VaultAccessGate(),
        authenticator: any NativeAuthenticating,
        accessPolicy: VaultAccessPolicyStore,
        beforeAccessCommit: (@Sendable (VaultSession) async -> Void)? = nil
    ) {
        self.accessGate = accessGate
        self.quiescenceCoordinator = VaultSaveQuiescenceCoordinator(accessGate: accessGate)
        self.authenticator = authenticator
        self.accessPolicy = accessPolicy
        self.beforeAccessCommit = beforeAccessCommit
    }

    public nonisolated var isAuthenticationPending: Bool {
        authenticationPending.withLock { $0 }
    }

    public nonisolated func accessAuthenticationRequired(for vaultID: UUID) -> Bool {
        accessPolicy.snapshot(for: vaultID).authenticationRequired
    }

    public func authenticationObservations() -> AsyncStream<Bool> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(isAuthenticationPending)
            authenticationObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeAuthenticationObserver(id) }
            }
        }
    }

    private func removeAuthenticationObserver(_ id: UUID) {
        authenticationObservers.removeValue(forKey: id)
    }

    private func setAuthenticationPending(_ pending: Bool) {
        authenticationPending.withLock { $0 = pending }
        for continuation in authenticationObservers.values { continuation.yield(pending) }
    }

    /// Invalidates admission before signalling cancellation. Late native results are ignored.
    private func invalidateAccessAttempt() {
        guard let attempt = activeAccessAttempt else { return }
        activeAccessAttempt = nil
        setAuthenticationPending(false)
        attempt.completion.finish(throwing: VaultSessionError.cancelled(action: attempt.action))
        attempt.task.cancel()
    }

    private func cancelAccessAttempt(id: UUID) {
        guard activeAccessAttempt?.id == id else { return }
        invalidateAccessAttempt()
    }

    @discardableResult
    private func authenticateAdmission(
        root: URL,
        vaultID: UUID,
        action: String,
        purpose: NativeAuthenticationPurpose,
        storageProvider: VaultStorageProvider,
        alwaysAuthenticate: Bool = false
    ) async throws -> VaultAccessPolicySnapshot {
        guard activeAccessAttempt == nil else {
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: action)
        }
        if Task.isCancelled { throw VaultSessionError.cancelled(action: action) }
        let policy = accessPolicy.snapshot(for: vaultID)
        let expectedState = state
        let expectedGeneration = generation
        if policy.authenticationRequired || alwaysAuthenticate {
            let id = UUID()
            let (stream, completion) = AsyncThrowingStream<Void, Error>.makeStream()
            let task = Task { [authenticator] in
                do {
                    try Task.checkCancellation()
                    try await authenticator.authenticate(for: purpose)
                    try Task.checkCancellation()
                    completion.yield(())
                    completion.finish()
                } catch {
                    completion.finish(throwing: error)
                }
            }
            activeAccessAttempt = AccessAttempt(
                id: id, root: root, vaultID: vaultID, action: action,
                state: expectedState, generation: expectedGeneration, policy: policy,
                task: task, completion: completion
            )
            setAuthenticationPending(true)
            do {
                var iterator = stream.makeAsyncIterator()
                _ = try await withTaskCancellationHandler {
                    try await iterator.next()
                } onCancel: {
                    Task { await self.cancelAccessAttempt(id: id) }
                }
                try Task.checkCancellation()
                guard let attempt = activeAccessAttempt, attempt.id == id,
                      attempt.root == root, attempt.vaultID == vaultID,
                      attempt.action == action, attempt.state == state,
                      attempt.generation == generation, attempt.policy == accessPolicy.snapshot(for: vaultID) else {
                    throw VaultSessionError.cancelled(action: action)
                }
                // Consume the attempt on this actor; it never leaves the manager as a grant.
                activeAccessAttempt = nil
                setAuthenticationPending(false)
            } catch {
                cancelAccessAttempt(id: id)
                if error is CancellationError || Task.isCancelled
                    || (error as? NativeAuthenticationError) == .cancelled
                    || error is VaultSessionError {
                    throw VaultSessionError.cancelled(action: action)
                }
                if let error = error as? NativeAuthenticationError { throw error }
                throw NativeAuthenticationError.failed
            }
        }
        guard state == expectedState, generation == expectedGeneration,
              Self.normalize(root) == root, accessPolicy.snapshot(for: vaultID) == policy else {
            throw VaultSessionError.cancelled(action: action)
        }
        let currentID = try FileVaultRepository.inspectManifest(at: root, storageProvider: storageProvider).id
        guard currentID == vaultID else {
            throw VaultSessionError.identityMismatch(expected: vaultID, actual: currentID)
        }
        if Task.isCancelled { throw VaultSessionError.cancelled(action: action) }
        guard accessPolicy.snapshot(for: vaultID) == policy else { throw VaultSessionError.cancelled(action: action) }
        return policy
    }

    private func validateCommitBinding(_ binding: AccessCommitBinding?, session: VaultSession, action: String) throws {
        guard let binding else { return } // Internal fixture loaders have no production admission.
        guard session.root == binding.root, Self.normalize(binding.root) == binding.root,
              session.vaultID == binding.vaultID else {
            throw VaultSessionError.cancelled(action: action)
        }
        let currentID = try FileVaultRepository.inspectManifest(at: binding.root, storageProvider: binding.storageProvider).id
        guard currentID == binding.vaultID else {
            throw VaultSessionError.identityMismatch(expected: binding.vaultID, actual: currentID)
        }
        if Task.isCancelled { throw VaultSessionError.cancelled(action: action) }
        guard accessPolicy.snapshot(for: binding.vaultID) == binding.policy else {
            throw VaultSessionError.cancelled(action: action)
        }
    }

    private func commitAccessSession(
        _ session: VaultSession,
        binding: AccessCommitBinding?,
        action: String,
        commit: () -> Void
    ) throws {
        // Metadata validation happens before the policy lock; no storage or await occurs below it.
        try validateCommitBinding(binding, session: session, action: action)
        if let binding {
            try accessPolicy.withUnchangedSnapshot(for: binding.vaultID, matching: binding.policy, action: action) {
                if Task.isCancelled { throw VaultSessionError.cancelled(action: action) }
                commit()
            }
        } else {
            commit() // Internal loader fixtures only.
        }
    }

    /// Changing either direction requires a fresh native attempt for the exact active session.
    public func setAccessAuthenticationRequired(
        _ required: Bool,
        expectedSession: VaultSession,
        storageProvider: VaultStorageProvider = .plaintext
    ) async throws {
        guard state == .open(expectedSession), activeCloseTask == nil else {
            throw VaultSessionError.cancelled(action: "changeVaultAccessPolicy")
        }
        guard accessPolicy.snapshot(for: expectedSession.vaultID).authenticationRequired != required else { return }
        let admittedPolicy = try await authenticateAdmission(
            root: expectedSession.root, vaultID: expectedSession.vaultID,
            action: "changeVaultAccessPolicy", purpose: .changeVaultAccessPolicy,
            storageProvider: storageProvider, alwaysAuthenticate: true
        )
        try accessPolicy.setRequired(required, for: expectedSession.vaultID, matching: admittedPolicy)
    }

    /// Registers an opt-in only for the fresh UUID created by the existing staged publisher.
    /// No API accepts an arbitrary UUID for unauthenticated preference writes.
    public func createVault(
        parent: URL,
        name: String,
        encryptionRequested: Bool,
        accessAuthenticationRequested: Bool = false,
        storageProvider: VaultStorageProvider = .plaintext
    ) async throws -> URL {
        let root = try await FileVaultRepository.createNewVault(
            parent: parent, name: name, encryptionRequested: encryptionRequested,
            storageProvider: storageProvider
        )
        let vaultID = try FileVaultRepository.inspectManifest(at: root, storageProvider: storageProvider).id
        if accessAuthenticationRequested { accessPolicy.setRequired(true, for: vaultID) }
        return root
    }

    public var currentSession: VaultSession? { state.activeSession }

    public nonisolated var currentLease: VaultSessionLease? { accessGate.currentLease }

    public nonisolated var admissionBarrier: VaultLockAdmissionBarrier { accessGate.admissionBarrier }

    public nonisolated var staleResultGuard: VaultStaleResultGuard { accessGate.staleResultGuard }

    public nonisolated func issueCompletionTicket(
        kind: VaultCompletionKind,
        lease: VaultSessionLease? = nil,
        token: UUID = UUID(),
        targetID: UUID? = nil,
        capturedText: String? = nil
    ) -> VaultCompletionTicket {
        accessGate.staleResultGuard.issueTicket(
            kind: kind,
            lease: lease,
            token: token,
            targetID: targetID,
            capturedText: capturedText
        )
    }

    public nonisolated func operationRegistrySnapshot() -> VaultOperationRegistrySnapshot {
        accessGate.registrySnapshot()
    }

    public nonisolated func admitOperation(
        _ operation: String,
        lease: VaultSessionLease? = nil,
        targetRoot: URL? = nil,
        targetVaultID: UUID? = nil,
        id: UUID = UUID()
    ) throws -> VaultOperationRegistration {
        try accessGate.admitOperation(
            operation: operation,
            lease: lease,
            targetRoot: targetRoot,
            targetVaultID: targetVaultID,
            id: id
        )
    }

    public nonisolated func withAdmittedOperation<T: Sendable>(
        _ operation: String,
        lease: VaultSessionLease? = nil,
        targetRoot: URL? = nil,
        targetVaultID: UUID? = nil,
        id: UUID = UUID(),
        body: @Sendable (VaultOperationRegistration) async throws -> T
    ) async throws -> T {
        try await accessGate.admissionBarrier.withAdmittedOperation(
            operation,
            lease: lease,
            targetRoot: targetRoot,
            targetVaultID: targetVaultID,
            id: id,
            body: body
        )
    }

    public func awaitAdmittedOperations(forSessionID sessionID: UUID? = nil) async throws {
        try await accessGate.awaitInFlightOperations(forSessionID: sessionID)
    }

    public func issueLease(for root: URL? = nil, vaultID: UUID? = nil) throws -> VaultSessionLease {
        try accessGate.issueLease(for: root, vaultID: vaultID)
    }

    /// Opens a vault session (if not already open for `root`), issues a session lease, and returns a
    /// `FileVaultRepository` whose storage and actor operations are gated by `accessGate` and `lease`.
    private var creationInitializationInProgress = false

    public func openRepository(
        root: URL,
        create: Bool = false,
        storageProvider: VaultStorageProvider = .plaintext,
        willExecuteIO: (@Sendable (String) -> Void)? = nil
    ) async throws -> (session: VaultSession, lease: VaultSessionLease, repository: FileVaultRepository) {
        let normalizedRoot = Self.normalize(root)
        if Task.isCancelled { throw VaultSessionError.cancelled(action: "open") }
        // Existing vaults never initialize directories or open content before admission.
        // Reject incompatible lifecycle requests before initializing a fresh canonical root.
        if create {
            guard !creationInitializationInProgress, activeCloseTask == nil else {
                throw VaultSessionError.transitionInProgress(current: state.phase, requested: "open")
            }
            switch state {
            case .closed:
                if let pending = activeAccessAttempt, pending.root != normalizedRoot { invalidateAccessAttempt() }
                guard activeAccessAttempt == nil else {
                    throw VaultSessionError.transitionInProgress(current: state.phase, requested: "open")
                }
                if try FileVaultRepository.preflightOpen(root: normalizedRoot, create: true, storageProvider: storageProvider) == nil {
                    creationInitializationInProgress = true
                    defer { creationInitializationInProgress = false }
                    try await FileVaultRepository.initializeSchema5(root: normalizedRoot, storageProvider: storageProvider)
                }
            case .open(let existing) where existing.root == normalizedRoot:
                break
            case .opening(let pendingRoot, _) where pendingRoot == normalizedRoot:
                break
            default:
                throw VaultSessionError.invalidTransition(from: state.phase, action: "open")
            }
        }
        let session = try await open(root: normalizedRoot, storageProvider: storageProvider)
        let lease = session.lease
        do {
            let repository = try FileVaultRepository.open(
                root: normalizedRoot,
                create: false,
                storageProvider: storageProvider,
                sessionLease: lease,
                accessGate: accessGate,
                willExecuteIO: willExecuteIO
            )
            return (session, lease, repository)
        } catch {
            // Construction happens synchronously on this actor after open commits. Revoke
            // that session if construction fails, so callers never receive a half-open vault.
            if state == .open(session) { setState(.closed) }
            if let sessionError = error as? VaultSessionError { throw sessionError }
            throw VaultSessionError.openFailed(root: normalizedRoot, message: error.localizedDescription)
        }
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

    static let defaultVaultLoader: @Sendable (URL) async throws -> UUID = { url in
        try FileVaultRepository.inspectManifest(at: url).id
    }

    /// Supported production access always inspects identity and enforces the per-Mac policy.
    @discardableResult
    public func open(root: URL, storageProvider: VaultStorageProvider = .plaintext) async throws -> VaultSession {
        if Task.isCancelled { throw VaultSessionError.cancelled(action: "open") }
        let targetRoot = Self.normalize(root)
        if case .open(let existing) = state, existing.root == targetRoot { return existing }
        if case .opening(let pendingRoot, _) = state, pendingRoot == targetRoot {
            return try await open(root: targetRoot, loader: { url in
                try FileVaultRepository.inspectManifest(at: url, storageProvider: storageProvider).id
            })
        }
        guard state == .closed, activeCloseTask == nil else {
            throw VaultSessionError.invalidTransition(from: state.phase, action: "open")
        }
        if let pending = activeAccessAttempt, pending.root != targetRoot { invalidateAccessAttempt() }
        let vaultID = try FileVaultRepository.inspectManifest(at: targetRoot, storageProvider: storageProvider).id
        let admittedPolicy = try await authenticateAdmission(
            root: targetRoot, vaultID: vaultID, action: "open", purpose: .openVault,
            storageProvider: storageProvider
        )
        return try await openTransition(root: targetRoot, loader: { url in
            let currentID = try FileVaultRepository.inspectManifest(at: url, storageProvider: storageProvider).id
            guard currentID == vaultID else { throw VaultSessionError.identityMismatch(expected: vaultID, actual: currentID) }
            return currentID
        }, binding: AccessCommitBinding(root: targetRoot, vaultID: vaultID, policy: admittedPolicy, storageProvider: storageProvider))
    }

    /// Opens a vault from `.closed`. Duplicate requests for the same URL while `.opening` or `.open`
    /// coalesce or return the existing session without advancing the generation.
    @discardableResult
    func open(
        root: URL,
        loader: @escaping @Sendable (URL) async throws -> UUID
    ) async throws -> VaultSession {
        try await openTransition(root: root, loader: loader)
    }

    private func openTransition(
        root: URL,
        loader: @escaping @Sendable (URL) async throws -> UUID,
        binding: AccessCommitBinding? = nil
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
            activeOpenTask = (transitionID, targetRoot, task, binding)
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
            if activeTransitionID == id, activeOpenTask?.binding != nil, let beforeAccessCommit {
                await beforeAccessCommit(session)
            }
            if Task.isCancelled { throw VaultSessionError.cancelled(action: "open") }
            if activeTransitionID == id {
                try commitAccessSession(session, binding: activeOpenTask?.binding, action: "open") {
                    activeTransitionID = nil
                    activeOpenTask = nil
                    generation = session.generation
                    setState(.open(session))
                }
            }
            guard state == .open(session), case .open(let committed) = state else {
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
        expectedSession: VaultSession? = nil,
        teardown: @escaping @Sendable (VaultSession) async throws -> Void = { _ in }
    ) async throws {
        if let expectedSession, state != .open(expectedSession) {
            if state.isTransitioning {
                throw VaultSessionError.transitionInProgress(current: state.phase, requested: "lock")
            }
            throw VaultSessionError.cancelled(action: "lock")
        }
        invalidateAccessAttempt()
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
                try await accessGate.awaitInFlightOperations(forSessionID: session.id)
                try Task.checkCancellation()
            }
            activeLockTask = (transitionID, task)
            try await awaitLockTask(task, id: transitionID)
        }
    }

    /// Locks the active session using `quiescenceCoordinator` to drain in-flight saves, autosaves,
    /// LCC updates, and source imports/downloads, preserving unsaved edits to `recovery` where needed.
    /// On unrecoverable quiescence failure, rolls back to `.open` and throws `VaultSessionError.lockAborted`
    /// without falsely publishing `.locked`.
    @discardableResult
    public func lockWithQuiescence(
        repository: FileVaultRepository,
        recovery: RecoveryStore?,
        pendingState: VaultPendingEditorState = VaultPendingEditorState(),
        cancelPreCommitSaves: Bool = false,
        teardown: @escaping @Sendable (VaultSession, VaultQuiescenceReport) async throws -> Void = { _, _ in }
    ) async throws -> VaultQuiescenceReport? {
        let reportBox = Mutex<VaultQuiescenceReport?>(nil)
        try await lock { [quiescenceCoordinator] session in
            let report = try await quiescenceCoordinator.quiesceForLock(
                session: session,
                repository: repository,
                recovery: recovery,
                pendingState: pendingState,
                cancelPreCommitSaves: cancelPreCommitSaves
            )
            try await repository.checkpointPageStorage()
            try await teardown(session, report)
            reportBox.withLock { $0 = report }
        }
        return reportBox.withLock { $0 }
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
            guard state == .locked(vaultID: session.vaultID, root: session.root, vaultName: session.vaultName, generation: session.generation) else {
                throw VaultSessionError.cancelled(action: "lock")
            }
        } catch {
            if activeTransitionID == id {
                activeTransitionID = nil
                activeLockTask = nil
                setState(.open(session))
            }
            if error is CancellationError
                || Task.isCancelled
                || (error as? VaultOperationAdmissionError) == .cancelled(operation: "awaitInFlightOperations") {
                throw VaultSessionError.cancelled(action: "lock")
            }
            if let sessionError = error as? VaultSessionError {
                throw sessionError
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw VaultSessionError.lockAborted(root: session.root, message: message)
        }
    }

    @discardableResult
    public func unlock(storageProvider: VaultStorageProvider = .plaintext) async throws -> VaultSession {
        if Task.isCancelled { throw VaultSessionError.cancelled(action: "unlock") }
        if case .unlocking = state {
            return try await unlock(storageProvider: storageProvider, loader: { url in
                try FileVaultRepository.inspectManifest(at: url, storageProvider: storageProvider).id
            })
        }
        guard case .locked(let vaultID, let root, _, _) = state, activeCloseTask == nil else {
            throw VaultSessionError.invalidTransition(from: state.phase, action: "unlock")
        }
        let inspectedID = try FileVaultRepository.inspectManifest(at: root, storageProvider: storageProvider).id
        guard inspectedID == vaultID else { throw VaultSessionError.identityMismatch(expected: vaultID, actual: inspectedID) }
        let admittedPolicy = try await authenticateAdmission(
            root: root, vaultID: vaultID, action: "unlock", purpose: .unlockVault,
            storageProvider: storageProvider
        )
        return try await unlockTransition(storageProvider: storageProvider, loader: { url in
            try FileVaultRepository.inspectManifest(at: url, storageProvider: storageProvider).id
        }, binding: AccessCommitBinding(root: root, vaultID: vaultID, policy: admittedPolicy, storageProvider: storageProvider))
    }

    /// Transitions a `.locked` session through `.unlocking` to `.open` with a newly incremented generation.
    @discardableResult
    func unlock(
        storageProvider: VaultStorageProvider = .plaintext,
        loader: @escaping @Sendable (URL) async throws -> UUID
    ) async throws -> VaultSession {
        try await unlockTransition(storageProvider: storageProvider, loader: loader)
    }

    private func unlockTransition(
        storageProvider: VaultStorageProvider,
        loader: @escaping @Sendable (URL) async throws -> UUID,
        binding: AccessCommitBinding? = nil
    ) async throws -> VaultSession {
        let effectiveLoader = loader
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
                let resolvedID = try await effectiveLoader(root)
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
            activeUnlockTask = (transitionID, task, binding)
            return try await awaitUnlockTask(
                task,
                id: transitionID,
                fallback: (lockedVaultID, root, vaultName, lockedGeneration)
            )
        }
    }

    /// Unlocks a `.locked` session, issues a fresh session lease, and constructs a `FileVaultRepository`
    /// gated by `accessGate` and `lease`. Rolls back to `.locked` if opening or validation fails.
    public func unlockRepository(
        root: URL? = nil,
        storageProvider: VaultStorageProvider = .plaintext,
        willExecuteIO: (@Sendable (String) -> Void)? = nil
    ) async throws -> (session: VaultSession, lease: VaultSessionLease, repository: FileVaultRepository) {
        guard case .locked(let lockedVaultID, let lockedRoot, let lockedName, let lockedGeneration) = state else {
            throw VaultSessionError.invalidTransition(from: state.phase, action: "unlock")
        }
        let accessRoot = root ?? lockedRoot
        if Task.isCancelled { throw VaultSessionError.cancelled(action: "unlock") }
        // Preserve missing-folder/provider diagnostics before rejecting a different candidate root.
        // This reads identity metadata only, never Wiki, Sources, local index or recovery content.
        let candidateID = try FileVaultRepository.inspectManifest(at: accessRoot, storageProvider: storageProvider).id
        guard Self.normalize(accessRoot) == lockedRoot else {
            throw VaultSessionError.cancelled(action: "unlock")
        }
        guard candidateID == lockedVaultID else {
            throw VaultSessionError.identityMismatch(expected: lockedVaultID, actual: candidateID)
        }
        let session = try await unlock(storageProvider: storageProvider)
        let lease = session.lease
        do {
            let gatedProvider = storageProvider.gated(
                by: accessGate,
                lease: lease,
                vaultID: session.vaultID,
                willExecuteIO: willExecuteIO
            )
            let repository = try FileVaultRepository.open(
                root: accessRoot,
                create: false,
                storageProvider: gatedProvider,
                sessionLease: lease,
                accessGate: accessGate,
                willExecuteIO: willExecuteIO
            )
            return (session, lease, repository)
        } catch {
            if state == .open(session) {
                setState(.locked(
                    vaultID: lockedVaultID,
                    root: lockedRoot,
                    vaultName: lockedName,
                    generation: lockedGeneration
                ))
            }
            if let sessionError = error as? VaultSessionError {
                throw sessionError
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw VaultSessionError.unlockFailed(root: lockedRoot, message: message)
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
            if activeTransitionID == id, activeUnlockTask?.binding != nil, let beforeAccessCommit {
                await beforeAccessCommit(session)
            }
            if Task.isCancelled { throw VaultSessionError.cancelled(action: "unlock") }
            if activeTransitionID == id {
                try commitAccessSession(session, binding: activeUnlockTask?.binding, action: "unlock") {
                    activeTransitionID = nil
                    activeUnlockTask = nil
                    generation = session.generation
                    setState(.open(session))
                }
            }
            guard state == .open(session), case .open(let committed) = state else {
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
    /// Calling `close()` when already `.closed` also cancels any pending access attempt.
    public func close(
        expectedSession: VaultSession? = nil,
        teardown: @escaping @Sendable (VaultSession?) async throws -> Void = { _ in }
    ) async throws {
        if let expectedSession, state != .open(expectedSession) {
            if state.isTransitioning {
                throw VaultSessionError.transitionInProgress(current: state.phase, requested: "close")
            }
            throw VaultSessionError.cancelled(action: "close")
        }
        invalidateAccessAttempt()
        if let inFlightClose = activeCloseTask {
            try await awaitCloseTask(inFlightClose.task)
            return
        }

        switch state {
        case .closed:
            return
        case .opening, .locking, .unlocking:
            throw VaultSessionError.transitionInProgress(current: state.phase, requested: "close")
        case .locked, .open:
            if Task.isCancelled { throw VaultSessionError.cancelled(action: "close") }
            let previous = state
            let transitionID = UUID()
            // The shared task includes both teardown and the state commit. Every coalesced
            // caller receives the same typed error and can only succeed after `.closed`.
            let task = Task<Void, Error> {
                try await self.finishClose(previous: previous, teardown: teardown)
            }
            activeCloseTask = (transitionID, task)
            try await awaitCloseTask(task)
        }
    }

    private func finishClose(
        previous: VaultSessionState,
        teardown: @escaping @Sendable (VaultSession?) async throws -> Void
    ) async throws {
        defer { activeCloseTask = nil }
        do {
            try Task.checkCancellation()
            try await teardown(previous.activeSession)
            try Task.checkCancellation()
            setState(.closed)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw VaultSessionError.cancelled(action: "close")
            }
            if let sessionError = error as? VaultSessionError { throw sessionError }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw VaultSessionError.closeAborted(root: previous.root!, message: message)
        }
    }

    private func awaitCloseTask(_ task: Task<Void, Error>) async throws {
        inFlightWaiterCount += 1
        defer { inFlightWaiterCount -= 1 }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard state == .closed else {
            throw VaultSessionError.unexpectedFinalState(action: "close", expected: .closed, actual: state.phase)
        }
    }

    /// Cancels only pending native admission, without cancelling subsequent resource reconstruction.
    @discardableResult
    public func cancelAuthentication() -> Bool {
        guard activeAccessAttempt != nil else { return false }
        invalidateAccessAttempt()
        return true
    }

    /// Explicitly cancels an in-flight `.opening`, `.locking`, or `.unlocking` transition.
    public func cancelActiveTransition() {
        invalidateAccessAttempt()
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
