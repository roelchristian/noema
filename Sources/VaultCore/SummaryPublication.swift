import Foundation
import Darwin

/// Exact local snapshot used for compare-and-swap publication. Never sent to a provider.
public struct PageSummarySnapshot: Sendable {
    public let note: NoteRecord
    public var sourceRevision: String {
        digest(Data(BlockDocumentCodec.readable(BlockDocumentCodec.decode(note.body).withoutAISummary).utf8))
    }
}
public struct SourceSummarySnapshot: Sendable {
    public let source: SourceRecord
    /// Original bytes permit complete extraction, including PDFs, without using cached excerpts.
    public let original: Data
    public var sourceRevision: String { digest(original) }
    let originalToken: VaultContentChangeToken?
    var canonicalRevision: BlockStoreRevision? = nil
}

extension FileVaultRepository {
    public func pageSummarySnapshot(_ note: NoteRecord) async throws -> PageSummarySnapshot {
        try validateAccess(operation: "pageSummarySnapshot")
        try Task.checkCancellation()
        let actual = try await sqliteBlockStore.loadPage(pageID: note.id).record
        guard actual.contentHash == note.contentHash, actual.body == note.body, !actual.isEditingLocked else { throw VaultContentStoreError.stale(note.relativePath) }
        return PageSummarySnapshot(note: actual)
    }

    public func sourceSummarySnapshot(id: UUID) async throws -> SourceSummarySnapshot {
        try validateAccess(operation: "sourceSummarySnapshot")
        try Task.checkCancellation()
        let source = try await loadSource(id: id, verifyOriginal: true)
        let captured = try await canonicalSourceMetadata(id: id)
        let before = try summaryOriginalToken(source)
        let original = try Self.readSourceOriginal(source, root: root, contentStore: contentStore)
        let after = try summaryOriginalToken(source)
        guard before == after, try await canonicalSourceMetadata(id: id).revision == captured.revision else {
            throw VaultContentStoreError.stale("canonical source")
        }
        return SourceSummarySnapshot(source: SourceRecord(metadata: captured.metadata, body: source.body),
            original: original, originalToken: after, canonicalRevision: captured.revision)
    }

    /// The actor rechecks content and prior summary immediately before a conditional write.
    /// `validate` checks external authorization immediately at the canonical write.
    public func publishPageSummary(_ snapshot: PageSummarySnapshot, summary: String,
        provenance: SummaryProvenance, validate: @escaping @Sendable () throws -> Void
    ) async throws -> NoteRecord {
        try validateAccess(operation: "publishPageArtifact")
        try Task.checkCancellation()
        let path = snapshot.note.relativePath

        var updated = snapshot.note
        var document = BlockDocumentCodec.decode(updated.body)
        guard !document.unsupportedVersion else { throw VaultContentStoreError.stale(path) }
        document.setAISummary(summary)
        document.blocks[0].metadata.extra["aiProvider"] = provenance.provider
        document.blocks[0].metadata.extra["aiModel"] = provenance.model
        document.blocks[0].metadata.extra["aiGeneratedAt"] = ISO8601DateFormatter().string(from: provenance.generatedAt)
        document.blocks[0].metadata.extra["aiSourceRevision"] = provenance.sourceRevision ?? snapshot.sourceRevision
        updated.body = BlockDocumentCodec.encode(document)
        updated.updatedAt = ISO8601DateFormatter().string(from: Date())
        try Task.checkCancellation()
        try validate()
        try validateAccess(operation: "publishArtifact.write")
        updated.inlineTags = MarkdownService.analyze(updated.body).tags
        _ = try await sqliteBlockStore.savePage(record: updated, document: document, condition: .replace(expected: sqliteRevision(snapshot.note)), validating: validate)
        let saved = try await sqliteBlockStore.loadPage(pageID: updated.id).record
        emitAIPageChange(saved, previous: snapshot.note, origin: .aiPublication)
        return saved
    }

    public func publishSourceSummary(_ snapshot: SourceSummarySnapshot, summary: String,
        provenance: SummaryProvenance, validate: @escaping @Sendable () throws -> Void
    ) async throws -> SourceRecord {
        try validateAccess(operation: "publishSourceArtifact")
        try Task.checkCancellation()
        var metadata = snapshot.source.metadata
        var provenance = provenance
        provenance.sourceRevision = provenance.sourceRevision ?? snapshot.sourceRevision
        metadata.aiSummary = summary; metadata.aiSummaryProvenance = provenance
        return try await publishSourceMetadata(snapshot, metadata: metadata, validate: validate)
    }

