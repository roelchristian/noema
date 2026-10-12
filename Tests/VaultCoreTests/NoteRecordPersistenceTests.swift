import Foundation
import Testing
@testable import VaultCore

@Test func canonicalPageMetadataPreservesUnknownValuesAcrossReplacement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultID = UUID()
    let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
    var note = NoteRecord(id: UUID(), title: "Before", aliases: [], tags: [], inlineTags: [],
        createdAt: "2026-10-12", updatedAt: "2026-10-12", body: "", relativePath: "sqlite/page", contentHash: "", originalHeader: nil)
    note.unknownFields["futureOptional"] = .object(["array": .array([.null, .bool(true), .number(Decimal(42))])])
    note.extensions = .init(properties: ["provenance": .object(["provider": .string("accepted")])])
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("unchanged")])])
    let initial = try await store.savePage(record: note, document: document, condition: .createOnly)
    var loaded = try await store.loadPage(pageID: note.id).record
    #expect(loaded.unknownFields == note.unknownFields)
    #expect(loaded.extensions == note.extensions)
    loaded.title = "After"
    _ = try await store.savePage(record: loaded, document: document, condition: .replace(expected: initial.revision))
    try await store.close()
    let reopened = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID, createIfMissing: false)
    let final = try await reopened.loadPage(pageID: note.id).record
    #expect(final.title == "After")
    #expect(final.unknownFields == note.unknownFields)
    #expect(final.extensions == note.extensions)
    try await reopened.close()
}

@Test func canonicalAnnotationsSurviveTrashRestoreAndRefuseDestructivePurge() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"), vaultID: UUID())
    let pageID = UUID(), block = EditorBlock(runs: [RichRun("word")])
    let target = try InlineAnnotationTarget(text: block.text, range: NSRange(location: 0, length: 4), revision: Data())
    let annotation = InlineAnnotation(pageID: pageID, blockID: block.id, designation: "term", expectedRevision: Data(), target: target)
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(annotation))
    var document = BlockDocument(blocks: [block]); document.extensions = .init(properties: ["annotations": .array([value])])
    let initial = try await store.save(document, pageID: pageID, condition: .createOnly)
    let trash = try await store.setTrashed(pageID: pageID, expected: initial.revision, trashed: true)
    try trash.document.validatingAnnotations(pageID: pageID, expectedRevision: trash.revision)
    let collection = try await store.canonicalVaultRevision()
    await #expect(throws: VaultError.self) {
        try await store.purgeCanonicalEntity(id: pageID, kind: .page, expected: trash.revision, expectedVaultRevision: collection)
    }
    #expect(try await store.load(pageID: pageID) == trash)
    let restored = try await store.setTrashed(pageID: pageID, expected: trash.revision, trashed: false)
    try restored.document.validatingAnnotations(pageID: pageID, expectedRevision: restored.revision)
    _ = try await store.save(restored.document, pageID: pageID, condition: .replace(expected: restored.revision))
    try await store.close()
}
