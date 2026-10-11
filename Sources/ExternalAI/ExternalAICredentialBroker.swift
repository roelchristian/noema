import Foundation
import LocalAuthentication
import Security
import Synchronization

/// A local use policy, independent of expiration or spending limits enforced by OpenAI.
public enum ExternalAICredentialPolicy: Sendable, Equatable {
    case unlimited
    case thirtyDays
}

public struct ExternalAICredentialStatus: Sendable, Equatable {
    public enum Presence: Sendable, Equatable { case missing, available, expired, malformed, inaccessible }
    public let presence: Presence
    public let version: UUID?
    public let localPolicyExpiresAt: Date?
    public var isAvailable: Bool { presence == .available }
}

/// Internal so application features cannot fetch stored bytes or inject another credential store.
protocol ExternalAIKeychain: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

private struct SystemExternalAIKeychain: ExternalAIKeychain {
    // No access group or sharing entitlement: default access is the application's signing identity.
    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.noema.external-ai.openai",
         kSecAttrAccount as String: "primary",
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    func read() throws -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never ask Keychain to interact: session authentication is owned by LocalAuthentication.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExternalAIError.credentialUnavailable
        }
        return data
    }

    func write(_ data: Data) throws {
        let status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            // No biometric access-control flag, avoiding an additional prompt on every request.
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ExternalAIError.credentialUnavailable
            }
        } else if status != errSecSuccess { throw ExternalAIError.credentialUnavailable }
    }

    func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExternalAIError.credentialUnavailable
        }
    }
}

/// Only the restricted transport inside ExternalAI can use this wrapper. Its diagnostics are redacted.
struct ExternalAICredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    var description: String { "ExternalAICredential(<redacted>)" }
    var debugDescription: String { description }

    func authorize(_ request: inout URLRequest) throws {
        guard let url = request.url, url.scheme == "https", url.host == "api.openai.com",
              url.port == nil || url.port == 443, url.path == "/v1/responses",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              request.httpMethod == "POST", let key = String(data: bytes, encoding: .utf8) else {
            throw ExternalAIError.invalidConfiguration
        }
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    }

    /// Metadata-only validation. This path cannot submit vault content or choose an arbitrary URL.
    func authorizeConnectionValidation(_ request: inout URLRequest) throws {
        guard let url = request.url, url.scheme == "https", url.host == "api.openai.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              url.path.hasPrefix("/v1/models/") else { throw ExternalAIError.invalidConfiguration }
        let model = String(url.path.dropFirst("/v1/models/".count))
        guard !model.isEmpty, model.utf8.count <= 100,
              model.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              let key = String(data: bytes, encoding: .utf8) else { throw ExternalAIError.invalidConfiguration }
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    }
}

