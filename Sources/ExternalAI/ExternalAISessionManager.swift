import Foundation
import Synchronization
import VaultCore

public enum ExternalAISessionState: String, Sendable, Equatable {
    case unauthorized, authorising, authorized, expired, revoked
}

public enum ExternalAIRevocationReason: Sendable {
    case explicit, vaultChanged, credentialChanged, deviceSleep, screenLocked, applicationTermination
}

/// Session authority is checked against the synchronous D02 access gate, never against a
/// delayed UI observation. Capability identity, credential version and both deadlines must match.
public actor ExternalAISessionManager {
    private let broker: ExternalAICredentialBroker
    private let authenticator: any ExternalAIAuthenticating
    private let gate: VaultAccessGate
    private nonisolated let registry: ExternalAIAuthorizationRegistry
    private let notifications: ExternalAISystemObservations
    private var authentication: (epoch: UInt64, authority: ExternalAIVaultAuthority,
                                 version: UUID, task: Task<Void, Error>)?
    private var credentialObservation: Task<UUID, Never>?
    private var gateObservation: UUID?
    private var expiryTask: Task<Void, Never>?
    private var grantedCredentialCancellation: UUID?

    /// Production callers cannot substitute authentication, freeze deadlines or disable
    /// native revocation notifications. Those controls belong to internal test injection.
    public init(accessGate: VaultAccessGate, credentialBroker: ExternalAICredentialBroker,
                policy: ExternalAISessionPolicy = .default) {
        gate = accessGate
        broker = credentialBroker
        authenticator = LocalExternalAIAuthenticator()
        registry = ExternalAIAuthorizationRegistry(gate: accessGate, policy: policy, now: { Date() })
        notifications = ExternalAISystemObservations(registry: registry, enabled: true)
    }

    init(
        accessGate: VaultAccessGate, credentialBroker: ExternalAICredentialBroker,
        authenticator: any ExternalAIAuthenticating,
        policy: ExternalAISessionPolicy = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        observeSystemEvents: Bool = true
    ) {
        gate = accessGate
        broker = credentialBroker
        self.authenticator = authenticator
        registry = ExternalAIAuthorizationRegistry(gate: accessGate, policy: policy, now: now)
        notifications = ExternalAISystemObservations(registry: registry, enabled: observeSystemEvents)
    }

    deinit {
        authentication?.task.cancel()
        expiryTask?.cancel()
        if let gateObservation { gate.removeSessionInvalidator(gateObservation) }
        if let credentialObservation {
            let broker = broker
            Task { await broker.removeChangeHandler(await credentialObservation.value) }
        }
        if let grantedCredentialCancellation { broker.unregisterCredentialCancellation(grantedCredentialCancellation) }
        registry.revoke()
    }

    public var state: ExternalAISessionState { registry.currentState() }

    public func authorize(_ authority: ExternalAIVaultAuthority) async throws -> ExternalAICapability {
        try Task.checkCancellation()
        // Register before reading the credential version, closing replacement/removal races.
        if credentialObservation == nil {
            credentialObservation = Task { [broker, weak registry] in
                await broker.addChangeHandler { [weak registry] in registry?.revoke() }
            }
        }
        _ = await credentialObservation!.value
        let lease = try registry.lease(for: authority)
        let version = try await broker.credentialVersion()
        // No suspension between this lease validation and capability/prompt selection.
        _ = try registry.lease(for: authority)
        if let capability = registry.reusable(authority: authority, version: version) {
            try registry.validate(capability, activity: false)
            return capability
        }

        let pending: (epoch: UInt64, authority: ExternalAIVaultAuthority,
                      version: UUID, task: Task<Void, Error>)
        if let existing = authentication, existing.authority == authority,
           existing.version == version, registry.matchesEpoch(existing.epoch) {
            pending = existing
        } else {
            authentication?.task.cancel()
            registry.revoke()
            if let gateObservation { gate.removeSessionInvalidator(gateObservation) }
            let epoch = registry.begin(lease: lease)
            // Registration itself fails closed if the gate became locked in the meantime.
            gateObservation = gate.registerSessionInvalidator(lease: lease) { [weak registry] in
                registry?.revoke()
            }
            let task = Task { [authenticator] in try await authenticator.authenticate() }
            registry.registerAuthenticationCancellation(epoch: epoch) { task.cancel() }
            pending = (epoch, authority, version, task)
            authentication = pending
        }

        do {
            try await withTaskCancellationHandler {
                try await pending.task.value
                try Task.checkCancellation()
            } onCancel: { [registry] in
                // Cancelling any coalesced waiter cancels the shared prompt and fails all closed.
                registry.revoke()
            }
            let currentVersion = try await broker.credentialVersion()
            guard currentVersion == version else { throw ExternalAIError.authorizationRevoked }
            let capability = try registry.commit(epoch: pending.epoch, authority: authority, version: version)
            if authentication?.epoch == pending.epoch { authentication = nil }
            startExpiryObservation()
            return capability
        } catch {
            if authentication?.epoch == pending.epoch {
                authentication = nil
                registry.revoke()
            }
            if error is CancellationError || Task.isCancelled { throw ExternalAIError.cancelled }
            throw (error as? ExternalAIError) ?? ExternalAIError.authenticationFailed
        }
    }

    /// Module-only: a validated durable grant issues one bounded request session.
    /// This never makes the ordinary interactive authorize path skip authentication.
    func authorizeGrantedRequest(_ request: ExternalAISummaryRequest, version: UUID) async throws -> ExternalAICapability {
        let lease = try registry.lease(for: request.authority)
        let epoch = try registry.beginGranted(lease: lease)
        gateObservation = gate.registerSessionInvalidator(lease: lease) { [registry] in registry.revoke() }
        grantedCredentialCancellation = try broker.registerCredentialCancellation(version: version) { [registry] in registry.revoke() }
        let observed = try await broker.credentialVersion()
        guard observed == version else { registry.revoke(); throw ExternalAIError.authorizationRevoked }
        try Task.checkCancellation()
        let capability = try registry.commit(epoch: epoch, authority: request.authority, version: version)
        startExpiryObservation()
        return capability
    }

    /// Gateway calls this around every broker suspension and before returning a result.
    /// Only initiation of an approved operation should set activity=true; validation and UI
    /// inspection do not extend the idle deadline.
    public func validate(_ capability: ExternalAICapability, activity: Bool = false) async throws {
        try registry.validate(capability, activity: false)
        let version = try await broker.credentialVersion()
        guard version == capability.credentialVersion else {
            registry.revoke()
            throw ExternalAIError.authorizationRevoked
        }
        try registry.validate(capability, activity: activity)
    }

    public nonisolated func validateSynchronously(_ capability: ExternalAICapability,
                                                activity: Bool = false) throws {
        try registry.validate(capability, activity: activity)
    }

    /// Final dispatch barrier, called only inside VaultAccessGate.withOpenSession. Lock order
    /// is gate then authorization registry. The body may only resume a configured network task;
    /// it must not reenter either gate, call a cancellation handler, or perform blocking work.
    public nonisolated func withValidatedAuthorization(
        _ capability: ExternalAICapability, body: @Sendable () throws -> Void
    ) throws {
        try registry.withValidatedAuthorization(capability, body: body)
    }

    public nonisolated func registerCancellation(
        for capability: ExternalAICapability, _ cancel: @escaping @Sendable () -> Void
    ) throws -> UUID {
        try registry.registerCancellation(capability: capability, cancel: cancel)
    }

    public nonisolated func unregisterCancellation(_ id: UUID) { registry.unregisterCancellation(id) }

    public nonisolated func revoke(reason: ExternalAIRevocationReason = .explicit) { registry.revoke() }

    private func startExpiryObservation() {
        guard expiryTask == nil else { return }
        expiryTask = Task { [weak self, registry] in
            while let delay = registry.timeUntilExpiry(), !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(max(0.01, delay))) } catch { break }
                registry.expireIfNeeded()
            }
            await self?.finishedExpiryObservation()
        }
    }

    private func finishedExpiryObservation() { expiryTask = nil }
}

