import CryptoKit
import Foundation
import Synchronization
import VaultCore

/// A revocation checkpoint, not submission authority. Only its issuing grant store
/// can validate it; pending callers capture it before their first suspension.
public struct ExternalAIVaultGrantGeneration: Sendable, Equatable {
    fileprivate let issuer: UUID
    fileprivate let epoch: UInt64
}

/// Opaque, exact-request authority; neither preferences nor a receipt can construct it.
public final class ExternalAIBackgroundAuthorization: Sendable {
    let sessions: ExternalAISessionManager
    let capability: ExternalAICapability
    let consent: ExternalAIContentConsent
    private let consumed = Mutex(false)

    init(sessions: ExternalAISessionManager, capability: ExternalAICapability, request: ExternalAISummaryRequest) {
        self.sessions = sessions; self.capability = capability
        consent = ExternalAIContentConsent(approving: request)
    }

    public func validate(for request: ExternalAISummaryRequest) throws {
        guard consent.approves(request) else { throw ExternalAIError.consentRequired }
        try sessions.validateSynchronously(capability)
    }

    func consume(for request: ExternalAISummaryRequest) throws {
        try validate(for: request)
        guard consent.approves(request) else { throw ExternalAIError.consentRequired }
        try consumed.withLock {
            guard !$0 else { throw ExternalAIError.consentAlreadyUsed }
            $0 = true
        }
    }
}

/// Security-owned durable consent, confined to this device's data-protection Keychain.
/// Main-actor serialization keeps grant read/modify/write and UI revocation ordered.
@MainActor public final class ExternalAIVaultGrants {
    public static let policyVersion = 1
    private static let operations: Set<String> = ["summarizePage", "summarizeSource", "lccClassification"]
    /// Denial-only generations are independent of Keychain availability. They never grant
    /// permission: only a freshly approved Keychain record can match a changed generation.
    private struct RevocationFence: Codable, Equatable {
        let allGrants: UUID?
        let vault: UUID?
    }
    private struct Grant: Codable {
        let vaultID: UUID
        let localIdentity: String
        let credentialVersion: UUID
        let policyVersion: Int
        let operations: Set<String>
        let revocationFence: RevocationFence?
    }
    private struct Stored: Codable { var version = 1; var grants: [String: Grant] = [:] }
    private let keychain: any ExternalAIKeychain
    private let broker: ExternalAICredentialBroker
    private let gate: VaultAccessGate
    private let revocationDefaults: UserDefaults
    private let authenticator: any ExternalAIAuthenticating
    private let makeRuntime: @Sendable () throws -> ExternalAISessionManager
    public let supportsDurableGrants: Bool
    private let generationIssuer = UUID()
    private var epoch: UInt64 = 0
    private var revocationPersistenceFailed = false
    private var runtime: [UUID: ExternalAISessionManager] = [:]

    public init(credentialBroker: ExternalAICredentialBroker, accessGate: VaultAccessGate) {
        broker = credentialBroker; gate = accessGate
        // Production callers cannot substitute an empty preference domain to hide denial.
        revocationDefaults = .standard
        authenticator = LocalExternalAIAuthenticator()
        makeRuntime = {
            ExternalAISessionManager(accessGate: accessGate, credentialBroker: credentialBroker,
                policy: try ExternalAISessionPolicy(idleTimeout: 60, maximumLifetime: 60))
        }
        let backend = ExternalAIKeychainBackend.currentProcess()
        supportsDurableGrants = backend == .dataProtection
        keychain = SystemExternalAIKeychain(backend: backend, service: "com.noema.external-ai.vault-grants", requiresDeviceOnly: true)
    }

    init(keychain: any ExternalAIKeychain, credentialBroker: ExternalAICredentialBroker, accessGate: VaultAccessGate,
         revocationDefaults: UserDefaults, authenticator: any ExternalAIAuthenticating,
         now: @escaping @Sendable () -> Date = { Date() }) {
        supportsDurableGrants = true
        self.authenticator = authenticator
        makeRuntime = {
            ExternalAISessionManager(accessGate: accessGate, credentialBroker: credentialBroker,
                authenticator: authenticator,
                policy: try ExternalAISessionPolicy(idleTimeout: 60, maximumLifetime: 60),
                now: now, observeSystemEvents: false)
        }
        self.revocationDefaults = revocationDefaults
        self.keychain = keychain; broker = credentialBroker; gate = accessGate
    }

