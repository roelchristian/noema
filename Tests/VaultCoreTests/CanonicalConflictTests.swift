import Foundation
import Testing
@testable import VaultCore

@Test func canonicalConflictDispositionRetainsBytesAndChecksTargetRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteBlockStore(canonicalStagingURL: root.appendingPathComponent("blocks.sqlite"), vaultID: UUID())
    let pageID = UUID(), payload = Data("unique competing draft".utf8)
    let record = NoteRecord(id: pageID, title: "Page", aliases: [], tags: [], inlineTags: [], createdAt: "", updatedAt: "", body: "", relativePath: "sqlite/page", contentHash: "", originalHeader: nil)
    let initial = try await store.savePage(record: record, document: BlockDocument(blocks: [EditorBlock(runs: [RichRun("original")])]), condition: .createOnly)
    let conflict = try await store.preserveConflict(.init(targetID: pageID, targetKind: .page, baseRevision: initial.revision, preservedPayload: payload), expectedVaultRevision: try await store.canonicalVaultRevision())
    let changed = BlockDocument(blocks: [EditorBlock(runs: [RichRun("reviewed replacement")])])
    let stale = CanonicalPagePublication(record: record, document: changed, condition: .replace(expected: .init(token: Data("stale".utf8))))
    await #expect(throws: VaultError.self) {
        try await store.disposeConflict(id: conflict.conflict.id, expected: conflict.revision, disposition: .pagePublished, page: stale)
    }
    #expect(try await store.load(pageID: pageID) == initial)
    #expect(try await store.conflictSnapshot(id: conflict.conflict.id) == conflict)
    let publication = CanonicalPagePublication(record: record, document: changed, condition: .replace(expected: initial.revision))
    await #expect(throws: VaultError.self) {
        try await store.disposeConflict(id: conflict.conflict.id, expected: conflict.revision, disposition: .pagePublished, page: publication, validating: { throw VaultError.invalid("injected publication failure") })
    }
    #expect(try await store.load(pageID: pageID) == initial)
    let resolved = try await store.disposeConflict(id: conflict.conflict.id, expected: conflict.revision, disposition: .pagePublished, page: publication)
    #expect(resolved.conflict.preservedPayload == payload)
    #expect(resolved.disposition == .pagePublished)
    #expect(try await store.load(pageID: pageID).document == changed)
    await #expect(throws: VaultError.self) {
        try await store.disposeConflict(id: conflict.conflict.id, expected: conflict.revision, disposition: .retained)
    }
    let missing = try await store.preserveConflict(.init(targetID: UUID(), targetKind: .source, preservedPayload: payload), expectedVaultRevision: try await store.canonicalVaultRevision())
    let retained = try await store.disposeConflict(id: missing.conflict.id, expected: missing.revision, disposition: .retained)
    #expect(retained.conflict.preservedPayload == payload)
    try await store.close()
}