    /// Publishes all generated artifacts in one conditional canonical write. A nil classification
    /// explicitly means unavailable; legacy/manual values survive until enrichment occurs.
    public func publishPageEnrichment(_ snapshot: PageSummarySnapshot, summary: String,
        classification: LCCClassification?, title: String? = nil, provenance: SummaryProvenance,
        validate: @escaping @Sendable () throws -> Void
    ) async throws -> NoteRecord {
        let provenance = try enrichmentProvenance(provenance, revision: snapshot.sourceRevision)
        let classification = try verifiedClassification(classification, provenance: provenance)
        var updated = snapshot.note
        if let title, needsGeneratedTitle(updated.title) {
            updated.title = try acceptedTitle(title)
            let otherNotes = try await scan().notes.filter { $0.id != updated.id }
            try requireUniqueTitle(updated.title, in: otherNotes)
            if normalized(updated.title) != normalized(snapshot.note.title), !snapshot.note.title.isEmpty,
               !updated.aliases.contains(snapshot.note.title) { updated.aliases.append(snapshot.note.title) }
            updated.aiTitleProvenance = provenance
        }
        updated.body = try enrichedBody(updated.body, summary: summary, provenance: provenance)
        updated.lcc = classification?.code
        updated.lccClassification = classification
        updated.aiLCCProvenance = classification == nil ? nil : provenance
        return try await publishPageMetadata(snapshot, updated: updated, validate: validate)
    }

    public func publishSourceEnrichment(_ snapshot: SourceSummarySnapshot, summary: String,
        classification: LCCClassification?, title: String? = nil, provenance: SummaryProvenance,
        validate: @escaping @Sendable () throws -> Void
    ) async throws -> SourceRecord {
        let provenance = try enrichmentProvenance(provenance, revision: snapshot.sourceRevision)
        let classification = try verifiedClassification(classification, provenance: provenance)
        var metadata = snapshot.source.metadata
        if let title, needsGeneratedTitle(metadata.title) {
            metadata.title = try acceptedTitle(title); metadata.aiTitleProvenance = provenance
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultError.invalid("An enrichment summary is required.")
        }
        metadata.aiSummary = summary; metadata.aiSummaryProvenance = provenance
        metadata.lcc = classification?.code; metadata.lccClassification = classification
        metadata.aiLCCProvenance = classification == nil ? nil : provenance
        return try await publishSourceMetadata(snapshot, metadata: metadata, validate: validate)
    }

