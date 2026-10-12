import Foundation
import Testing
@testable import VaultCore

struct SQLiteRepositoryTests {
    private func fixture() async throws -> (URL, FileVaultRepository) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("noema-sqlite-repository-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: root, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, _, repository) = try await manager.openRepository(root: root)
        return (root, repository)
    }

    @Test func SQLiteCreateSaveReopenTrashRestoreAndRevisionChecks() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await repository.create(title: "Original", body: "A body")
        let saved = try await repository.save(note: note, title: "Renamed", body: "Changed body", tags: ["History"])
        #expect(saved.id == note.id)
        #expect(saved.aliases.contains("Original"))
        #expect(saved.tags == ["history"])
        do {
            _ = try await repository.save(note: note, title: "Stale", body: "Stale body", tags: [])
            Issue.record("A stale SQLite revision overwrote a page")
        } catch {}
        let reopened = try FileVaultRepository.open(root: root, sessionLease: repository.sessionLease, accessGate: repository.accessGate)
        #expect(try await reopened.scan().notes == [saved])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Wiki").path))
        try await repository.trash(note: saved)
        #expect(try await repository.scan().notes.isEmpty)
        let removed = try #require(try await repository.trashedPages().first)
        #expect(removed.note.id == note.id)
        try await repository.restore(removed)
        let restored = try #require(try await repository.scan().notes.first)
        #expect(restored.body == saved.body)
        try await repository.trash(note: restored)
        let latest = try #require(try await repository.trashedPages().first)
        try await repository.permanentlyDelete(latest)
        #expect(try await repository.trashedPages().isEmpty)
    }

    @Test func SQLiteAICompletionCannotOverwriteNewerContent() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await repository.create(title: "A page", body: "Before")
        let captured = try await repository.pageSummarySnapshot(note)
        let saved = try await repository.save(note: note, title: note.title, body: "Newer", tags: [])
        let provenance = SummaryProvenance(provider: "test", model: "test", generatedAt: Date())
        do {
            _ = try await repository.publishPageSummary(captured, summary: "Delayed", provenance: provenance, validate: {})
            Issue.record("Delayed AI publication overwrote a newer revision")
        } catch {}
        #expect(try await repository.scan().notes == [saved])
        let fresh = try await repository.pageSummarySnapshot(saved)
        let enriched = try await repository.publishPageSummary(fresh, summary: "Current summary", provenance: provenance, validate: {})
        #expect(BlockDocumentCodec.decode(enriched.body).aiSummary != nil)
        let current = try await repository.pageSummarySnapshot(enriched)
        await #expect(throws: VaultError.self) {
            _ = try await repository.publishPageSummary(current, summary: "Revoked publication", provenance: provenance, validate: {
                throw VaultError.invalid("Publication authority revoked")
            })
        }
        #expect(try await repository.scan().notes == [enriched])
    }

    @Test func SQLiteGatedAccessLocksAndDerivedSearchSurviveReopening() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try await repository.create(title: "Target", body: "Destination")
        var note = try await repository.create(title: "Linked", body: "[[Target]] #Research")
        #expect(note.inlineTags == ["research"])
        let source = try await repository.importSource(data: Data("Original source".utf8), filename: "reference.txt", title: "Reference", originURL: nil)
        let sourceBytes = try Data(contentsOf: root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename))
        note = try await repository.setSourceReference(note: note, sourceID: source.id, linked: true)
        note = try await repository.setEditingLock(note: note, locked: true)
        await #expect(throws: VaultError.self) {
            _ = try await repository.save(note: note, title: note.title, body: "Forbidden", tags: [])
        }
        note = try await repository.setEditingLock(note: note, locked: false)
        note = try await repository.save(note: note, title: "Linked renamed", body: "[[Target]] #Science", tags: ["Explicit"])
        #expect(note.inlineTags == ["science"])
        let reopened = try FileVaultRepository.open(root: root, sessionLease: repository.sessionLease, accessGate: repository.accessGate)
        let batch = try await reopened.scan()
        let restored = try #require(batch.notes.first { $0.id == note.id })
        #expect(restored.linkedSourceIDs == [source.id])
        #expect(!restored.isEditingLocked)
        let index = try SQLiteSearchIndex(url: root.appendingPathComponent("derived-search.sqlite"))
        try await index.reconcile(batch)
        #expect(try await index.backlinks(to: target) == [note.id])
        #expect(try await index.search("Science", kind: .wiki, tag: "science").map(\.id) == [note.id])
        #expect(try Data(contentsOf: root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename)) == sourceBytes)
        await #expect(throws: VaultAccessError.self) {
            _ = try FileVaultRepository.open(root: root)
        }
        let gate = try #require(repository.accessGate)
        gate.updateState(.closed)
        await #expect(throws: VaultAccessError.self) { _ = try await repository.scan() }
        await #expect(throws: VaultAccessError.self) { _ = try await repository.save(note: restored, title: restored.title, body: "Revoked", tags: []) }
    }

    @Test func SQLiteModePreservesAndRestoresPreMigrationMarkdownTrash() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let removedAt = Date().addingTimeInterval(-3600)
        let path = "Removed Pages/trash-\(Int(removedAt.timeIntervalSince1970))-legacy.md"
        let note = NoteRecord(id: UUID(), title: "Legacy removed page", aliases: ["Old title"], tags: ["kept"], inlineTags: [], createdAt: "old", updatedAt: "new", body: "Legacy content", relativePath: path, contentHash: "", originalHeader: "future_field: retained")
        try NoteCodec.encode(note).write(to: root.appendingPathComponent(path))
        let removed = try #require(try await repository.trashedPages().first)
        #expect(removed.id == path)
        #expect(try await repository.scan().notes.isEmpty)
        try await repository.restore(removed)
        let restored = try #require(try await repository.scan().notes.first)
        #expect(restored.id == note.id)
        #expect(restored.aliases == note.aliases)
        #expect(restored.originalHeader?.contains("future_field: retained") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        #expect(try await repository.trashedPages().isEmpty)
    }

    @Test func explicitMarkdownRoundTripPreservesIDsAndMetadata() async throws {
        let (root, repository) = try await fixture()
        let (otherRoot, other) = try await fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let original = try await repository.create(title: "Portable", body: "# Heading\n\nA **bold** paragraph\n\n| raw | table |")
        let exported = try await repository.exportMarkdown(pageID: original.id)
        #expect(exported.warnings.isEmpty)
        let imported = try await other.importMarkdown(exported.data, filename: exported.filename)
        #expect(imported.id == original.id)
        #expect(BlockDocumentCodec.decode(imported.body).flattened.map(\.id) == BlockDocumentCodec.decode(original.body).flattened.map(\.id))
        #expect(BlockDocumentCodec.readable(BlockDocumentCodec.decode(imported.body)).contains("| raw | table |"))
        await #expect(throws: VaultError.self) {
            _ = try await other.importMarkdown(exported.data, filename: exported.filename)
        }
        let readable = try await repository.exportMarkdown(pageID: original.id, format: .readable)
        #expect(!readable.warnings.isEmpty)
        #expect(!String(decoding: readable.data, as: UTF8.self).contains("noema:document"))
        #expect(try await repository.exportVaultMarkdown().map(\.pageID) == [original.id])
    }

    @Test func externalMarkdownRequiresExplicitRevisionCheckedImport() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repository.create(title: "External", body: "Before")
        let exported = try await repository.exportMarkdown(pageID: original.id)
        let changed = String(decoding: exported.data, as: UTF8.self).replacingOccurrences(of: "Before", with: "Externally edited")
        try Data(changed.utf8).write(to: root.appendingPathComponent("Wiki/export.md"))
        #expect(try await repository.scan().notes.first?.body == original.body)
        let imported = try await repository.importMarkdown(Data(changed.utf8), filename: exported.filename, disposition: .replace(expected: original))
        #expect(BlockDocumentCodec.readable(BlockDocumentCodec.decode(imported.body)).contains("Externally edited"))
        #expect(BlockDocumentCodec.decode(imported.body).recoveredMetadata != nil)
        await #expect(throws: Error.self) {
            _ = try await repository.importMarkdown(exported.data, filename: exported.filename, disposition: .replace(expected: original))
        }
        let locked = try await repository.setEditingLock(note: imported, locked: true)
        await #expect(throws: VaultError.self) {
            _ = try await repository.importMarkdown(exported.data, filename: exported.filename, disposition: .replace(expected: locked))
        }
    }

}
