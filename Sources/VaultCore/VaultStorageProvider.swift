import Foundation

/// Selects storage once for each opened root, including temporary creation roots.
/// The selected store belongs to the repository and is shared by its consumers.
public struct VaultStorageProvider: Sendable {
    private let factory: @Sendable (URL) throws -> any VaultContentStore

    public init(_ factory: @escaping @Sendable (URL) throws -> any VaultContentStore) {
        self.factory = factory
    }

    public func makeStore(root: URL) throws -> any VaultContentStore { try factory(root) }

    /// Actor construction remains in the same policy as byte-store selection.
    /// An existing page-only vault must never infer expanded authority from tables.
    func makeBlockStore(url: URL, sessionLease: VaultSessionLease?, accessGate: VaultAccessGate?,
                        createIfMissing: Bool = true) throws -> SQLiteBlockStore {
        if let sessionLease, let accessGate {
            return try SQLiteBlockStore(url: url, sessionLease: sessionLease,
                                        accessGate: accessGate, createIfMissing: createIfMissing)
        }
        guard sessionLease == nil, accessGate == nil else {
            throw VaultAccessError.missingLease(operation: "blockStore.open")
        }
        // Only explicit migration staging and disposable tests lack a session.
        return try SQLiteBlockStore(unguardedTestingURL: url, createIfMissing: createIfMissing)
    }

    /// Explicit construction of a fresh expanded database. This does not publish a
    /// manifest or convert an existing vault; repository admission remains closed
    /// until source byte receipts and every metadata lifecycle path are integrated.
    func makeCanonicalStagingStore(url: URL, vaultID: UUID,
                                   createIfMissing: Bool = true) throws -> SQLiteBlockStore {
        try SQLiteVaultMigration.requireLocalRoot(url.deletingLastPathComponent())
        return try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID,
                                    createIfMissing: createIfMissing)
    }

    public static let plaintext = VaultStorageProvider { try PlaintextVaultContentStore(root: $0) }
}
