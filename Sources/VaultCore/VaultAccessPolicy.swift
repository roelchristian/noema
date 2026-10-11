import Foundation
import Synchronization

/// Per-Mac application preferences, separate from the portable plaintext vault format.
/// This gate does not protect against filesystem access or local preference tampering.
struct VaultAccessPolicySnapshot: Sendable, Equatable {
    let authenticationRequired: Bool
    let revision: String?
}

/// Only the session manager writes production policy. Tests use isolated defaults internally.
// UserDefaults is thread-safe; this lock additionally serializes compound snapshots and writes.
// The reference stays private, and every store access below holds the lock.
final class VaultAccessPolicyStore: @unchecked Sendable {
    static let standard = VaultAccessPolicyStore(defaults: .standard)
    private let defaults: UserDefaults
    private let lock = Mutex(())

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func key(for vaultID: UUID) -> String {
        "noema.vault-access-authentication.v1.\(vaultID.uuidString)"
    }

    private func snapshotWhileLocked(for vaultID: UUID) -> VaultAccessPolicySnapshot {
        let key = Self.key(for: vaultID)
        return VaultAccessPolicySnapshot(
            authenticationRequired: defaults.bool(forKey: key),
            revision: defaults.string(forKey: key + ".revision")
        )
    }

    func snapshot(for vaultID: UUID) -> VaultAccessPolicySnapshot {
        lock.withLock { _ in snapshotWhileLocked(for: vaultID) }
    }

    private func writeWhileLocked(_ required: Bool, for vaultID: UUID) {
        let key = Self.key(for: vaultID)
        defaults.set(required, forKey: key)
        defaults.set(UUID().uuidString, forKey: key + ".revision")
    }

    func setRequired(_ required: Bool, for vaultID: UUID) {
        lock.withLock { _ in writeWhileLocked(required, for: vaultID) }
    }

    /// Serializes supported preference writers with a final synchronous lifecycle commit.
    /// The body must not suspend, inspect storage, or call back into this policy store.
    func withUnchangedSnapshot<T>(
        for vaultID: UUID,
        matching expected: VaultAccessPolicySnapshot,
        action: String,
        body: () throws -> T
    ) throws -> T {
        try lock.withLock { _ in
            guard snapshotWhileLocked(for: vaultID) == expected else {
                throw VaultSessionError.cancelled(action: action)
            }
            return try body()
        }
    }

    func setRequired(_ required: Bool, for vaultID: UUID, matching expected: VaultAccessPolicySnapshot) throws {
        try withUnchangedSnapshot(for: vaultID, matching: expected, action: "changeVaultAccessPolicy") {
            if Task.isCancelled { throw VaultSessionError.cancelled(action: "changeVaultAccessPolicy") }
            writeWhileLocked(required, for: vaultID)
        }
    }
}