    /// Metadata identity includes directory inode/device as well as admitted UUID/root.
    /// A copied directory, including one replacing the same path, needs fresh approval.
    private func identity(_ lease: VaultSessionLease) throws -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: lease.root.path) else { throw ExternalAIError.vaultUnavailable }
        guard let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { throw ExternalAIError.vaultUnavailable }
        let text = "\(lease.vaultID)|\(lease.root.path)|\(device)|\(inode)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load() throws -> Stored {
        guard let data = try keychain.read() else { return Stored() }
        guard data.count <= 256 * 1024,
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1 else {
            throw ExternalAIError.consentRequired
        }
        return stored
    }

    private func validateLease(_ lease: VaultSessionLease) throws {
        guard gate.currentLease == lease else { throw ExternalAIError.staleSession }
        try Task.checkCancellation()
    }

    private static func revocationKey(for vaultID: UUID?) -> String {
        "externalAI.vaultGrantRevocation.v1." + (vaultID?.uuidString ?? "all")
    }

    private func revocationFence(for vaultID: UUID) throws -> RevocationFence {
        func generation(for key: String) throws -> UUID? {
            guard let value = revocationDefaults.object(forKey: key) else { return nil }
            guard let text = value as? String, let generation = UUID(uuidString: text) else {
                throw ExternalAIError.authorizationRevoked
            }
            return generation
        }
        return try RevocationFence(allGrants: generation(for: Self.revocationKey(for: nil)),
                                   vault: generation(for: Self.revocationKey(for: vaultID)))
    }

    private func persistRevocation(for vaultID: UUID?) throws {
        // Keep admission closed even if writing the independent denial marker fails.
        // Only a successful revocation retry clears this process-local failure latch.
        // After an uncertain write, a retry fences every old grant before reopening
        // admission; revoking a different vault cannot accidentally clear the failure.
        let key = Self.revocationKey(for: revocationPersistenceFailed ? nil : vaultID)
        revocationPersistenceFailed = true
        let generation = UUID().uuidString
        revocationDefaults.set(generation, forKey: key)
        // Unlike ordinary preferences, this must reach persistent storage before we
        // attempt a Keychain mutation that can fail and leave the old grant intact.
        guard revocationDefaults.synchronize(), revocationDefaults.string(forKey: key) == generation else {
            throw ExternalAIError.credentialUnavailable
        }
        revocationPersistenceFailed = false
    }

    /// Called only by explicit approval. Opening Settings never creates these markers.
    private func prepareApprovalFence(for vaultID: UUID) throws -> RevocationFence {
        let existing = try revocationFence(for: vaultID)
        guard existing.allGrants == nil || existing.vault == nil else { return existing }
        let allGrants = existing.allGrants ?? UUID()
        let vault = existing.vault ?? UUID()
        let fence = RevocationFence(allGrants: allGrants, vault: vault)
        if existing.allGrants == nil {
            revocationDefaults.set(allGrants.uuidString, forKey: Self.revocationKey(for: nil))
        }
        if existing.vault == nil {
            revocationDefaults.set(vault.uuidString, forKey: Self.revocationKey(for: vaultID))
        }
        do {
            guard revocationDefaults.synchronize(), (try revocationFence(for: vaultID)) == fence else {
                throw ExternalAIError.credentialUnavailable
            }
        } catch {
            revocationPersistenceFailed = true
            invalidateRuntime()
            throw ExternalAIError.credentialUnavailable
        }
        return fence
    }

    public func captureGeneration() -> ExternalAIVaultGrantGeneration {
        .init(issuer: generationIssuer, epoch: epoch)
    }

    public func validateGeneration(_ generation: ExternalAIVaultGrantGeneration) throws {
        guard generation.issuer == generationIssuer, generation.epoch == epoch,
              !revocationPersistenceFailed else { throw ExternalAIError.authorizationRevoked }
        try Task.checkCancellation()
    }

    public func hasGrant(for lease: VaultSessionLease) async throws -> Bool {
        guard supportsDurableGrants, !revocationPersistenceFailed else { return false }
        let captured = epoch
        try validateLease(lease)
        let version = try await broker.credentialVersion()
        try validateLease(lease)
        guard epoch == captured else { throw ExternalAIError.authorizationRevoked }
        let identity = try identity(lease)
        guard let grant = try load().grants[identity] else { return false }
        // Missing markers, including legacy empty fences, never establish consent.
        // Fresh approval replaces old records; it cannot restore an old marker value.
        guard let approvedFence = grant.revocationFence,
              approvedFence.allGrants != nil, approvedFence.vault != nil,
              approvedFence == (try revocationFence(for: lease.vaultID)) else { return false }
        return grant.vaultID == lease.vaultID && grant.localIdentity == identity
            && grant.credentialVersion == version && grant.policyVersion == Self.policyVersion
            && grant.operations == Self.operations
    }

    /// Trusted Settings caller invokes only after the vault-specific informed disclosure.
    /// Authentication is required once for creation, never inferred from a saved preference.
    public func approve(for lease: VaultSessionLease) async throws {
        guard supportsDurableGrants else { throw ExternalAIError.credentialUnavailable }
        guard !revocationPersistenceFailed else { throw ExternalAIError.authorizationRevoked }
        try validateLease(lease)
        let fence = try prepareApprovalFence(for: lease.vaultID)
        let captured = epoch
        let version = try await broker.credentialVersion()
        try await authenticator.authenticate()
        guard try await broker.credentialVersion() == version else { throw ExternalAIError.authorizationRevoked }
        try validateLease(lease)
        guard captured == epoch, fence == (try revocationFence(for: lease.vaultID)) else {
            throw ExternalAIError.authorizationRevoked
        }
        let identity = try identity(lease)
        var stored = try load()
        guard stored.grants.count < 128 || stored.grants[identity] != nil else { throw ExternalAIError.invalidConfiguration }
        stored.grants[identity] = Grant(vaultID: lease.vaultID, localIdentity: identity,
            credentialVersion: version, policyVersion: Self.policyVersion, operations: Self.operations,
            revocationFence: fence)
        let data = try JSONEncoder().encode(stored)
        try keychain.write(data)
        guard try keychain.read() == data else { throw ExternalAIError.credentialUnavailable }
    }

    /// Revoke pending minting and in-flight requests before attempting persistent deletion.
    public func invalidateRuntime() {
        epoch &+= 1
        runtime.values.forEach { $0.revoke() }; runtime.removeAll()
    }

    public func revoke(for lease: VaultSessionLease? = nil) throws {
        invalidateRuntime()
        guard supportsDurableGrants else { return }
        // Persist denial before identity lookup, grant read, replacement or deletion.
        // Any subsequent failure leaves saved grants unusable, including after relaunch.
        try persistRevocation(for: lease?.vaultID)
        guard let lease else { try keychain.delete(); return }
        var stored = try load()
        stored.grants.removeValue(forKey: try identity(lease))
        try keychain.write(JSONEncoder().encode(stored))
    }

    /// No scheduler or dispatch: the future trusted coordinator supplies a captured request.
    /// Standalone title replacement is excluded; structured initial enrichment fills only
    /// placeholder titles through the existing repository publication contract.
    public func authorize(_ request: ExternalAISummaryRequest,
                          generation: ExternalAIVaultGrantGeneration? = nil) async throws -> ExternalAIBackgroundAuthorization {
        let checkpoint = generation ?? captureGeneration()
        try validateGeneration(checkpoint)
        guard Self.operations.contains(request.action.rawValue), request.mode != .compose else {
            throw ExternalAIError.unsupportedAction
        }
        guard let lease = gate.currentLease, request.authority.matches(lease) else { throw ExternalAIError.staleSession }
        let version = try await broker.credentialVersion()
        try validateGeneration(checkpoint)
        guard try await hasGrant(for: lease) else { throw ExternalAIError.consentRequired }
        try validateGeneration(checkpoint)
        guard try await broker.credentialVersion() == version else { throw ExternalAIError.authorizationRevoked }
        try validateLease(lease)
        try validateGeneration(checkpoint)
        // Bounded per request; it can never authorize another gateway operation.
        let sessions = try makeRuntime()
        guard runtime[request.id] == nil, runtime.count < 256 else { throw ExternalAIError.providerUnavailable }
        runtime[request.id] = sessions
        // The cleanup delay must not retain the request's plaintext after revocation.
        Task { [weak self, requestID = request.id] in
            try? await Task.sleep(for: .seconds(61))
            self?.runtime.removeValue(forKey: requestID)?.revoke()
        }
        do {
            let capability = try await sessions.authorizeGrantedRequest(request, version: version)
            try validateLease(lease)
            try validateGeneration(checkpoint)
            return ExternalAIBackgroundAuthorization(sessions: sessions, capability: capability, request: request)
        } catch {
            sessions.revoke(); runtime.removeValue(forKey: request.id); throw error
        }
    }
}
