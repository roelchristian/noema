import Foundation
import ExternalAI
import VaultCore
import Synchronization

/// Submission disclosure preference. Authentication and request-bound receipts remain mandatory.
enum OpenAIConsentPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case always, oncePerSession, neverAsk
    var id: Self { self }
    var displayName: String {
        switch self {
        case .always: "Always ask"
        case .oncePerSession: "Ask once every session"
        case .neverAsk: "Never ask"
        }
    }
    static let preferenceKey = "openAIConsentPolicy.v1"
    private struct StoredPolicy: Codable { let version: Int; let policy: OpenAIConsentPolicy }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: preferenceKey),
              let stored = try? JSONDecoder().decode(StoredPolicy.self, from: data),
              stored.version == 1 else { return .always }
        return stored.policy
    }

    func persist(in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(StoredPolicy(version: 1, policy: self)) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}

/// The complete lease includes root, vault, session identity and generation. It is memory-only
/// and synchronously cleared when the access gate closes, including lock/unlock ABA transitions.
final class OpenAIConsentSession: Sendable {
    private let approved = Mutex<VaultSessionLease?>(nil)
    func approves(_ lease: VaultSessionLease) -> Bool { approved.withLock { $0 == lease } }
    func record(_ lease: VaultSessionLease) { approved.withLock { $0 = lease } }
    func clear() { approved.withLock { $0 = nil } }
}
