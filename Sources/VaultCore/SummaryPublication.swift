import Foundation
import Darwin

/// Exact local snapshot used for compare-and-swap publication. Never sent to a provider.
public struct PageSummarySnapshot: Sendable {
    public let note: NoteRecord
    let bytes: Data
    let token: VaultContentChangeToken?
}
public struct SourceSummarySnapshot: Sendable {
    public let source: SourceRecord
    /// Original bytes permit complete extraction, including PDFs, without using cached excerpts.
    public let original: Data
    let metadataBytes: Data
    let metadataToken: VaultContentChangeToken?
    let originalToken: VaultContentChangeToken?
}

extension FileVaultRepository {
    public func pageSummarySnapshot(_ note: NoteRecord) throws -> PageSummarySnapshot {
        try Task.checkCancellation()
        let before = try contentStore.changeToken(at: note.relativePath)
        let bytes = try contentStore.read(at: note.relativePath)
        let after = try contentStore.changeToken(at: note.relativePath)
        guard before == after else { throw VaultContentStoreError.stale(note.relativePath) }
        let actual = try NoteCodec.decode(bytes, path: note.relativePath, vaultID: manifest.id)
        guard actual.id == note.id, actual.contentHash == note.contentHash, actual.body == note.body,
              !actual.isEditingLocked else { throw VaultContentStoreError.stale(note.relativePath) }
        return PageSummarySnapshot(note: actual, bytes: bytes, token: after)
    }

    public func sourceSummarySnapshot(id: UUID) throws -> SourceSummarySnapshot {
        try Task.checkCancellation()
        let source = try loadSource(id: id, verifyOriginal: true)
        let path = "Sources/" + id.uuidString.lowercased() + "/metadata.json"
        let metadataBefore = try contentStore.changeToken(at: path)
        let bytes = try contentStore.read(at: path)
        let metadataAfter = try contentStore.changeToken(at: path)
        guard metadataBefore == metadataAfter else { throw VaultContentStoreError.stale(path) }
        let metadata = try JSONDecoder().decode(SourceMetadata.self, from: bytes)
        guard metadata.id == source.id, metadata.aiSummary == source.metadata.aiSummary,
              metadata.sha256 == source.metadata.sha256 else { throw VaultContentStoreError.stale(path) }
        let originalBefore = try summaryOriginalToken(source)
        let original = try Self.readSourceOriginal(source, root: root, contentStore: contentStore)
        let originalAfter = try summaryOriginalToken(source)
        guard originalBefore == originalAfter else { throw VaultContentStoreError.stale(path) }
        return SourceSummarySnapshot(source: SourceRecord(metadata: metadata, body: source.body),
            original: original, metadataBytes: bytes, metadataToken: metadataAfter, originalToken: originalAfter)
    }

    /// The actor rechecks content and prior summary immediately before a conditional write.
    /// `validate` checks external authorization immediately at the canonical write.
    public func publishPageSummary(_ snapshot: PageSummarySnapshot, summary: String,
        provenance: SummaryProvenance, validate: @Sendable () throws -> Void
    ) throws -> NoteRecord {
        try Task.checkCancellation()
        let path = snapshot.note.relativePath
        guard try contentStore.read(at: path) == snapshot.bytes,
              try contentStore.changeToken(at: path) == snapshot.token else { throw VaultContentStoreError.stale(path) }
        var updated = snapshot.note
        var document = BlockDocumentCodec.decode(updated.body)
        guard !document.unsupportedVersion else { throw VaultContentStoreError.stale(path) }
        document.setAISummary(summary)
        document.blocks[0].metadata.extra["aiProvider"] = provenance.provider
        document.blocks[0].metadata.extra["aiModel"] = provenance.model
        document.blocks[0].metadata.extra["aiGeneratedAt"] = ISO8601DateFormatter().string(from: provenance.generatedAt)
        updated.body = BlockDocumentCodec.encode(document)
        updated.updatedAt = ISO8601DateFormatter().string(from: Date())
        let data = try NoteCodec.encode(updated)
        try Task.checkCancellation()
        try validate()
        try contentStore.write(data, at: path, condition: .replace(expected: snapshot.bytes))
        invalidateSummaryCaches(pagePath: path, sourceID: nil)
        return try NoteCodec.decode(data, path: path, vaultID: manifest.id)
    }

    public func publishSourceSummary(_ snapshot: SourceSummarySnapshot, summary: String,
        provenance: SummaryProvenance, validate: @Sendable () throws -> Void
    ) throws -> SourceRecord {
        try Task.checkCancellation()
        let source = snapshot.source
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        guard try contentStore.read(at: path) == snapshot.metadataBytes,
              try contentStore.changeToken(at: path) == snapshot.metadataToken,
              try summaryOriginalToken(source) == snapshot.originalToken,
              try Self.readSourceOriginal(source, root: root, contentStore: contentStore) == snapshot.original,
              try summaryOriginalToken(source) == snapshot.originalToken else {
            throw VaultContentStoreError.stale(path)
        }
        var metadata = try JSONDecoder().decode(SourceMetadata.self, from: snapshot.metadataBytes)
        guard metadata.id == source.id, metadata.aiSummary == source.metadata.aiSummary else {
            throw VaultContentStoreError.stale(path)
        }
        metadata.aiSummary = summary; metadata.aiSummaryProvenance = provenance
        let data = try JSONEncoder().encode(metadata)
        try Task.checkCancellation()
        try validate()
        try contentStore.write(data, at: path, condition: .replace(expected: snapshot.metadataBytes))
        invalidateSummaryCaches(pagePath: nil, sourceID: source.id)
        return SourceRecord(metadata: metadata, body: source.body, availabilityIssue: source.availabilityIssue)
    }

    private func summaryOriginalToken(_ source: SourceRecord) throws -> VaultContentChangeToken? {
        if let bookmark = source.metadata.linkedBookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            guard !stale else { throw VaultError.unavailable("Linked source permission expired.") }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Linked files have external ownership; inode and ctime detect replacement/ABA.
            var info = stat()
            guard stat(url.path, &info) == 0 else { throw VaultError.unavailable("Linked source is unavailable.") }
            return VaultContentChangeToken(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
        }
        return try contentStore.changeToken(at: "Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename)
    }
}
