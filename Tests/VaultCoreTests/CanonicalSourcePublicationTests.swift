import Foundation
import CryptoKit
import Testing
@testable import VaultCore

private func publicationRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-publication-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func publicationMetadata(_ data: Data) -> SourceMetadata {
    SourceMetadata(id: UUID(), title: "Original", capturedAt: "2026-10-12", originalFilename: "original.txt", originURL: nil,
                   sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), fileSize: data.count, storedFilename: "original.txt")
}

@Test func canonicalOriginalReceiptIsBoundToOperationAndRetainsEvidence() async throws {
    let root = try publicationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("immutable source".utf8), metadata = publicationMetadata(Data("immutable source".utf8)), vaultID = UUID(), operationID = UUID()
    let adapter = try PlaintextVaultContentStore(root: root)
    let receipt = try adapter.publishCanonicalOriginal(bytes, metadata: metadata, vaultID: vaultID, operationID: operationID)
    let source = try CanonicalSource(metadata: metadata)
    #expect(try source.sourceMetadata() == metadata)
    #expect(throws: VaultError.self) { try receipt.validate(source: source, vaultID: vaultID, operationID: UUID()) }
    #expect(throws: VaultContentStoreError.self) { try adapter.publishCanonicalOriginal(bytes, metadata: metadata, vaultID: vaultID, operationID: UUID()) }
    let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    let revision = try await store.canonicalVaultRevision()
    let outcome = try await store.publishSourceAndPage(source: source, condition: .createOnly, operationID: operationID, expectedVaultRevision: revision, byteReceipt: receipt)
    #expect(try await store.sourceSnapshot(id: metadata.id).source == source)
    #expect(try await store.committedOperation(id: operationID) == outcome)
    #expect(try adapter.read(at: "Source Publications/" + operationID.uuidString.lowercased() + ".json").count > 0)
    try await store.close()
}

@Test func canonicalOriginalReceiptRechecksBytesAndCannotPublishCorruption() async throws {
    let root = try publicationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("original".utf8), metadata = publicationMetadata(Data("original".utf8)), vaultID = UUID(), operationID = UUID()
    let adapter = try PlaintextVaultContentStore(root: root)
    let receipt = try adapter.publishCanonicalOriginal(data, metadata: metadata, vaultID: vaultID, operationID: operationID)
    let source = try CanonicalSource(metadata: metadata)
    let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    let revision = try await store.canonicalVaultRevision()
    try adapter.write(Data("corrupt".utf8), at: source.original!.blobPath!, condition: .replace(expected: data))
    await #expect(throws: VaultError.self) { try await store.publishSourceAndPage(source: source, condition: .createOnly, operationID: operationID, expectedVaultRevision: revision, byteReceipt: receipt) }
    #expect(try await store.sourceSnapshots().isEmpty)
    #expect(try await store.committedOperation(id: operationID) == nil)
    try await store.close()
}

@Test func canonicalOriginalRejectsWrongChecksumSizeAndUnknownSyncProvider() throws {
    let root = try publicationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("original".utf8), adapter = try PlaintextVaultContentStore(root: root)
    var metadata = publicationMetadata(bytes); metadata.fileSize = bytes.count + 1
    #expect(throws: VaultError.self) { try adapter.publishCanonicalOriginal(bytes, metadata: metadata, vaultID: UUID(), operationID: UUID()) }
}

@Test func canonicalSourceReplacementPreservesUnknownMetadataAndImmutableDescriptor() async throws {
    let root = try publicationRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("immutable".utf8), vaultID = UUID(), operation = UUID()
    var metadata = publicationMetadata(data)
    metadata.unknownFields["future"] = .object(["items": .array([.bool(true), .null])])
    let adapter = try PlaintextVaultContentStore(root: root)
    let receipt = try adapter.publishCanonicalOriginal(data, metadata: metadata, vaultID: vaultID, operationID: operation)
    let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    let created = try await store.publishSourceAndPage(source: CanonicalSource(metadata: metadata), condition: .createOnly,
        operationID: operation, expectedVaultRevision: try await store.canonicalVaultRevision(), byteReceipt: receipt)
    #expect(try await store.sourceSnapshot(id: metadata.id).source.sourceMetadata().unknownFields == metadata.unknownFields)
    let oldPath = "Sources/" + metadata.id.uuidString.lowercased() + "/" + metadata.storedFilename
    try adapter.write(Data("changed".utf8), at: oldPath, condition: .replace(expected: data))
    var changed = metadata; changed.sha256 = digest(Data("changed".utf8)); changed.fileSize = 7
    let second = UUID()
    let changedReceipt = try adapter.verifyCanonicalOriginal(metadata: changed, vaultID: vaultID, operationID: second)
    await #expect(throws: VaultError.self) {
        try await store.publishSourceAndPage(source: CanonicalSource(metadata: changed), condition: .replace(expected: created.sourceRevision),
            operationID: second, expectedVaultRevision: try await store.canonicalVaultRevision(), byteReceipt: changedReceipt)
    }
    #expect(try await store.sourceSnapshot(id: metadata.id).revision == created.sourceRevision)
    try await store.close()
}
