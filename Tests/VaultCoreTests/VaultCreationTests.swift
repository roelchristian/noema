import Foundation
import Testing
@testable import VaultCore

private func creationParent() throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/CreationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func encryptedCreationRejectsBeforeWritingAnything() throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    #expect(throws: VaultError.self) {
        try FileVaultRepository.createNewVault(parent: parent, name: "My Knowledge Vault", encryptionRequested: true)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
}

@Test func plaintextCreationPublishesCompleteVaultAndPreservesCollision() throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let vault = try FileVaultRepository.createNewVault(parent: parent, name: " My Knowledge Vault ", encryptionRequested: false)
    #expect(vault.lastPathComponent == "My Knowledge Vault")
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: vault.path)) == Set(["vault.json", "Wiki", "Sources", "Removed Pages", "Conflicts"]))
    let before = try Data(contentsOf: vault.appendingPathComponent("vault.json"))
    #expect(try FileVaultRepository.open(root: vault).manifest.formatVersion == 1)
    #expect(throws: VaultError.self) {
        try FileVaultRepository.createNewVault(parent: parent, name: "My Knowledge Vault", encryptionRequested: false)
    }
    #expect(try Data(contentsOf: vault.appendingPathComponent("vault.json")) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["My Knowledge Vault"])
    let manifest = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
    #expect(manifest["encrypted"] == nil)
}

@Test func creationRejectsInvalidNamesAndMissingParentWithoutWrites() throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    for name in ["", "  ", ".", "..", "../escaped", "nested/vault", "bad:name", "bad\nname", "bad\0name"] {
        #expect(throws: VaultError.self) {
            try FileVaultRepository.createNewVault(parent: parent, name: name, encryptionRequested: false)
        }
    }
    #expect(throws: (any Error).self) {
        try FileVaultRepository.createNewVault(parent: parent.appendingPathComponent("missing"), name: "Vault", encryptionRequested: false)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
}