/// Keeps credentials exclusively in Keychain. No public API returns a secret, authorization
/// header, or generic credential-execution closure. In-process isolation is an API boundary,
/// not protection against arbitrary malicious code executing inside the application process.
public actor ExternalAICredentialBroker {
    private struct Record: Codable {
        let format: Int
        let version: UUID
        let createdAt: Date
        let localPolicyExpiresAt: Date?
        let secret: Data
    }

    private let keychain: any ExternalAIKeychain
    private nonisolated let now: @Sendable () -> Date
    private var observedVersion: UUID?
    private var changeHandlers: [UUID: @Sendable () -> Void] = [:]
    private var expiryTask: Task<Void, Never>?
    private var scheduledVersion: UUID?
    private struct DispatchAuthority: Sendable {
        var version: UUID?
        var expiresAt: Date?
        var cancellations: [UUID: @Sendable () -> Void] = [:]
    }
    private nonisolated let dispatchAuthority = Mutex(DispatchAuthority())

    /// Metadata validation has no vault authority, but must still serialize dispatch with
    /// credential replacement/removal and cancel its active exchange on those events.
    nonisolated func withValidatedCredential(version: UUID, body: @Sendable () -> Void) throws {
        try dispatchAuthority.withLock {
            guard $0.version == version else { throw ExternalAIError.authorizationRevoked }
            if let expiry = $0.expiresAt, now() >= expiry { throw ExternalAIError.credentialExpired }
            try Task.checkCancellation()
            body()
        }
    }

    nonisolated func registerCredentialCancellation(version: UUID, cancel: @escaping @Sendable () -> Void) throws -> UUID {
        try dispatchAuthority.withLock {
            guard $0.version == version else { throw ExternalAIError.authorizationRevoked }
            let id = UUID()
            $0.cancellations[id] = cancel
            return id
        }
    }

    nonisolated func unregisterCredentialCancellation(_ id: UUID) {
        _ = dispatchAuthority.withLock { $0.cancellations.removeValue(forKey: id) }
    }

    public init() {
        keychain = SystemExternalAIKeychain()
        now = { Date() }
    }

    init(keychain: any ExternalAIKeychain, now: @escaping @Sendable () -> Date = { Date() }) {
        self.keychain = keychain
        self.now = now
    }

    public func status() -> ExternalAICredentialStatus {
        do {
            let record = try loadRecord()
            return ExternalAICredentialStatus(presence: .available, version: record.version,
                                              localPolicyExpiresAt: record.localPolicyExpiresAt)
        } catch {
            invalidateObservedVersion()
            let presence: ExternalAICredentialStatus.Presence
            switch error as? ExternalAIError {
            case .credentialMissing: presence = .missing
            case .credentialMalformed: presence = .malformed
            case .credentialExpired: presence = .expired
            default: presence = .inaccessible
            }
            // Even expired metadata is not fetched through a less restrictive read path.
            return ExternalAICredentialStatus(presence: presence, version: nil, localPolicyExpiresAt: nil)
        }
    }

    /// Receives an initially entered key only. UI must clear its entry field after this call.
    public func store(_ enteredKey: String, policy: ExternalAICredentialPolicy = .unlimited) throws {
        let secret = Data(enteredKey.utf8)
        guard Self.isValidSecret(secret) else { throw ExternalAIError.credentialMalformed }
        revokeCapabilities()
        let createdAt = now()
        let record = Record(format: 1, version: UUID(), createdAt: createdAt,
                            localPolicyExpiresAt: policy == .thirtyDays ? createdAt.addingTimeInterval(30 * 24 * 60 * 60) : nil,
                            secret: secret)
        do { try keychain.write(JSONEncoder().encode(record)) }
        catch { throw ExternalAIError.credentialUnavailable }
        observedVersion = record.version
        dispatchAuthority.withLock { $0.version = record.version; $0.expiresAt = record.localPolicyExpiresAt }
        scheduleExpiry(record)
    }

    public func replace(_ enteredKey: String, policy: ExternalAICredentialPolicy = .unlimited) throws {
        try store(enteredKey, policy: policy)
    }

    public func remove() throws {
        // Fail closed even if Keychain deletion subsequently fails.
        revokeCapabilities()
        do { try keychain.delete() }
        catch { throw ExternalAIError.credentialUnavailable }
    }

    func addChangeHandler(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        changeHandlers[id] = handler
        return id
    }

    func removeChangeHandler(_ id: UUID) { changeHandlers[id] = nil }

    func credentialVersion() throws -> UUID {
        do { return try loadRecord().version }
        catch {
            invalidateObservedVersion()
            throw error
        }
    }

    /// Gateway-only execution hook, suitable for moving alongside the transport into XPC.
    /// The wrapper can authorize only the fixed Responses endpoint, and cannot reveal its bytes.
    func withCredential<Result: Sendable>(version: UUID,
        execute: @Sendable (ExternalAICredential) async throws -> Result
    ) async throws -> Result {
        guard !Task.isCancelled else { throw ExternalAIError.cancelled }
        let record = try loadRecord()
        guard record.version == version else { throw ExternalAIError.authorizationRevoked }
        let result: Result
        do { result = try await execute(ExternalAICredential(bytes: record.secret)) }
        catch let error as ExternalAIError { throw error }
        catch is CancellationError { throw ExternalAIError.cancelled }
        catch { throw ExternalAIError.networkUnavailable }
        guard !Task.isCancelled else { throw ExternalAIError.cancelled }
        guard try credentialVersion() == version else { throw ExternalAIError.authorizationRevoked }
        return result
    }

    private static func isValidSecret(_ data: Data) -> Bool {
        (20...512).contains(data.count) && data.allSatisfy { (0x21...0x7e).contains($0) }
    }

    private func loadRecord() throws -> Record {
        let data: Data
        do {
            guard let stored = try keychain.read() else { throw ExternalAIError.credentialMissing }
            data = stored
        } catch let error as ExternalAIError { throw error }
        catch { throw ExternalAIError.credentialUnavailable }
        guard data.count <= 2_048, let record = try? JSONDecoder().decode(Record.self, from: data),
              record.format == 1, Self.isValidSecret(record.secret),
              record.createdAt.timeIntervalSinceReferenceDate.isFinite,
              record.localPolicyExpiresAt.map({ $0 > record.createdAt && $0.timeIntervalSince(record.createdAt) <= 30 * 24 * 60 * 60 }) ?? true else {
            throw ExternalAIError.credentialMalformed
        }
        if let expiry = record.localPolicyExpiresAt, now() >= expiry { throw ExternalAIError.credentialExpired }
        if let previous = observedVersion, previous != record.version { revokeCapabilities() }
        observedVersion = record.version
        dispatchAuthority.withLock { $0.version = record.version; $0.expiresAt = record.localPolicyExpiresAt }
        scheduleExpiry(record)
        return record
    }

    private func invalidateObservedVersion() {
        if observedVersion != nil { revokeCapabilities() }
    }

    private func revokeCapabilities() {
        expiryTask?.cancel()
        expiryTask = nil
        scheduledVersion = nil
        observedVersion = nil
        let cancellations = dispatchAuthority.withLock {
            $0.version = nil
            $0.expiresAt = nil
            let cancellations = Array($0.cancellations.values)
            $0.cancellations.removeAll()
            return cancellations
        }
        for cancel in cancellations { cancel() }
        for handler in changeHandlers.values { handler() }
    }

    private func scheduleExpiry(_ record: Record) {
        guard let expiry = record.localPolicyExpiresAt, scheduledVersion != record.version else { return }
        expiryTask?.cancel()
        scheduledVersion = record.version
        let delay = max(0, expiry.timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.expire(version: record.version)
        }
    }

    private func expire(version: UUID) {
        guard observedVersion == version else { return }
        // A wall-clock change can move expiry; reschedule if the stored policy is still valid.
        scheduledVersion = nil
        _ = status()
    }
}
