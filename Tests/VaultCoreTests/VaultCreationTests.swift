import Foundation
import Testing
@testable import VaultCore

private func creationParent() throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/CreationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func encryptedCreationRejectsBeforeWritingAnything() async throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    await #expect(throws: VaultError.self) {
        try await FileVaultRepository.createNewVault(parent: parent, name: "My Knowledge Vault", encryptionRequested: true)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
}

@Test func schema5CreationPublishesCompleteVaultAndPreservesCollision() async throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let vault = try await FileVaultRepository.createNewVault(parent: parent, name: " My Knowledge Vault ", encryptionRequested: false)
    #expect(vault.lastPathComponent == "My Knowledge Vault")
    #expect(Set(["vault.json", "blocks.sqlite", "Sources", "Removed Pages", "Conflicts"]).isSubset(of: Set(try FileManager.default.contentsOfDirectory(atPath: vault.path))))
    let before = try Data(contentsOf: vault.appendingPathComponent("vault.json"))
    let manager = VaultSessionManager()
    let opened = try await manager.openRepository(root: vault)
    #expect(opened.repository.manifest.storage?.schemaVersion == 6)
    let page = try await opened.repository.create(title: "Canonical", body: "Persisted")
    #expect(try await opened.repository.scan().notes.first?.id == page.id)
    try await opened.repository.sqliteBlockStore.close()
    try await manager.close()
    let reopened = try await manager.openRepository(root: vault)
    #expect(try await reopened.repository.scan().notes.first?.body.contains("Persisted") == true)
    try await reopened.repository.sqliteBlockStore.close()
    try await manager.close()
    await #expect(throws: VaultError.self) {
        try await FileVaultRepository.createNewVault(parent: parent, name: "My Knowledge Vault", encryptionRequested: false)
    }
    #expect(try Data(contentsOf: vault.appendingPathComponent("vault.json")) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["My Knowledge Vault"])
    let manifest = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
    #expect(manifest["encrypted"] == nil)
}

@Test func creationRejectsInvalidNamesAndMissingParentWithoutWrites() async throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    for name in ["", "  ", ".", "..", "../escaped", "nested/vault", "bad:name", "bad\nname", "bad\0name"] {
        await #expect(throws: VaultError.self) {
            try await FileVaultRepository.createNewVault(parent: parent, name: name, encryptionRequested: false)
        }
    }
    await #expect(throws: (any Error).self) {
        try await FileVaultRepository.createNewVault(parent: parent.appendingPathComponent("missing"), name: "Vault", encryptionRequested: false)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
}

@Test func creationPublicationCollisionPreservesInitializedStagingAndOccupiedDestination() async throws {
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
        _ = try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false, storageProvider: provider)
        Issue.record("Creation must reject publication over an occupied destination")
    } catch { message = error.localizedDescription }
    let stagedNames = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".noema-create-") }
    let stagedName = try #require(stagedNames.first)
    #expect(stagedNames.count == 1)
    let staging = parent.appendingPathComponent(stagedName)
    // macOS may report /tmp for an enumerated /private/tmp URL (or another symlinked parent).
    let prefix = "Staged content was preserved at "
    let pathStart = try #require(message.range(of: prefix)?.upperBound)
    let reportedSuffix = message[pathStart...]
    let pathEnd = try #require(reportedSuffix.range(of: ". ")?.lowerBound)
    let reportedStaging = URL(fileURLWithPath: String(reportedSuffix[..<pathEnd]))
    #expect(reportedStaging.resolvingSymlinksInPath() == staging.resolvingSymlinksInPath())
    let manifestBytes = try Data(contentsOf: staging.appendingPathComponent("vault.json"))
    #expect(try FileVaultRepository.inspectManifest(at: staging).storage?.schemaVersion == 6)
    #expect(try Data(contentsOf: staging.appendingPathComponent("vault.json")) == manifestBytes)
    #expect(try Data(contentsOf: destination.appendingPathComponent("external.txt")) == occupiedBytes)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("vault.json").path))
    // An explicit retry cannot create additional staging while the destination is occupied.
    await #expect(throws: VaultError.self) {
        try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix(".noema-create-") } == stagedNames)
}

@Test(arguments: [false, true])
func failedInitializationRemovesOnlyEmptyOwnedStaging(preservedContent: Bool) async throws {
    let parent = try creationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let bytes = Data("Potentially recoverable partial content".utf8)
    let provider = VaultStorageProvider { root in
        if preservedContent { try bytes.write(to: root.appendingPathComponent("partial.md")) }
        throw VaultError.storage("Injected initialization failure")
    }
    await #expect(throws: VaultError.self) {
        try await FileVaultRepository.createNewVault(parent: parent, name: "Vault", encryptionRequested: false, storageProvider: provider)
    }
    #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Vault").path))
    let children = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    #expect(children.count == (preservedContent ? 1 : 0))
    if preservedContent {
        let staging = parent.appendingPathComponent(try #require(children.first))
        #expect(try Data(contentsOf: staging.appendingPathComponent("partial.md")) == bytes)
    }
}

@Test func schema5ManifestPreservesOptionalFieldsAndRejectsIncompleteAuthority() throws {
    var manifest = VaultManifest()
    manifest.unknownFields = ["futureOptional": .object(["value": .string("retained")])]
    manifest.storage?.unknownFields = ["optionalPolicy": .string("retained")]
    let bytes = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(VaultManifest.self, from: bytes)
    #expect(decoded.isSupported)
    #expect(decoded.unknownFields == manifest.unknownFields)
    #expect(decoded.storage?.unknownFields == manifest.storage?.unknownFields)
    for version in [1, 2, 3, 4, 5] {
        manifest.storage?.schemaVersion = version
        #expect(!manifest.isSupported)
    }
    manifest.storage?.schemaVersion = 6
    manifest.storage?.requiredCapabilities.removeLast()
    #expect(!manifest.isSupported)
    manifest.storage = nil
    #expect(!manifest.isSupported)
}

@Test func historicalVaultRejectionDoesNotModifyExistingContent() throws {
    let root = try creationParent()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldManifest = Data("{\"formatVersion\":1,\"id\":\"\(UUID().uuidString)\"}".utf8)
    let oldPage = Data("Preserve unsupported content".utf8)
    try oldManifest.write(to: root.appendingPathComponent("vault.json"))
    try oldPage.write(to: root.appendingPathComponent("old.md"))
    #expect(throws: VaultError.self) { try FileVaultRepository.inspectManifest(at: root) }
    #expect(try Data(contentsOf: root.appendingPathComponent("vault.json")) == oldManifest)
    #expect(try Data(contentsOf: root.appendingPathComponent("old.md")) == oldPage)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["vault.json", "old.md"])
}
