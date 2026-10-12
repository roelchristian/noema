import Foundation

extension FileVaultRepository {
    func canonicalSourceMetadata(id: UUID) async throws -> (metadata: SourceMetadata, revision: BlockStoreRevision) {
        try validateAccess(operation: "canonicalSourceMetadata")
        let snapshot = try await sqliteBlockStore.sourceSnapshot(id: id)
        guard !snapshot.trashed else { throw VaultError.conflict("Source was removed.") }
        return (try snapshot.source.sourceMetadata(), snapshot.revision)
    }

    func canonicalPublish(metadata: SourceMetadata, original: Data? = nil,
                          validating publication: (@Sendable () throws -> Void)? = nil) async throws {
        try publication?()
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
            condition: .createOnly, operationID: operationID, expectedVaultRevision: try await sqliteBlockStore.canonicalVaultRevision(), byteReceipt: receipt,
            validating: publication)
    }

    func canonicalUpdateSource(metadata: SourceMetadata, expected: BlockStoreRevision,
                               validating publication: (@Sendable () throws -> Void)? = nil) async throws {
        _ = try await canonicalPublishSourceAndPage(metadata: metadata, expected: expected, page: nil, validating: publication)
    }

    @discardableResult
    func canonicalPublishSourceAndPage(metadata: SourceMetadata, expected: BlockStoreRevision,
                                      page: CanonicalPagePublication?,
                                      validating publication: (@Sendable () throws -> Void)? = nil) async throws -> CanonicalPublicationOutcome {
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
        do {
            try validateAccess(operation: "canonicalScanSources")
            var batch = ScanBatch()
            var seen: Set<UUID> = []
            for snapshot in try await sqliteBlockStore.sourceSnapshots() {
                try Task.checkCancellation()
                let id = snapshot.source.id
                seen.insert(id)
                guard sourceID == nil || id == sourceID else { continue }
                let metadata = try snapshot.source.sourceMetadata()
                let metadataBytes = try encoder.encode(metadata)
                let path = "Sources/" + id.uuidString.lowercased() + "/" + metadata.storedFilename
                var source = SourceRecord(metadata: metadata, body: "", contentState: .notLoaded)
                do {
                    let token = try metadata.isLinked ? nil : contentStore.changeToken(at: path)
                    let cached = sourceCache.entry(id)
                    let reusable = token != nil && cached?.token == token && cached?.metadataBytes == metadataBytes
                    if !reusable { sourceCache.remove(id) }
                    if loading == .metadataOnly {
                        batch.sourceVerification[id] = .notVerified
                        if reusable, let cached {
                            batch.sourceContentRevisions[id] = cached.contentRevision
                            batch.sourceOriginalRevisions[id] = metadata.sha256
                        }
                    } else if loading == .complete, reusable, let cached {
                        try validateAccess(operation: "canonicalScanSources.cached")
                        source = cached.record
                        batch.sourceContentRevisions[id] = cached.contentRevision
                        batch.sourceOriginalRevisions[id] = metadata.sha256
                        batch.sourceVerification[id] = .reusedPreviouslyVerified
                    } else {
                        let bytes = try Self.readSourceOriginal(source, root: root, contentStore: contentStore)
                        source.body = try Self.canonicalSourceText(bytes, filename: metadata.originalFilename)
                        source.contentState = .loaded
                        source.availabilityIssue = metadata.webAvailabilityIssue
                        let revision = digest(Data(source.body.utf8))
                        try Task.checkCancellation()
                        try validateAccess(operation: "canonicalScanSources.loaded")
                        if let token, try contentStore.changeToken(at: path) == token {
                            sourceCache.insert(.init(metadataBytes: metadataBytes, token: token,
                                record: source, contentRevision: revision), id: id)
                        }
                        batch.sourceContentRevisions[id] = revision
                        batch.sourceOriginalRevisions[id] = metadata.isLinked ? digest(bytes) : metadata.sha256
                        batch.sourceVerification[id] = metadata.isLinked ? .linkedContentRead : .verifiedThisScan
                    }
                } catch let error as VaultAccessError { throw error }
                catch is CancellationError { throw CancellationError() }
                catch {
                    sourceCache.remove(id)
                    source.contentState = .unavailable
                    source.availabilityIssue = Self.sourceAvailabilityMessage(error, linked: metadata.isLinked)
                    batch.sourceVerification[id] = .notVerified
                    batch.issues.append("Source " + metadata.title + ": " + (source.availabilityIssue ?? error.localizedDescription))
                }
                batch.sources.append(source)
            }
            if sourceID == nil { sourceCache.retain(seen) }
            else if let sourceID, !seen.contains(sourceID) { sourceCache.remove(sourceID) }
            for pending in downloadingSources.values where !seen.contains(pending.id) && (sourceID == nil || sourceID == pending.id) {
                var pending = pending; pending.contentState = .unavailable
                batch.sources.append(pending); batch.sourceVerification[pending.id] = .notVerified
            }
            batch.sources.sort { $0.metadata.capturedAt > $1.metadata.capturedAt }
            try validateAccess(operation: "canonicalScanSources.complete")
            return batch
        } catch {
            sourceCache.clear()
            throw error
        }
    }

    private static func canonicalSourceText(_ data: Data, filename: String) throws -> String {
        if ["txt", "md", "html", "htm"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) {
            guard let value = String(data: data, encoding: .utf8) else { throw VaultError.invalid("Text sources must use UTF-8 encoding.") }
            return value
        }
        return ""
    }

    func canonicalExpireTrash(now: Date) async throws -> [String] {
        let store = sqliteBlockStore
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
        try SQLiteVaultLocality.requireLocalRoot(root)
        let store = try storageProvider.makeStore(root: root)
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw VaultError.invalid("Canonical staging requires an empty owned directory.")
        }
        for directory in ["Sources", "Conflicts"] { try store.createDirectory(at: directory) }
        let database = try storageProvider.makeSemanticStagingStore(url: root.appendingPathComponent(VaultManifest.sqliteDatabasePath), vaultID: id)
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
        try SQLiteVaultLocality.requireLocalRoot(root)
        try store.write(JSONEncoder().encode(manifest), at: "vault.json", condition: .createOnly)
        return manifest
    }
}
