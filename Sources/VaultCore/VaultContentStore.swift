import Foundation

/// Byte storage for vault-owned relative paths. Implementations must check paths again
/// inside coordination, keep preconditions and mutations in the same access window,
/// atomically publish writes, and leave stale or cloud-conflicted content untouched.
/// Calls are synchronous so repository actors can own compound domain operations;
/// callers must keep filesystem work off the main actor. No multi-call transaction is implied.
public protocol VaultContentStore: Sendable {
    func read(at path: String) throws -> Data
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
