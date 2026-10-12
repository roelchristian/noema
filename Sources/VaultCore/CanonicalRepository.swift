import Foundation

extension FileVaultRepository {
    func canonicalSourceMetadata(id: UUID) async throws -> (metadata: SourceMetadata, revision: BlockStoreRevision) {
        try validateAccess(operation: "canonicalSourceMetadata")
        guard manifest.canonicalStorage, let sqliteBlockStore else { throw VaultError.invalid("Canonical source authority is not admitted.") }
        let snapshot = try await sqliteBlockStore.sourceSnapshot(id: id)
        guard !snapshot.trashed else { throw VaultError.conflict("Source was removed.") }
        return (try snapshot.source.sourceMetadata(), snapshot.revision)
    }

    func canonicalPublish(metadata: SourceMetadata, original: Data? = nil) async throws {
        guard let sqliteBlockStore else { throw VaultError.invalid("Canonical source authority is not admitted.") }
        let operationID = UUID()
        let receipt: CanonicalSourceByteReceipt
        if let original {
            receipt = try contentStore.publishCanonicalOriginal(original, metadata: metadata, vaultID: manifest.id, operationID: operationID)
        } else if metadata.isLinked {
            receipt = try contentStore.verifyCanonicalLinked(metadata: metadata, vaultID: manifest.id, operationID: operationID)
        } else {
            receipt = try contentStore.verifyCanonicalOriginal(metadata: metadata, vaultID: manifest.id, operationID: operationID)
        }
        _ = try await sqliteBlockStore.publishSourceAndPage(source: CanonicalSource(metadata: metadata),
            condition: .createOnly, operationID: operationID, expectedVaultRevision: try await sqliteBlockStore.canonicalVaultRevision(), byteReceipt: receipt)
    }

    func canonicalUpdateSource(metadata: SourceMetadata, expected: BlockStoreRevision,
                               validating publication: (@Sendable () throws -> Void)? = nil) async throws {
        _ = try await canonicalPublishSourceAndPage(metadata: metadata, expected: expected, page: nil, validating: publication)
    }

    @discardableResult
    func canonicalPublishSourceAndPage(metadata: SourceMetadata, expected: BlockStoreRevision,
                                      page: CanonicalPagePublication?,
                                      validating publication: (@Sendable () throws -> Void)? = nil) async throws -> CanonicalPublicationOutcome {
        guard manifest.canonicalStorage, let sqliteBlockStore else { throw VaultError.invalid("Canonical source authority is not admitted.") }
        try validateAccess(operation: "canonicalUpdateSource")
        let operationID = UUID()
        let receipt = try metadata.isLinked
            ? contentStore.verifyCanonicalLinked(metadata: metadata, vaultID: manifest.id, operationID: operationID)
            : contentStore.verifyCanonicalOriginal(metadata: metadata, vaultID: manifest.id, operationID: operationID)
        return try await sqliteBlockStore.publishSourceAndPage(source: CanonicalSource(metadata: metadata),
            condition: .replace(expected: expected), page: page, operationID: operationID, expectedVaultRevision: try await sqliteBlockStore.canonicalVaultRevision(), byteReceipt: receipt,
            validating: publication)
    }

    func canonicalReplaceSource(_ source: SourceRecord, metadata: SourceMetadata) async throws -> SourceRecord {
        let current = try await canonicalSourceMetadata(id: source.id)
        guard current.metadata == source.metadata else { throw VaultError.conflict("Source metadata changed. Refresh before changing it.") }
        try await canonicalUpdateSource(metadata: metadata, expected: current.revision)
        return SourceRecord(metadata: metadata, body: source.body, availabilityIssue: source.availabilityIssue, contentState: source.contentState)
    }

    func canonicalScanSources(loading: SourceLoadingPolicy, sourceID: UUID?) async throws -> ScanBatch {
        try validateAccess(operation: "canonicalScanSources")
        var batch = ScanBatch()
        for snapshot in try await sqliteBlockStore!.sourceSnapshots() {
            try Task.checkCancellation()
            guard sourceID == nil || snapshot.source.id == sourceID else { continue }
            let metadata = try snapshot.source.sourceMetadata()
            var source = SourceRecord(metadata: metadata, body: "", contentState: .notLoaded)
            if loading != .metadataOnly {
                do {
                    let bytes = try Self.readSourceOriginal(source, root: root, contentStore: contentStore)
                    source.body = try Self.canonicalSourceText(bytes, filename: metadata.originalFilename)
                    source.contentState = .loaded
                    source.availabilityIssue = metadata.webAvailabilityIssue
                } catch let error as VaultAccessError { throw error }
                catch { source.contentState = .unavailable; source.availabilityIssue = error.localizedDescription; batch.issues.append(error.localizedDescription) }
            }
            batch.sources.append(source)
        }
        try validateAccess(operation: "canonicalScanSources.complete")
        return batch
    }

    private static func canonicalSourceText(_ data: Data, filename: String) throws -> String {
        if ["txt", "md", "html", "htm"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) {
            guard let value = String(data: data, encoding: .utf8) else { throw VaultError.invalid("Text sources must use UTF-8 encoding.") }
            return value
        }
        return ""
    }

    func canonicalExpireTrash(now: Date) async throws -> [String] {
        let store = sqliteBlockStore!
        var eligible: [TrashedItem] = []
        for note in try await store.allTrashedPages() {
            // A missing legacy removal date receives no implicit deletion authority.
            if let removed = try await store.trashedAt(pageID: note.id), now.timeIntervalSince(removed) >= Self.trashRetentionInterval {
                eligible.append(.page(TrashedPage(note: note)))
            }
        }
        for snapshot in try await store.sourceSnapshots(includeTrashed: true) where snapshot.trashed {
            if let removed = snapshot.trashedAt, now.timeIntervalSince(removed) >= Self.trashRetentionInterval {
                let metadata = try snapshot.source.sourceMetadata()
                eligible.append(.source(TrashedSource(id: "sqlite/source/" + metadata.id.uuidString,
                    source: SourceRecord(metadata: metadata, body: "", contentState: .notLoaded), contentHash: snapshot.revision.token.base64EncodedString())))
            }
        }
        return await emptyTrashItems(eligible)
    }
}

extension FileVaultRepository {
    /// Initializes only a positively empty, explicitly selected local staging root.
    /// STOR02B owns create-only directory publication and default creation policy.
    public static func initializeCanonicalStaging(root: URL, id: UUID = UUID(),
                                                  storageProvider: VaultStorageProvider = .plaintext) async throws -> VaultManifest {
        try SQLiteVaultMigration.requireLocalRoot(root)
        let store = try storageProvider.makeStore(root: root)
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw VaultError.invalid("Canonical staging requires an empty owned directory.")
        }
        for directory in ["Wiki", "Sources", trashDirectoryName, "Conflicts"] { try store.createDirectory(at: directory) }
        let database = try storageProvider.makeCanonicalStagingStore(url: root.appendingPathComponent(VaultManifest.sqliteDatabasePath), vaultID: id)
        do {
            _ = try await database.canonicalVaultRevision()
            try await database.checkpoint()
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }
        var manifest = VaultManifest(id: id)
        manifest.formatVersion = 2; manifest.storageMode = .sqliteBlocks; manifest.storage = VaultCanonicalStorageDeclaration()
        try SQLiteVaultMigration.requireLocalRoot(root)
        try store.write(JSONEncoder().encode(manifest), at: "vault.json", condition: .createOnly)
        return manifest
    }
}
