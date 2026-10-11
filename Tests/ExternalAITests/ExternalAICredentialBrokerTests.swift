import Foundation
import Testing
@testable import ExternalAI

final class CredentialTestKeychain: ExternalAIKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?
    private var unavailable = false
    func read() throws -> Data? {
        try lock.withLock {
            if unavailable { throw ExternalAIError.credentialUnavailable }
            return storage
        }
    }
    func write(_ data: Data) throws {
        try lock.withLock {
            if unavailable { throw ExternalAIError.credentialUnavailable }
            storage = data
        }
    }
    func delete() throws {
        try lock.withLock {
            if unavailable { throw ExternalAIError.credentialUnavailable }
            storage = nil
        }
    }
    func setUnavailable(_ value: Bool) { lock.withLock { unavailable = value } }
}

private final class CredentialTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}

private final class CredentialRevocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private let testCredential = "sk-test-credential-for-unit-tests-only"

@Test func credentialBrokerMissingMalformedAndInaccessibleAreRedacted() async throws {
    let keychain = CredentialTestKeychain()
    let broker = ExternalAICredentialBroker(keychain: keychain)
    #expect(await broker.status().presence == .missing)
    await #expect(throws: ExternalAIError.credentialMissing) { try await broker.credentialVersion() }
    await #expect(throws: ExternalAIError.credentialMalformed) { try await broker.store("short") }
    await #expect(throws: ExternalAIError.credentialMalformed) { try await broker.store(testCredential + "\n") }
    try keychain.write(Data("corrupted-keychain-record".utf8))
    #expect(await broker.status().presence == .malformed)
    keychain.setUnavailable(true)
    #expect(await broker.status().presence == .inaccessible)
    await #expect(throws: ExternalAIError.credentialUnavailable) { try await broker.store(testCredential) }
    for error in ExternalAIError.allCases {
        #expect(!error.localizedDescription.contains(testCredential))
        #expect(!String(reflecting: error).contains(testCredential))
    }
}

@Test func credentialReplacementAndRemovalRevokeCapabilitiesSynchronously() async throws {
    let keychain = CredentialTestKeychain()
    let broker = ExternalAICredentialBroker(keychain: keychain)
    try await broker.store(testCredential)
    let original = try await broker.credentialVersion()
    let counter = CredentialRevocationCounter()
    let handler = await broker.addChangeHandler { counter.increment() }
    try await broker.replace(testCredential + "-replacement")
    let replacement = try await broker.credentialVersion()
    #expect(replacement != original)
    #expect(counter.value == 1)
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await broker.withCredential(version: original) { _ in true }
    }
    try await broker.remove()
    #expect(counter.value == 2)
    #expect(await broker.status().presence == .missing)
    await broker.removeChangeHandler(handler)
    try await broker.store(testCredential)
    #expect(counter.value == 2)
}

@Test func credentialThirtyDayPolicyExpiresLocallyAndRevokes() async throws {
    let keychain = CredentialTestKeychain()
    let clock = CredentialTestClock()
    let broker = ExternalAICredentialBroker(keychain: keychain, now: { clock.now() })
    try await broker.store(testCredential, policy: .thirtyDays)
    let status = await broker.status()
    #expect(status.isAvailable)
    #expect(status.localPolicyExpiresAt == clock.now().addingTimeInterval(30 * 24 * 60 * 60))
    let counter = CredentialRevocationCounter()
    _ = await broker.addChangeHandler { counter.increment() }
    clock.advance(30 * 24 * 60 * 60)
    await #expect(throws: ExternalAIError.credentialExpired) { try await broker.credentialVersion() }
    #expect(counter.value == 1)
    #expect(await broker.status().presence == .expired)
    #expect(try keychain.read() != nil) // Local policy does not claim issuer revocation or delete its key.
}

