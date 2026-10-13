import Foundation

/// Selects storage once for each opened root, including temporary creation roots.
/// The selected store belongs to the repository and is shared by its consumers.
public struct VaultStorageProvider: Sendable {
    private let factory: @Sendable (URL) throws -> any VaultContentStore

    public init(_ factory: @escaping @Sendable (URL) throws -> any VaultContentStore) {
        self.factory = factory
    }

    public func makeStore(root: URL) throws -> any VaultContentStore { try factory(root) }

    /// Production construction admits only a declared schema-6 vault and a current lease.
    func makeBlockStore(url: URL, sessionLease: VaultSessionLease?, accessGate: VaultAccessGate?,
                        createIfMissing: Bool = false, manifest: VaultManifest? = nil) throws -> SQLiteBlockStore {
        guard let manifest, manifest.isSupported, let declaration = manifest.storage,
              let sessionLease, let accessGate, !createIfMissing else {
            throw VaultError.invalid("Canonical admission requires a schema-6 manifest, existing database and matching session authority.")
        }
        try SQLiteVaultLocality.requireLocalRoot(url.deletingLastPathComponent())
        return try SQLiteBlockStore(url: url, sessionLease: sessionLease, accessGate: accessGate,
            canonicalVaultID: manifest.id, requiredCapabilities: declaration.requiredCapabilities,
            schemaVersion: declaration.schemaVersion, createIfMissing: false)
    }

    /// Explicit construction of a fresh expanded database. This does not publish a
    /// manifest or convert an existing vault; repository admission remains closed
    /// until source byte receipts and every metadata lifecycle path are integrated.
    func makeCanonicalStagingStore(url: URL, vaultID: UUID,
                                   createIfMissing: Bool = true) throws -> SQLiteBlockStore {
        try SQLiteVaultLocality.requireLocalRoot(url.deletingLastPathComponent())
        return try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID,
                                    createIfMissing: createIfMissing)
    }

    /// Explicit fresh staging only; opening schema 3 never converts its authority.
    func makeKnowledgeStagingStore(url: URL, vaultID: UUID, createIfMissing: Bool = true) throws -> SQLiteBlockStore {
        try SQLiteVaultLocality.requireLocalRoot(url.deletingLastPathComponent())
        return try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID,
            requiredCapabilities: SQLiteBlockStore.knowledgeRequiredCapabilities,
            schemaVersion: SQLiteBlockStore.knowledgeSchemaVersion, createIfMissing: createIfMissing)
    }

    /// Schema 5 is initialized only through this explicit fresh staging route.
    func makeSemanticStagingStore(url: URL, vaultID: UUID, createIfMissing: Bool = true, validating operation: (@Sendable () throws -> Void)? = nil) throws -> SQLiteBlockStore {
        try SQLiteVaultLocality.requireLocalRoot(url.deletingLastPathComponent())
        return try SQLiteBlockStore(canonicalStagingURL:url, vaultID:vaultID, requiredCapabilities:SQLiteBlockStore.semanticRequiredCapabilities, schemaVersion:SQLiteBlockStore.semanticSchemaVersion, createIfMissing:createIfMissing, validating:operation)
    }

    /// Fresh schema 6, including vault-owned favourites, collections, and folders.
    func makeOrganisationStagingStore(url: URL, vaultID: UUID, createIfMissing: Bool = true, validating operation: (@Sendable () throws -> Void)? = nil) throws -> SQLiteBlockStore {
        try SQLiteVaultLocality.requireLocalRoot(url.deletingLastPathComponent())
        return try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities, schemaVersion: SQLiteBlockStore.organisationSchemaVersion, createIfMissing: createIfMissing, validating: operation)
    }

    /// Opens the vault database at the schema declared by its own manifest. Does not create or convert authority.
    func makeDeclaredStagingStore(url: URL, vaultID: UUID, declaration: VaultCanonicalStorageDeclaration, createIfMissing: Bool = false, validating operation: (@Sendable () throws -> Void)? = nil) throws -> SQLiteBlockStore {
        try operation?()
        guard declaration.isSupported, !createIfMissing else {
            throw VaultError.invalid("Archive validation requires an existing schema-6 database.")
        }
        try SQLiteVaultLocality.requireLocalRoot(url.deletingLastPathComponent())
        return try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID, requiredCapabilities: declaration.requiredCapabilities, schemaVersion: declaration.schemaVersion, createIfMissing: createIfMissing, validating: operation)
    }

    public static let plaintext = VaultStorageProvider { try PlaintextVaultContentStore(root: $0) }
}
