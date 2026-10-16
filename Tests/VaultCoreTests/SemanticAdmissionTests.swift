import Foundation
import Testing
@testable import VaultCore

@Test func semanticFreshAdmissionRejectsUnknownDeclarationsBeforeCreation() async throws {
    var declaration = VaultCanonicalStorageDeclaration()
    #expect(declaration.isSupported)
    #expect(declaration.schemaVersion == SQLiteBlockStore.associationSchemaVersion)
    declaration.schemaVersion = 5
    declaration.requiredCapabilities = SQLiteBlockStore.semanticRequiredCapabilities
    #expect(!declaration.isSupported)
    declaration = VaultCanonicalStorageDeclaration()
    declaration.requiredCapabilities.append("futureRequired")
    #expect(!declaration.isSupported)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-admission-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite")
    #expect(throws: VaultError.self) {
        _ = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID(), requiredCapabilities: declaration.requiredCapabilities, schemaVersion: 5)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(throws: VaultError.self) {
        _ = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: UUID(), requiredCapabilities: SQLiteBlockStore.semanticRequiredCapabilities, schemaVersion: 6)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    let object = try await store.createObject(.init(typeKey: "question"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    try await store.close()
    let reopened = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopened.loadObject(id: object.object.id) == object)
    try await reopened.close()
}

@Test func semanticOpeningNeverUpgradesKnowledgeSchemaFour() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-transition-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
    let store = try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: url, vaultID: vaultID)
    let revision = try await store.canonicalVaultRevision()
    try await store.close()
    #expect(throws: VaultError.self) {
        _ = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    }
    let reopened = try VaultStorageProvider.plaintext.makeKnowledgeStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopened.canonicalVaultRevision() == revision)
    try await reopened.close()
}
