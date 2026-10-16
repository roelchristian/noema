import Foundation
import Synchronization

/// One process-wide domain per canonical database, shared by every admitted store connection.
/// Canonical SQL remains on SQLiteBlockStore; this domain contains no SQL or content.
final class EmbeddingPublicationDomain: @unchecked Sendable {
    private static let domains = Mutex<[String: EmbeddingPublicationDomain]>([:])
    let lock = NSRecursiveLock()
    private(set) var epoch = UUID()

    static func shared(for url: URL) -> EmbeddingPublicationDomain {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        return domains.withLock { domains in
            if let domain = domains[key] { return domain }
            let domain = EmbeddingPublicationDomain(); domains[key] = domain; return domain
        }
    }
    func invalidate() { epoch = UUID() } // Caller holds lock.
}

/// A short synchronous publication barrier, deliberately separate from gate dispatch helpers.
/// Invalidate before replacing provider/model/session/consent authority. No gate calls or awaits
/// are permitted inside its protected body. Gate revocation may wait for an admitted COMMIT.
public final class EmbeddingPublicationAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private let gate: VaultAccessGate?
    private var registration: UUID?
    let lease: VaultSessionLease?
    let generation: EmbeddingIndexGeneration?

    public init(accessGate: VaultAccessGate, lease: VaultSessionLease,
                generation: EmbeddingIndexGeneration) throws {
        guard generation.vaultID == lease.vaultID else { throw EmbeddingContractError.authorityDenied }
        gate = accessGate; self.lease = lease; self.generation = generation
        try accessGate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID,
                                operation: "embedding.publication.authority")
        registration = accessGate.registerSessionInvalidator(lease: lease) { [weak self] in self?.invalidate() }
    }
    /// Disposable tests only; never accepted by SQLiteEmbeddingIndex's protected publication API.
    init() { gate = nil; lease = nil; generation = nil }
    deinit { if let registration { gate?.removeSessionInvalidator(registration) } }
    public func invalidate() { lock.lock(); defer { lock.unlock() }; valid = false }
    fileprivate func withPublication<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard valid else { throw EmbeddingContractError.authorityDenied }
        return try body()
    }
}

/// Opaque canonical-issued evidence. A ledger row or caller-created context cannot mint it.
/// Lock order: canonical domain -> publication authority. Neither protected body reenters the
/// access gate. No lock spans an await. Unsupported external SQLite writers are outside this
/// in-process boundary, just as externally mutable linked originals require revalidation.
public final class EmbeddingPublicationPermit: @unchecked Sendable {
    private let domain: EmbeddingPublicationDomain
    private let epoch: UUID
    let entityID: UUID
    let revision: BlockStoreRevision
    let kind: AIEntityKind
    let vaultID: UUID?

    init(domain: EmbeddingPublicationDomain, entityID: UUID, revision: BlockStoreRevision,
         kind: AIEntityKind, vaultID: UUID?) {
        self.domain = domain; epoch = domain.epoch; self.entityID = entityID
        self.revision = revision; self.kind = kind; self.vaultID = vaultID
    }
    public func withPublication<T>(authority: EmbeddingPublicationAuthority,
                                   _ body: () throws -> T) throws -> T {
        domain.lock.lock(); defer { domain.lock.unlock() }
        try Task.checkCancellation()
        guard domain.epoch == epoch else { throw EmbeddingContractError.authorityDenied }
        return try authority.withPublication(body)
    }
    func matches(_ identity: EmbeddingEntityIdentity) -> Bool {
        identity.entityID == entityID && identity.entityKind == kind && identity.vaultID == vaultID &&
            identity.revision == revision.token.base64EncodedString()
    }
}
