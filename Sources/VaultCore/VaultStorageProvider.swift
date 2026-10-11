import Foundation

/// Selects storage once for each opened root, including temporary creation roots.
/// The selected store belongs to the repository and is shared by its consumers.
public struct VaultStorageProvider: Sendable {
    private let factory: @Sendable (URL) throws -> any VaultContentStore

    public init(_ factory: @escaping @Sendable (URL) throws -> any VaultContentStore) {
        self.factory = factory
    }

    public func makeStore(root: URL) throws -> any VaultContentStore { try factory(root) }

    public static let plaintext = VaultStorageProvider { try PlaintextVaultContentStore(root: $0) }
}
