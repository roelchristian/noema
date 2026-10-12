import Foundation
import Testing
@testable import VaultCore

@Test func knowledgeCatalogueIncludesUnassociatedTargetsWithoutInventingContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-catalogue-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: UUID())
    let first = try await store.createEntity(.init(typeKey: "person", label: "Same name"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let second = try await store.createEntity(.init(typeKey: "person", label: "Same name"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let object = try await store.createObject(.init(typeKey: "question", properties: .init(properties: ["questionText": .string("An independent question")])), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let catalogue = try await store.knowledgeCatalogue()
    #expect(Set(catalogue.entities.map { $0.entity.id }) == [first.entity.id, second.entity.id])
    #expect(catalogue.objects == [object])
    #expect(catalogue.annotations.isEmpty)
    #expect(try await store.allPages().isEmpty)
    #expect(catalogue.vaultRevision == (try await store.canonicalVaultRevision()))
    try await store.close()
}