    /// Automatic source processing uses the captured canonical revision and retains manual classification.
    public func publishSourceProcessing(_ snapshot: SourceSummarySnapshot, title: String, summary: String,
        lcc: String?, provenance: SummaryProvenance, validate: @escaping @Sendable () throws -> Void
    ) async throws -> SourceRecord {
        let provenance = try enrichmentProvenance(provenance, revision: snapshot.sourceRevision)
        var metadata = snapshot.source.metadata
        metadata.title = try acceptedTitle(title)
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultError.invalid("A source processing summary is required.")
        }
        metadata.aiTitleProvenance = provenance
        metadata.aiSummary = summary; metadata.aiSummaryProvenance = provenance
        if metadata.lcc == nil, let lcc {
            metadata.lcc = try acceptedLCC(lcc)
            metadata.lccClassification = nil
            metadata.aiLCCProvenance = provenance
        }
        return try await publishSourceMetadata(snapshot, metadata: metadata, validate: validate)
    }

    /// A reviewed draft is encoded fully before a single create-only canonical write.
    /// Source relationships use the captured original and metadata, never a cached excerpt.
    public func createEnrichedPage(id: UUID = UUID(), title: String, body: String, summary: String,
        classification: LCCClassification?, provenance: SummaryProvenance,
        source: SourceSummarySnapshot? = nil, validate: @escaping @Sendable () throws -> Void
    ) async throws -> NoteRecord {
        try validateAccess(operation: "createEnrichedPage")
        try Task.checkCancellation()
        let title = try acceptedTitle(title)
        let notes = try await scan().notes
        try requireUniqueTitle(title, in: notes)
        guard !notes.contains(where: { $0.id == id }) else { throw VaultError.invalid("This generated page already exists.") }
        let provenance = try enrichmentProvenance(provenance, revision: source?.sourceRevision ?? digest(Data(body.utf8)))
        let classification = try verifiedClassification(classification, provenance: provenance)
        let enriched = try enrichedBody(body, summary: summary, provenance: provenance)
        let now = timestamp()
        var note = NoteRecord(id: id, title: title, aliases: [], tags: [], inlineTags: [],
            createdAt: now, updatedAt: now, body: enriched, relativePath: "sqlite/" + id.uuidString.lowercased(),
            contentHash: "", originalHeader: nil)
        note.sourceIDs = source.map { [$0.source.id] }
        note.aiTitleProvenance = provenance
        note.lcc = classification?.code; note.lccClassification = classification
        note.aiLCCProvenance = classification == nil ? nil : provenance
        if let source { try await validateSourceSnapshot(source) }
        try Task.checkCancellation()
        try validate()
        try validateAccess(operation: "createEnrichedPage.write")
        note.relativePath = "sqlite/" + note.id.uuidString.lowercased()
        note.inlineTags = MarkdownService.analyze(note.body).tags
        if let source {
            guard let revision = source.canonicalRevision else { throw VaultError.invalid("Missing source revision.") }
            try await canonicalPublishSourceAndPage(metadata: source.source.metadata, expected: revision,
                page: CanonicalPagePublication(record: note, document: BlockDocumentCodec.decode(note.body), condition: .createOnly), validating: validate)
        } else {
            _ = try await sqliteBlockStore.savePage(record: note, document: BlockDocumentCodec.decode(note.body), condition: .createOnly, validating: validate)
        }
        let saved = try await sqliteBlockStore.loadPage(pageID: note.id).record
        emitAIPageChange(saved, previous: nil, kind: .created, origin: .aiPublication)
        return saved
    }

    public func validateSourceSnapshot(_ snapshot: SourceSummarySnapshot) async throws {
        try validateAccess(operation: "validateSourceSnapshot")
        try Task.checkCancellation()
        guard let revision = snapshot.canonicalRevision,
              try await canonicalSourceMetadata(id: snapshot.source.id).revision == revision,
              try summaryOriginalToken(snapshot.source) == snapshot.originalToken,
              try Self.readSourceOriginal(snapshot.source, root: root, contentStore: contentStore) == snapshot.original,
              try summaryOriginalToken(snapshot.source) == snapshot.originalToken else {
            throw VaultContentStoreError.stale("canonical source")
        }
        return
    }

    private func needsGeneratedTitle(_ title: String) -> Bool {
        normalized(title).isEmpty || normalized(title) == "untitled"
    }

    private func requireUniqueTitle(_ title: String, in notes: [NoteRecord]) throws {
        guard !notes.contains(where: { normalized($0.title) == normalized(title) || $0.aliases.contains { normalized($0) == normalized(title) } }) else {
            throw VaultError.duplicateTitle(title)
        }
    }

    private func enrichmentProvenance(_ value: SummaryProvenance, revision: String) throws -> SummaryProvenance {
        guard value.sourceRevision == nil || value.sourceRevision == revision else {
            throw VaultError.invalid("Enrichment belongs to another content revision.")
        }
        var value = value
        value.sourceRevision = revision; value.generationID = value.generationID ?? UUID()
        return value
    }

    private func verifiedClassification(_ value: LCCClassification?, provenance: SummaryProvenance) throws -> LCCClassification? {
        guard let value else { return nil }
        guard let level = LCCClassificationVocabulary.level(for: value.code),
              let caption = LCCClassificationVocabulary.caption(for: value.code), value.level == level else {
            throw VaultError.invalid("Invalid generated LCC classification.")
        }
        return LCCClassification(code: value.code, level: level, caption: caption,
            provenance: provenance, classifiedAt: provenance.generatedAt)
    }

    private func enrichedBody(_ body: String, summary: String, provenance: SummaryProvenance) throws -> String {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultError.invalid("An enrichment summary is required.")
        }
        var document = BlockDocumentCodec.decode(body)
        guard !document.unsupportedVersion else { throw VaultError.invalid("This page uses an unsupported block format.") }
        document.setAISummary(summary)
        document.blocks[0].metadata.extra["aiProvider"] = provenance.provider
        document.blocks[0].metadata.extra["aiModel"] = provenance.model
        document.blocks[0].metadata.extra["aiGeneratedAt"] = ISO8601DateFormatter().string(from: provenance.generatedAt)
        document.blocks[0].metadata.extra["aiSourceRevision"] = provenance.sourceRevision
        document.blocks[0].metadata.extra["aiGenerationID"] = provenance.generationID?.uuidString.lowercased()
        return BlockDocumentCodec.encode(document)
    }

    /// Publication occurs only after the caller's explicit acceptance of a suggestion.
    public func publishPageTitle(_ snapshot: PageSummarySnapshot, title: String,
        provenance: SummaryProvenance, validate: @escaping @Sendable () throws -> Void
    ) async throws -> NoteRecord {
        let title = try acceptedTitle(title)
        let otherNotes = try await scan().notes.filter { $0.id != snapshot.note.id }
        guard !otherNotes.contains(where: { normalized($0.title) == normalized(title) || $0.aliases.contains { normalized($0) == normalized(title) } }) else {
            throw VaultError.duplicateTitle(title)
        }
        var updated = snapshot.note
        if normalized(title) != normalized(updated.title), !updated.aliases.contains(updated.title) {
            updated.aliases.append(updated.title)
        }
        updated.title = title
        updated.aiTitleProvenance = acceptedProvenance(provenance, revision: snapshot.sourceRevision)
        return try await publishPageMetadata(snapshot, updated: updated, validate: validate)
    }

    public func publishPageLCC(_ snapshot: PageSummarySnapshot, lcc: String,
        provenance: SummaryProvenance, validate: @escaping @Sendable () throws -> Void
    ) async throws -> NoteRecord {
        var updated = snapshot.note
        updated.lcc = try acceptedLCC(lcc)
        updated.lccClassification = nil
        updated.aiLCCProvenance = acceptedProvenance(provenance, revision: snapshot.sourceRevision)
        return try await publishPageMetadata(snapshot, updated: updated, validate: validate)
    }

    public func publishSourceTitle(_ snapshot: SourceSummarySnapshot, title: String,
        provenance: SummaryProvenance, validate: @escaping @Sendable () throws -> Void
    ) async throws -> SourceRecord {
        var metadata = snapshot.source.metadata
        metadata.title = try acceptedTitle(title)
        metadata.aiTitleProvenance = acceptedProvenance(provenance, revision: snapshot.sourceRevision)
        return try await publishSourceMetadata(snapshot, metadata: metadata, validate: validate)
    }

    public func publishSourceLCC(_ snapshot: SourceSummarySnapshot, lcc: String,
        provenance: SummaryProvenance, validate: @escaping @Sendable () throws -> Void
    ) async throws -> SourceRecord {
        var metadata = snapshot.source.metadata
        metadata.lcc = try acceptedLCC(lcc)
        metadata.lccClassification = nil
        metadata.aiLCCProvenance = acceptedProvenance(provenance, revision: snapshot.sourceRevision)
        return try await publishSourceMetadata(snapshot, metadata: metadata, validate: validate)
    }

    private func acceptedTitle(_ value: String) throws -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, !title.contains("\n"), !title.contains("\r") else {
            throw VaultError.invalid("Invalid suggested title.")
        }
        return title
    }

    private func acceptedLCC(_ value: String) throws -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard LCCClassificationVocabulary.isAuthorized(code) else {
            throw VaultError.invalid("Invalid suggested LCC class code.")
        }
        return code
    }

    private func acceptedProvenance(_ provenance: SummaryProvenance, revision: String) -> SummaryProvenance {
        var provenance = provenance
        provenance.sourceRevision = provenance.sourceRevision ?? revision
        return provenance
    }

    private func publishPageMetadata(_ snapshot: PageSummarySnapshot, updated: NoteRecord,
        validate: @escaping @Sendable () throws -> Void
    ) async throws -> NoteRecord {
        try validateAccess(operation: "publishPageArtifact")
        try Task.checkCancellation()
        let path = snapshot.note.relativePath
        guard !snapshot.note.isEditingLocked else { throw VaultContentStoreError.stale(path) }
        var updated = updated
        updated.updatedAt = timestamp()
        try validate()
        updated.inlineTags = MarkdownService.analyze(updated.body).tags
        _ = try await sqliteBlockStore.savePage(record: updated, document: BlockDocumentCodec.decode(updated.body), condition: .replace(expected: sqliteRevision(snapshot.note)), validating: validate)
        let saved = try await sqliteBlockStore.loadPage(pageID: updated.id).record
        emitAIPageChange(saved, previous: snapshot.note, origin: .aiPublication)
        return saved
    }

    private func publishSourceMetadata(_ snapshot: SourceSummarySnapshot, metadata: SourceMetadata,
        validate: @escaping @Sendable () throws -> Void
    ) async throws -> SourceRecord {
        try validateAccess(operation: "publishSourceArtifact")
        try Task.checkCancellation()
        try await validateSourceSnapshot(snapshot)
        guard let revision = snapshot.canonicalRevision else { throw VaultError.invalid("Missing canonical source revision.") }
        try await canonicalUpdateSource(metadata: metadata, expected: revision, origin: .aiPublication, validating: validate)
        return SourceRecord(metadata: metadata, body: snapshot.source.body,
            availabilityIssue: snapshot.source.availabilityIssue, contentState: snapshot.source.contentState)
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
