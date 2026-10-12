import Foundation
import Yams

public enum MarkdownExportFormat: Sendable {
    /// Readable Markdown plus Noema frontmatter and the versioned document envelope.
    case noema
    /// Conventional Markdown body. Stable identities and editor metadata are omitted.
    case readable
}

public struct MarkdownPageExport: Sendable {
    public let pageID: UUID
    public let filename: String
    public let data: Data
    public let warnings: [String]
}

public enum MarkdownImportDisposition: Sendable {
    /// Recognised page and block identities are retained; an occupied identity fails.
    case createOnly
    /// Explicit replacement requires the captured canonical revision, never an export hash.
    case replace(expected: NoteRecord)
}

public extension FileVaultRepository {
    /// Exports canonical content, never an implicit editor draft or an autosave mirror.
    func exportMarkdown(pageID: UUID, format: MarkdownExportFormat = .noema) async throws -> MarkdownPageExport {
        try validateAccess(operation: "exportMarkdown")
        let note: NoteRecord
        if let sqliteBlockStore {
            note = try await sqliteBlockStore.loadPage(pageID: pageID).record
        } else {
            guard let found = try await scan().notes.first(where: { $0.id == pageID }) else {
                throw VaultError.unavailable("Page is missing.")
            }
            note = found
        }
        try Task.checkCancellation()
        try validateAccess(operation: "exportMarkdown.publish")
        return try Self.markdownExport(note, format: format)
    }

    /// Exports all live pages from one SQLite read transaction. This is a page
    /// interchange bundle, not a backup of sources, trash, recovery or vault policy.
    func exportVaultMarkdown(format: MarkdownExportFormat = .noema) async throws -> [MarkdownPageExport] {
        try validateAccess(operation: "exportVaultMarkdown")
        let notes: [NoteRecord]
        if let sqliteBlockStore { notes = try await sqliteBlockStore.allPages() }
        else { notes = try await scan().notes }
        let exports = try notes.map { try Self.markdownExport($0, format: format) }
        try Task.checkCancellation()
        try validateAccess(operation: "exportVaultMarkdown.publish")
        return exports
    }

    /// External file edits have no authority until this operation is explicitly
    /// invoked. A replacement uses the same optimistic revision checks as editing.
    @discardableResult
    func importMarkdown(_ data: Data, filename: String,
                        disposition: MarkdownImportDisposition = .createOnly) async throws -> NoteRecord {
        try Task.checkCancellation()
        try validateAccess(operation: "importMarkdown")
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        var imported = try NoteCodec.decode(data, path: "Wiki/" + safeName, vaultID: manifest.id)
        guard !imported.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultError.invalid("A wiki page needs a title.")
        }
        let document = BlockDocumentCodec.decode(imported.body)
        guard !document.unsupportedVersion, BlockDocumentCodec.valid(document) else {
            throw VaultError.invalid("Unsupported Noema document metadata. Keep the original Markdown for recovery.")
        }
        // Always persist the envelope, including plain imports, so the new block
        // identities become stable rather than being regenerated on each export.
        var preserved = document
        preserved.originalSource = nil
        imported.body = BlockDocumentCodec.encode(preserved)
        switch disposition {
        case .replace(let expected):
            guard !expected.isEditingLocked else { throw VaultError.invalid("Unlock this article before importing.") }
            // NoteCodec's fallback ID is path-derived. Only a declared Noema ID
            // constrains explicit replacement of an existing page.
            let header = try imported.originalHeader.flatMap { try Yams.compose(yaml: $0) }
            if header?["id"] == nil { imported.id = expected.id }
            guard imported.id == expected.id else { throw VaultError.invalid("Imported page identity does not match the selected page.") }
            // Re-read to enforce a lock enabled since the captured revision.
            guard let current = try await scan().notes.first(where: { $0.id == expected.id }),
                  !current.isEditingLocked else { throw VaultError.invalid("Page is missing or locked.") }
            imported.relativePath = expected.relativePath
            imported.contentHash = expected.contentHash
            return try await save(note: imported, title: imported.title, body: imported.body, tags: imported.tags)
        case .createOnly:
            let existing = try await scan().notes
            guard !existing.contains(where: { $0.id == imported.id }) else {
                throw VaultError.conflict("This page already exists. Explicitly select a revision to replace it.")
            }
            guard !existing.contains(where: { normalized($0.title) == normalized(imported.title) }) else {
                throw VaultError.duplicateTitle(imported.title)
            }
            if imported.createdAt.isEmpty { imported.createdAt = timestamp() }
            if imported.updatedAt.isEmpty { imported.updatedAt = imported.createdAt }
            imported.relativePath = "Wiki/" + imported.id.uuidString.lowercased() + ".md"
            try Task.checkCancellation()
            try validateAccess(operation: "importMarkdown.publish")
            if let sqliteBlockStore {
                imported.relativePath = "sqlite/" + imported.id.uuidString.lowercased()
                _ = try await sqliteBlockStore.savePage(record: imported, document: preserved, condition: .createOnly)
                return try await sqliteBlockStore.loadPage(pageID: imported.id).record
            }
            let encoded = try NoteCodec.encode(imported)
            try contentStore.write(encoded, at: imported.relativePath, condition: .createOnly)
            return try NoteCodec.decode(encoded, path: imported.relativePath, vaultID: manifest.id)
        }
    }

    private static func markdownExport(_ note: NoteRecord, format: MarkdownExportFormat) throws -> MarkdownPageExport {
        var document = BlockDocumentCodec.decode(note.body)
        let bytes: Data
        let warnings: [String]
        switch format {
        case .noema:
            document.originalSource = document.unsupportedVersion ? document.originalSource : nil
            var exported = note
            exported.body = BlockDocumentCodec.encode(document)
            bytes = try NoteCodec.encode(exported)
            warnings = document.unsupportedVersion ? ["Unsupported metadata is retained; this client cannot validate a lossless round-trip."] : []
        case .readable:
            bytes = Data(BlockDocumentCodec.readable(document).utf8)
            warnings = ["Readable export omits page and block identities, metadata and editor-only semantics. Keep a Noema export for lossless recovery."]
        }
        return MarkdownPageExport(pageID: note.id, filename: note.id.uuidString.lowercased() + ".md", data: bytes, warnings: warnings)
    }
}
