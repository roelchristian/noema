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

@Test func creationPublicationCollisionPreservesInitializedStagingAndOccupiedDestination() throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let destination = parent.appendingPathComponent("Vault")
    let occupiedBytes = Data("External content must survive".utf8)
    let provider = VaultStorageProvider { root in
        // Occupy the destination after the creation preflight, before publication.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try occupiedBytes.write(to: destination.appendingPathComponent("external.txt"))
        return try VaultStorageProvider.plaintext.makeStore(root: root)
    }
    var message = ""
    do {
        _ = try FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false, storageProvider: provider)
        Issue.record("Creation must reject publication over an occupied destination")
    } catch { message = error.localizedDescription }
    let stagedNames = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".noema-create-") }
    let stagedName = try #require(stagedNames.first)
    #expect(stagedNames.count == 1)
    let staging = parent.appendingPathComponent(stagedName)
    #expect(message.contains(staging.path))
    let manifestBytes = try Data(contentsOf: staging.appendingPathComponent("vault.json"))
    #expect(try FileVaultRepository.open(root: staging).manifest.formatVersion == 1)
    #expect(try Data(contentsOf: staging.appendingPathComponent("vault.json")) == manifestBytes)
    #expect(try Data(contentsOf: destination.appendingPathComponent("external.txt")) == occupiedBytes)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("vault.json").path))
    // An explicit retry cannot create additional staging while the destination is occupied.
    #expect(throws: VaultError.self) {
        try FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".noema-create-") } == stagedNames)
}

@Test(arguments: [false, true])
func failedInitializationRemovesOnlyEmptyOwnedStaging(preservedContent: Bool) throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let bytes = Data("Potentially recoverable partial content".utf8)
    let provider = VaultStorageProvider { root in
        if preservedContent { try bytes.write(to: root.appendingPathComponent("partial.md")) }
        throw VaultError.storage("Injected initialization failure")
    }
    #expect(throws: VaultError.self) {
        try FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false, storageProvider: provider)
    }
    #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Vault").path))
    let children = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(children.count == (preservedContent ? 1 : 0))
    if preservedContent {
        let staging = parent.appendingPathComponent(try #require(children.first))
        #expect(try Data(contentsOf: staging.appendingPathComponent("partial.md")) == bytes)
    }
}
