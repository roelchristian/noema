import Foundation
import LocalAuthentication
import Security
import Testing
@testable import ExternalAI

private final class KeychainOperations: ExternalAIKeychainOperations, @unchecked Sendable {
    var readStatus = errSecSuccess
    var readData: Data? = Data("synthetic-record".utf8)
    var updateStatus = errSecItemNotFound
    var addStatus = errSecSuccess
    var deleteStatus = errSecSuccess
    var reads: [[String: Any]] = []
    var updates: [[String: Any]] = []
    var additions: [[String: Any]] = []
    var deletions: [[String: Any]] = []

    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        reads.append(query)
        return (readStatus, readData)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updates.append(query)
        return updateStatus
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        additions.append(attributes)
        return addStatus
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        deletions.append(query)
        return deleteStatus
    }
}

@Test func keychainSelectsLoginOnlyForAdHocSigning() {
    #expect(ExternalAIKeychainBackend.forSigningFlags(SecCodeSignatureFlags.adhoc.rawValue) == .login)
    #expect(ExternalAIKeychainBackend.forSigningFlags(SecCodeSignatureFlags([.adhoc, .runtime]).rawValue) == .login)
    #expect(ExternalAIKeychainBackend.forSigningFlags(SecCodeSignatureFlags.runtime.rawValue) == .dataProtection)
}

@Test(arguments: [ExternalAIKeychainBackend.login, .dataProtection])
func keychainCRUDUsesOneIdentityAndNoninteractiveReads(backend: ExternalAIKeychainBackend) throws {
    let operations = KeychainOperations()
    let keychain = SystemExternalAIKeychain(backend: backend, operations: operations)
    let payload = Data("synthetic-record".utf8)
    try keychain.write(payload)
    #expect(try keychain.read() == payload)
    try keychain.delete()
    for query in operations.updates + operations.additions + operations.reads + operations.deletions {
        #expect(query[kSecAttrService as String] as? String == "com.noema.external-ai.openai")
        #expect(query[kSecAttrAccount as String] as? String == "primary")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == (backend == .dataProtection))
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }
    let item = try #require(operations.additions.first)
    #expect(item[kSecValueData as String] as? Data == payload)
    if backend == .dataProtection {
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(item[kSecAttrAccess as String] == nil)
    } else {
        #expect(item[kSecAttrAccess as String] != nil)
        #expect(item[kSecAttrAccessible as String] == nil)
        #expect(item[kSecAttrSynchronizable as String] == nil)
    }
    let read = try #require(operations.reads.first)
    let context = try #require(read[kSecUseAuthenticationContext as String] as? LAContext)
    #expect(context.interactionNotAllowed)
    #expect(read[kSecReturnData as String] as? Bool == true)
}

@Test(arguments: [ExternalAIKeychainBackend.login, .dataProtection])
func keychainUpdateDoesNotAddWhenExistingOrInaccessible(backend: ExternalAIKeychainBackend) throws {
    let operations = KeychainOperations()
    let keychain = SystemExternalAIKeychain(backend: backend, operations: operations)
    operations.updateStatus = errSecSuccess
    try keychain.write(Data("replacement".utf8))
    #expect(operations.additions.isEmpty)
    for status in [errSecMissingEntitlement, errSecInteractionNotAllowed, errSecAuthFailed] {
        operations.updateStatus = status
        #expect(throws: ExternalAIError.credentialUnavailable) { try keychain.write(Data("replacement".utf8)) }
        #expect(operations.additions.isEmpty)
    }
    #expect(operations.updates.count == 4)
}

@Test func keychainFailuresStayRedactedAndNeverSwitchStores() throws {
    let operations = KeychainOperations()
    let keychain = SystemExternalAIKeychain(backend: .dataProtection, operations: operations)
    operations.addStatus = errSecMissingEntitlement
    #expect(throws: ExternalAIError.credentialUnavailable) { try keychain.write(Data("synthetic".utf8)) }
    #expect(operations.additions.count == 1)
    #expect(operations.additions.first?[kSecUseDataProtectionKeychain as String] as? Bool == true)
    operations.readStatus = errSecItemNotFound
    #expect(try keychain.read() == nil)
    operations.readStatus = errSecSuccess
    operations.readData = nil
    #expect(throws: ExternalAIError.credentialUnavailable) { try keychain.read() }
    operations.readStatus = errSecAuthFailed
    #expect(throws: ExternalAIError.credentialUnavailable) { try keychain.read() }
    operations.deleteStatus = errSecItemNotFound
    try keychain.delete()
    operations.deleteStatus = errSecAuthFailed
    #expect(throws: ExternalAIError.credentialUnavailable) { try keychain.delete() }
}

@Test func keychainUnknownSigningIdentityFailsBeforeAnyOperation() {
    let operations = KeychainOperations()
    let keychain = SystemExternalAIKeychain(backend: nil, operations: operations)
    #expect(throws: ExternalAIError.credentialUnavailable) { try keychain.read() }
    #expect(throws: ExternalAIError.credentialUnavailable) { try keychain.write(Data("synthetic".utf8)) }
    #expect(throws: ExternalAIError.credentialUnavailable) { try keychain.delete() }
    #expect(operations.reads.isEmpty && operations.updates.isEmpty
            && operations.additions.isEmpty && operations.deletions.isEmpty)
}
