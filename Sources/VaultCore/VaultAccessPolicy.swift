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

    func snapshot(for vaultID: UUID) -> VaultAccessPolicySnapshot {
        lock.withLock { _ in
            let key = Self.key(for: vaultID)
            return VaultAccessPolicySnapshot(
                authenticationRequired: defaults.bool(forKey: key),
                revision: defaults.string(forKey: key + ".revision")
            )
        }
    }

    func setRequired(_ required: Bool, for vaultID: UUID) {
        lock.withLock { _ in
            let key = Self.key(for: vaultID)
            defaults.set(required, forKey: key)
            defaults.set(UUID().uuidString, forKey: key + ".revision")
        }
    }
}