/// Shared synchronous revocation state. This class is safe for D02 gate callbacks and native
/// notification callbacks; cancellation handlers must not reenter VaultAccessGate.
final class ExternalAIAuthorizationRegistry: Sendable {
    private struct Record: Sendable {
        let capability: ExternalAICapability
        let lease: VaultSessionLease
        let authorizedAt: Date
        var lastActivity: Date
    }
    private struct State: Sendable {
        var phase: ExternalAISessionState = .unauthorized
        var epoch: UInt64 = 0
        var lease: VaultSessionLease?
        var record: Record?
        var cancellations: [UUID: @Sendable () -> Void] = [:]
    }
    private let storage = Mutex(State())
    private let gate: VaultAccessGate
    private let policy: ExternalAISessionPolicy
    private let now: @Sendable () -> Date

    init(gate: VaultAccessGate, policy: ExternalAISessionPolicy, now: @escaping @Sendable () -> Date) {
        self.gate = gate
        self.policy = policy
        self.now = now
    }

    func lease(for authority: ExternalAIVaultAuthority) throws -> VaultSessionLease {
        guard let lease = gate.currentLease, authority.matches(lease) else {
            revoke()
            throw ExternalAIError.vaultUnavailable
        }
        do {
            try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID,
                              operation: "externalAISummary")
        } catch {
            revoke()
            throw ExternalAIError.vaultUnavailable
        }
        return lease
    }

    func currentState() -> ExternalAISessionState {
        expireIfNeeded()
        let expected = storage.withLock { $0.lease }
        if let expected, gate.currentLease != expected { revoke() }
        return storage.withLock { $0.phase }
    }

    func reusable(authority: ExternalAIVaultAuthority, version: UUID) -> ExternalAICapability? {
        expireIfNeeded()
        return storage.withLock {
            guard let record = $0.record, record.capability.authority == authority,
                  record.capability.credentialVersion == version else { return nil }
            return record.capability
        }
    }

    func beginGranted(lease: VaultSessionLease) throws -> UInt64 {
        try storage.withLock {
            guard $0.phase == .unauthorized, $0.epoch == 0 else { throw ExternalAIError.authorizationRevoked }
            $0.epoch &+= 1; $0.phase = .authorising; $0.lease = lease
            return $0.epoch
        }
    }

    func begin(lease: VaultSessionLease) -> UInt64 {
        storage.withLock {
            $0.epoch &+= 1
            $0.phase = .authorising
            $0.lease = lease
            return $0.epoch
        }
    }

    func matchesEpoch(_ epoch: UInt64) -> Bool { storage.withLock { $0.epoch == epoch } }

    func registerAuthenticationCancellation(epoch: UInt64, cancel: @escaping @Sendable () -> Void) {
        let stale = storage.withLock {
            guard $0.epoch == epoch, $0.phase == .authorising else { return true }
            $0.cancellations[UUID()] = cancel
            return false
        }
        if stale { cancel() }
    }

    func commit(epoch: UInt64, authority: ExternalAIVaultAuthority, version: UUID) throws -> ExternalAICapability {
        let lease = try self.lease(for: authority)
        let instant = now()
        return try storage.withLock {
            guard $0.epoch == epoch else { throw ExternalAIError.authorizationRevoked }
            if let existing = $0.record { return existing.capability }
            guard $0.phase == .authorising else { throw ExternalAIError.authorizationRevoked }
            let capability = ExternalAICapability(authority: authority, credentialVersion: version)
            $0.record = Record(capability: capability, lease: lease, authorizedAt: instant, lastActivity: instant)
            $0.cancellations.removeAll()
            $0.phase = .authorized
            return capability
        }
    }

    func validate(_ capability: ExternalAICapability, activity: Bool) throws {
        _ = try lease(for: capability.authority)
        expireIfNeeded()
        let instant = now()
        try storage.withLock {
            if $0.phase == .expired { throw ExternalAIError.authorizationExpired }
            guard $0.phase == .authorized, var record = $0.record, record.capability == capability else {
                throw ExternalAIError.authorizationRevoked
            }
            if activity { record.lastActivity = instant; $0.record = record }
        }
    }

    func withValidatedAuthorization(_ capability: ExternalAICapability,
                                    body: @Sendable () throws -> Void) throws {
        expireIfNeeded()
        do {
            try storage.withLock {
                if $0.phase == .expired { throw ExternalAIError.authorizationExpired }
                guard $0.phase == .authorized, let record = $0.record, record.capability == capability else {
                    throw ExternalAIError.authorizationRevoked
                }
                let instant = now()
                let age = instant.timeIntervalSince(record.authorizedAt)
                let idle = instant.timeIntervalSince(record.lastActivity)
                guard age >= 0, idle >= 0, age < policy.maximumLifetime, idle < policy.idleTimeout else {
                    throw ExternalAIError.authorizationExpired
                }
                try body()
            }
        } catch {
            expireIfNeeded()
            throw error
        }
    }

    func registerCancellation(capability: ExternalAICapability,
                              cancel: @escaping @Sendable () -> Void) throws -> UUID {
        try validate(capability, activity: false)
        return try storage.withLock {
            guard $0.record?.capability == capability, $0.phase == .authorized else {
                throw ExternalAIError.authorizationRevoked
            }
            let id = UUID()
            $0.cancellations[id] = cancel
            return id
        }
    }

    func unregisterCancellation(_ id: UUID) { _ = storage.withLock { $0.cancellations.removeValue(forKey: id) } }

    func revoke() { invalidate(phase: .revoked) }

    private func invalidate(phase: ExternalAISessionState) {
        let callbacks = storage.withLock {
            $0.epoch &+= 1
            $0.phase = phase
            $0.record = nil
            $0.lease = nil
            let callbacks = Array($0.cancellations.values)
            $0.cancellations.removeAll()
            return callbacks
        }
        for cancel in callbacks { cancel() }
    }

    func expireIfNeeded() {
        let instant = now()
        let callbacks: [@Sendable () -> Void] = storage.withLock {
            guard let record = $0.record else { return [] }
            let age = instant.timeIntervalSince(record.authorizedAt)
            let idle = instant.timeIntervalSince(record.lastActivity)
            // Clock rollback must not extend authority.
            guard age < 0 || idle < 0 || age >= policy.maximumLifetime || idle >= policy.idleTimeout else { return [] }
            $0.phase = .expired
            $0.epoch &+= 1
            $0.record = nil
            let callbacks = Array($0.cancellations.values)
            $0.cancellations.removeAll()
            return callbacks
        }
        for cancel in callbacks { cancel() }
    }

    func timeUntilExpiry() -> TimeInterval? {
        expireIfNeeded()
        let instant = now()
        return storage.withLock {
            guard let record = $0.record else { return nil }
            return min(policy.maximumLifetime - instant.timeIntervalSince(record.authorizedAt),
                       policy.idleTimeout - instant.timeIntervalSince(record.lastActivity))
        }
    }
}
