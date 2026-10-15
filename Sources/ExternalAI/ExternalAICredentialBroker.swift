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

enum ExternalAIKeychainBackend: Sendable {
    case dataProtection, login

    static func forSigningFlags(_ flags: UInt32) -> Self {
        flags & SecCodeSignatureFlags.adhoc.rawValue == 0 ? .dataProtection : .login
    }

    static func currentProcess() -> Self? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber else { return nil }
        return forSigningFlags(flags.uint32Value)
    }
}

/// Internal Security seam tests OSStatus handling without touching a user's Keychain.
protocol ExternalAIKeychainOperations: Sendable {
    func read(_ query: [String: Any]) throws -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) throws -> OSStatus
    func add(_ attributes: [String: Any]) throws -> OSStatus
    func delete(_ query: [String: Any]) throws -> OSStatus
}

protocol ExternalAIKeychainInteraction: Sendable {
    func getAllowed() -> (OSStatus, Bool)
    func setAllowed(_ allowed: Bool) -> OSStatus
}

private struct SystemExternalAIKeychainInteraction: ExternalAIKeychainInteraction {
    func getAllowed() -> (OSStatus, Bool) {
        var allowed = DarwinBoolean(false)
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }
    func setAllowed(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }
}

/// File-based Keychain ignores SecItem's per-query UI controls. Its legacy UI
/// policy is process-wide, so serialize every scope and restore it before returning.
struct ExternalAIKeychainInteractionGuard: Sendable {
    private static let lock = Mutex(())
    private let interaction: any ExternalAIKeychainInteraction

    init(interaction: any ExternalAIKeychainInteraction = SystemExternalAIKeychainInteraction()) {
        self.interaction = interaction
    }

    func perform<Value>(_ operation: () throws -> Value) throws -> Value {
        try Self.lock.withLock { _ in
            let (status, wasAllowed) = interaction.getAllowed()
            guard status == errSecSuccess,
                  interaction.setAllowed(false) == errSecSuccess else { throw ExternalAIError.credentialUnavailable }
            let result: Result<Value, any Error>
            do { result = .success(try operation()) }
            catch { result = .failure(error) }
            guard interaction.setAllowed(wasAllowed) == errSecSuccess else { throw ExternalAIError.credentialUnavailable }
            return try result.get()
        }
    }
}

private struct SystemExternalAIKeychainOperations: ExternalAIKeychainOperations {
    private let interactionGuard = ExternalAIKeychainInteractionGuard()

    private func perform<Value>(_ query: [String: Any], operation: () -> Value) throws -> Value {
        if query[kSecUseDataProtectionKeychain as String] as? Bool == false {
            return try interactionGuard.perform(operation)
        }
        return operation()
    }

    func read(_ query: [String: Any]) throws -> (OSStatus, Data?) {
        try perform(query) {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) throws -> OSStatus {
        try perform(query) { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    }
    func add(_ attributes: [String: Any]) throws -> OSStatus {
        try perform(attributes) { SecItemAdd(attributes as CFDictionary, nil) }
    }
    func delete(_ query: [String: Any]) throws -> OSStatus {
        try perform(query) { SecItemDelete(query as CFDictionary) }
    }
}

struct SystemExternalAIKeychain: ExternalAIKeychain {
    private let backend: ExternalAIKeychainBackend?
    private let operations: any ExternalAIKeychainOperations
    private let service: String
    private let account: String

    init(backend: ExternalAIKeychainBackend? = ExternalAIKeychainBackend.currentProcess(),
         operations: any ExternalAIKeychainOperations = SystemExternalAIKeychainOperations(),
         service: String = "com.noema.external-ai.openai", account: String = "primary",
         requiresDeviceOnly: Bool = false) {
        self.service = service
        self.account = account
        self.backend = requiresDeviceOnly && backend != .dataProtection ? nil : backend
        self.operations = operations
    }

    // Select once from signing metadata, never by retrying an access-denied operation in
    // another store. Ad-hoc builds cannot have provisioned data-protection access groups.
    // No access group or sharing entitlement is added to either implementation.
    private var identity: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: backend == .dataProtection]
        if backend == .dataProtection { query[kSecAttrSynchronizable as String] = false }
        return query
    }

    func read() throws -> Data? {
        guard backend != nil else { throw ExternalAIError.credentialUnavailable }
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never ask Keychain to interact: session authentication is owned by LocalAuthentication.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let (status, data) = try operations.read(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else {
            throw ExternalAIError.credentialUnavailable
        }
        return data
    }

    func write(_ data: Data) throws {
        guard let backend else { throw ExternalAIError.credentialUnavailable }
        let status = try operations.update(identity, attributes: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            if backend == .dataProtection {
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            } else {
                // File-based Keychain items never sync. A nil trusted list grants access
                // only to the creating application, not to all applications.
                var access: SecAccess?
                guard SecAccessCreate("Noema OpenAI API key" as CFString, nil, &access) == errSecSuccess,
                      let access else { throw ExternalAIError.credentialUnavailable }
                item[kSecAttrAccess as String] = access
            }
            // No biometric access-control flag, avoiding an additional prompt on every request.
            guard try operations.add(item) == errSecSuccess else {
                throw ExternalAIError.credentialUnavailable
            }
        } else if status != errSecSuccess { throw ExternalAIError.credentialUnavailable }
    }

    func delete() throws {
        guard backend != nil else { throw ExternalAIError.credentialUnavailable }
        let status = try operations.delete(identity)
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
        do {
            let encoded = try JSONEncoder().encode(record)
            try keychain.write(encoded)
            // A login-Keychain ACL can allow an update while denying reads after an
            // ad-hoc rebuild. Confirm this exact record is usable before granting authority.
            guard try keychain.read() == encoded else { throw ExternalAIError.credentialUnavailable }
        }
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
