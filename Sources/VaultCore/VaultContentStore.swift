import Foundation

/// Byte storage for vault-owned relative paths. Implementations must check paths again
/// inside coordination, keep preconditions and mutations in the same access window,
/// atomically publish writes, and leave stale or cloud-conflicted content untouched.
/// Calls are synchronous so repository actors can own compound domain operations;
/// callers must keep filesystem work off the main actor. No multi-call transaction is implied.
public protocol VaultContentStore: Sendable {
    func synchronize(at path: String) throws
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt
    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt
    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt
    func createDirectory(at path: String) throws
    func read(at path: String) throws -> Data
    /// Optional coordinated change evidence for a currently accessible, readable original.
    /// Providers must reject unavailable/conflicted paths even when attributes are unchanged.
    /// This is never a cryptographic verification.
    func changeToken(at path: String) throws -> VaultContentChangeToken?
    func snapshot(at path: String) throws -> VaultContentSnapshot
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws
    func delete(at path: String, expected: VaultContentSnapshot) throws
}

public enum VaultWriteCondition: Sendable, Equatable {
    case createOnly
    case replace(expected: Data)
}

/// Source publication/trash operates on flat directories of original + metadata.
/// Nested directories and symlinks are deliberately unsupported, rather than silently
/// excluded from the snapshot protecting a destructive operation.
public enum VaultContentSnapshot: Sendable, Equatable {
    case file(Data)
    case directory([String: Data])
}

public enum VaultContentStoreError: Error, Sendable, Equatable, LocalizedError {
    case unsafePath(String)
    case missing(String)
    case alreadyExists(String)
    case stale(String)
    case cloudConflict(String)
    case unavailable(String)
    case unsupportedItem(String)
    case coordination(domain: String, code: Int, message: String)
    case io(domain: String, code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): "Unsafe vault path: \(path)"
        case .missing(let path): "Vault item is missing: \(path)"
        case .alreadyExists(let path): "Vault destination is occupied: \(path)"
        case .stale(let path): "Vault item changed: \(path)"
        case .cloudConflict(let path): "Resolve cloud conflicts before changing: \(path)"
        case .unavailable(let path): "Downloading \(path) from iCloud. Try again when the download finishes."
        case .unsupportedItem(let path): "Unsupported vault item: \(path)"
        case .coordination(_, _, let message), .io(_, _, let message): message
        }
    }
}

/// Providers without reliable change evidence conservatively return nil and reload originals.
public extension VaultContentStore {
    func changeToken(at path: String) throws -> VaultContentChangeToken? { nil }
    func synchronize(at path: String) throws { throw VaultContentStoreError.unsupportedItem(path) }
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt { throw VaultContentStoreError.unsupportedItem("Canonical original publication") }
    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt { throw VaultContentStoreError.unsupportedItem("Canonical original verification") }
    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt { throw VaultContentStoreError.unsupportedItem("Canonical linked verification") }
}

public struct VaultContentChangeToken: Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public init(device: Int32, inode: UInt64, size: Int64, modifiedSeconds: Int64,
                modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64) {
        self.device = device; self.inode = inode; self.size = size
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds
    }
}