@Test func credentialUnlimitedPolicyAndExternalKeychainDeletion() async throws {
    let keychain = CredentialTestKeychain()
    let clock = CredentialTestClock()
    let broker = ExternalAICredentialBroker(keychain: keychain, now: { clock.now() })
    try await broker.store(testCredential)
    clock.advance(100 * 24 * 60 * 60)
    #expect(await broker.status().isAvailable)
    #expect(await broker.status().localPolicyExpiresAt == nil)
    let counter = CredentialRevocationCounter()
    _ = await broker.addChangeHandler { counter.increment() }
    try keychain.delete()
    #expect(await broker.status().presence == .missing)
    #expect(counter.value == 1)
}

@Test func credentialFailedDeletionStillRevokesCachedAuthority() async throws {
    let keychain = CredentialTestKeychain()
    let broker = ExternalAICredentialBroker(keychain: keychain)
    try await broker.store(testCredential)
    let counter = CredentialRevocationCounter()
    _ = await broker.addChangeHandler { counter.increment() }
    keychain.setUnavailable(true)
    await #expect(throws: ExternalAIError.credentialUnavailable) { try await broker.remove() }
    #expect(counter.value == 1)
}

@Test func credentialWrapperOnlyAuthorizesFixedResponsesEndpoint() throws {
    let credential = ExternalAICredential(bytes: Data(testCredential.utf8))
    #expect(!String(describing: credential).contains(testCredential))
    #expect(!String(reflecting: credential).contains(testCredential))
    var allowed = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    allowed.httpMethod = "POST"
    try credential.authorize(&allowed)
    #expect(allowed.value(forHTTPHeaderField: "Authorization") == "Bearer " + testCredential)
    for url in ["http://api.openai.com/v1/responses", "https://evil.example/v1/responses",
                "https://api.openai.com/v1/chat/completions", "https://api.openai.com/v1/responses?key=x",
                "https://api.openai.com:8080/v1/responses", "https://user:password@api.openai.com/v1/responses"] {
        var rejected = URLRequest(url: URL(string: url)!)
        rejected.httpMethod = "POST"
        #expect(throws: ExternalAIError.invalidConfiguration) { try credential.authorize(&rejected) }
        #expect(rejected.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Test func credentialExecutionRejectsReplacementBeforeCompletion() async throws {
    let broker = ExternalAICredentialBroker(keychain: CredentialTestKeychain())
    try await broker.store(testCredential)
    let version = try await broker.credentialVersion()
    await #expect(throws: ExternalAIError.authorizationRevoked) {
        try await broker.withCredential(version: version) { _ in
            try await broker.replace(testCredential + "-new")
            return "a delayed result"
        }
    }
}

@Test func credentialExecutionRedactsUnderlyingErrors() async throws {
    struct LeakingError: Error, CustomStringConvertible {
        var description: String { testCredential }
    }
    let broker = ExternalAICredentialBroker(keychain: CredentialTestKeychain())
    try await broker.store(testCredential)
    let version = try await broker.credentialVersion()
    await #expect(throws: ExternalAIError.networkUnavailable) {
        try await broker.withCredential(version: version) { _ -> Bool in throw LeakingError() }
    }
}

@Test func credentialConnectionValidationCannotSubmitContentOrChooseEndpoints() throws {
    let credential = ExternalAICredential(bytes: Data(testCredential.utf8))
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/gpt-test")!)
    request.httpMethod = "GET"
    try credential.authorizeConnectionValidation(&request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + testCredential)
    request.httpBody = Data("vault content".utf8)
    #expect(throws: ExternalAIError.invalidConfiguration) { try credential.authorizeConnectionValidation(&request) }
    for url in ["https://api.openai.com/v1/models/", "https://api.openai.com/v1/models/other/path",
                "https://api.openai.com/v1/models/model?content=x", "https://evil.example/v1/models/model"] {
        var rejected = URLRequest(url: URL(string: url)!)
        rejected.httpMethod = "GET"
        #expect(throws: ExternalAIError.invalidConfiguration) { try credential.authorizeConnectionValidation(&rejected) }
    }
}
