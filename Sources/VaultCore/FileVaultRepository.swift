import Foundation

public protocol VaultRepository: Sendable {
    func scan(progress: (@Sendable (ScanBatch) -> Void)?) async throws -> ScanBatch
    func create(title: String, body: String) async throws -> NoteRecord
    func create(title: String, body: String, source: SourceRecord) async throws -> NoteRecord
    func save(note: NoteRecord, title: String, body: String, tags: [String]) async throws -> NoteRecord
    func setEditingLock(note: NoteRecord, locked: Bool) async throws -> NoteRecord
    func setSourceReference(note: NoteRecord, sourceID: UUID, linked: Bool) async throws -> NoteRecord
    func trashItems() async throws -> [TrashedItem]
    func expireTrash(now: Date) async throws -> [String]
    func restore(_ item: TrashedItem) async throws
    func emptyTrashItems(_ items: [TrashedItem]) async -> [String]
    func trashedPages() async throws -> [TrashedPage]
    func restore(_ page: TrashedPage) async throws
    func permanentlyDelete(_ page: TrashedPage) async throws
    func emptyTrash(_ pages: [TrashedPage]) async -> [String]
    func trash(note: NoteRecord) async throws
    func deleteSource(_ source: SourceRecord) async throws
    func renameSource(_ source: SourceRecord, title: String, summary: String?) async throws -> SourceRecord
    func updateSourceLCC(_ source: SourceRecord, lcc: String?) async throws -> SourceRecord
    func linkSources(at url: URL, maximumFiles: Int) async throws -> [SourceRecord]
    func importSource(data: Data, filename: String, title: String, originURL: String?) async throws -> SourceRecord
}

public actor FileVaultRepository: VaultRepository {
    public static let trashDirectoryName = "Removed Pages"
    public nonisolated let root: URL
    public nonisolated let manifest: VaultManifest
    public nonisolated let contentStore: any VaultContentStore
    public nonisolated let sessionLease: VaultSessionLease?
    public nonisolated let accessGate: VaultAccessGate?
    public nonisolated let sqliteBlockStore: SQLiteBlockStore
    let sourceCache = SourceSnapshotCache()
    private var cacheInvalidatorID: UUID?
    var downloadingSources: [UUID: SourceRecord] = [:]
    private let fm = FileManager.default
    let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }()

    /// Inspects `vault.json` outside the protected content API so a vault's manifest and identity can be
    /// verified before or while opening/unlocking a session.
    public static func inspectManifest(
        at root: URL,
        contentStore: (any VaultContentStore)? = nil,
        storageProvider: VaultStorageProvider = .plaintext
    ) throws -> VaultManifest {
        guard let manifest = try inspectManifestIfPresent(at: root, contentStore: contentStore,
            storageProvider: storageProvider, allowCreation: false) else {
            throw VaultError.invalid("Choose a vault folder containing vault.json, or create a new vault.")
        }
        return manifest
    }

    private static func inspectManifestIfPresent(
        at root: URL,
        contentStore: (any VaultContentStore)? = nil,
        storageProvider: VaultStorageProvider = .plaintext,
        allowCreation: Bool
    ) throws -> VaultManifest? {
        let accessRoot = root
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: normalizedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultError.unavailable("The vault folder ‘\(normalizedRoot.lastPathComponent)’ could not be found. It may have been moved, renamed, or disconnected.")
        }
        let store = try contentStore ?? storageProvider.makeStore(root: accessRoot)
        let data: Data
        do {
            if let gated = store as? GatedVaultContentStore {
                data = try gated.inspectManifestData()
            } else {
                data = try store.read(at: "vault.json")
            }
        } catch let storeError as VaultContentStoreError {
            switch storeError {
            case .missing:
                if allowCreation {
                    guard try fm.contentsOfDirectory(atPath: normalizedRoot.path).isEmpty else {
                        throw VaultError.invalid("The selected folder contains existing content but has no readable vault manifest. Its contents have been preserved; choose an empty folder to create a vault.")
                    }
                    return nil
                }
                throw VaultError.invalid("Choose a vault folder containing vault.json, or create a new vault.")
            case .unavailable:
                throw VaultError.unavailable("Downloading vault metadata from iCloud. Try again when the download finishes.")
            default:
                throw storeError
            }
        }
        let manifest: VaultManifest
        do { manifest = try JSONDecoder().decode(VaultManifest.self, from: data) }
        catch {
            throw VaultError.invalid("The vault manifest is damaged or has malformed format declarations. Its original bytes have been preserved.")
        }
        guard manifest.isSupported else {
            throw VaultError.invalid("This vault uses an unsupported format version.")
        }
        return manifest
    }

    @discardableResult
    public static func preflightOpen(
        root: URL,
        create: Bool = false,
        storageProvider: VaultStorageProvider = .plaintext
    ) throws -> VaultManifest? {
        let accessRoot = root
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: normalizedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultError.unavailable("The vault folder ‘\(normalizedRoot.lastPathComponent)’ could not be found. It may have been moved, renamed, or disconnected.")
        }
        let manifest = try inspectManifestIfPresent(at: accessRoot,
            storageProvider: storageProvider, allowCreation: create)
        for name in ["Sources", "Conflicts"] {
            let directory = normalizedRoot.appendingPathComponent(name)
            guard directory.resolvingSymlinksInPath() == directory else { throw VaultContentStoreError.unsafePath(name) }
            if fm.fileExists(atPath: directory.path) {
                guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw VaultContentStoreError.unsupportedItem(name)
                }
            }
        }
        return manifest
    }

    public static func open(
        root: URL,
        create: Bool = false,
        contentStore: (any VaultContentStore)? = nil,
        storageProvider: VaultStorageProvider = .plaintext,
        sessionLease: VaultSessionLease? = nil,
        accessGate: VaultAccessGate? = nil,
        willExecuteIO: (@Sendable (String) -> Void)? = nil
    ) throws -> FileVaultRepository {
        let accessRoot = root
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultError.unavailable("The vault folder ‘\(root.lastPathComponent)’ could not be found. It may have been moved, renamed, or disconnected.")
        }
        if let accessGate {
            try accessGate.validate(lease: sessionLease, targetRoot: root, targetVaultID: nil, operation: "open")
        }
        let rawStore = try contentStore ?? storageProvider.makeStore(root: accessRoot)
        let store: any VaultContentStore
        if let accessGate {
            if let existingGated = rawStore as? GatedVaultContentStore {
                store = existingGated
            } else {
                store = GatedVaultContentStore(
                    base: rawStore,
                    root: root,
                    vaultID: sessionLease?.vaultID,
                    gate: accessGate,
                    lease: sessionLease,
                    willExecuteIO: willExecuteIO
                )
            }
        } else {
            store = rawStore
        }
        guard let manifest = try inspectManifestIfPresent(at: accessRoot, contentStore: store,
            storageProvider: storageProvider, allowCreation: false) else {
            throw VaultError.invalid("Create a canonical vault before opening it.")
        }
        if let gated = store as? GatedVaultContentStore {
            gated.bindVaultID(manifest.id)
        }
        if let accessGate {
            try accessGate.validate(lease: sessionLease, targetRoot: root, targetVaultID: manifest.id, operation: "open")
        } else if let sessionLease, (sessionLease.root != root || sessionLease.vaultID != manifest.id) {
            throw VaultAccessError.wrongVault(
                expectedVaultID: manifest.id,
                expectedRoot: root,
                actualVaultID: sessionLease.vaultID,
                actualRoot: sessionLease.root,
                operation: "open"
            )
        }
        for name in ["Sources", "Conflicts"] {
            let directory = root.appendingPathComponent(name)
            guard directory.resolvingSymlinksInPath() == directory else { throw VaultContentStoreError.unsafePath(name) }
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw VaultContentStoreError.unsupportedItem(name)
            }
        }
        try SQLiteVaultLocality.requireLocalRoot(accessRoot)
        let database = root.appendingPathComponent(VaultManifest.sqliteDatabasePath)
        guard fm.fileExists(atPath: database.path), database.resolvingSymlinksInPath() == database else {
            throw VaultError.invalid("The canonical SQLite database is missing or unsafe.")
        }
        guard let sessionLease, let accessGate else {
            throw VaultAccessError.missingLease(operation: "blockStore.open")
        }
        let blocks = try storageProvider.makeBlockStore(url: database, sessionLease: sessionLease,
            accessGate: accessGate, createIfMissing: false, manifest: manifest)
        return FileVaultRepository(
            root: root,
            manifest: manifest,
            contentStore: store,
            sqliteBlockStore: blocks,
            sessionLease: sessionLease,
            accessGate: accessGate
        )
    }

    /// Run after save/recovery quiescence, while the session still has authority.
    public func checkpointPageStorage() async throws {
        try await sqliteBlockStore.checkpoint()
    }

    /// Call only after a successful lifecycle transition has retired this repository.
    public func shutdownPageStorage() async throws {
        try await sqliteBlockStore.close()
    }

    /// A consistent SQLite snapshot. Whole-vault export also needs manifest/source bytes.
    public func backupDatabase(to destination: URL) async throws {
        try await sqliteBlockStore.backup(to: destination)
    }

    private init(
        root: URL,
        manifest: VaultManifest,
        contentStore: any VaultContentStore,
        sqliteBlockStore: SQLiteBlockStore,
        sessionLease: VaultSessionLease? = nil,
        accessGate: VaultAccessGate? = nil
    ) {
        self.root = root
        self.manifest = manifest
        self.contentStore = contentStore
        self.sqliteBlockStore = sqliteBlockStore
        self.sessionLease = sessionLease
        self.accessGate = accessGate
        let gate = (contentStore as? GatedVaultContentStore)?.gate ?? accessGate
        if let gate, let lease = sessionLease ?? gate.currentLease {
            let cache = sourceCache
            cacheInvalidatorID = gate.registerContentInvalidator(lease: lease) { cache.retire() }
        }
    }

    deinit {
        if let cacheInvalidatorID {
            ((contentStore as? GatedVaultContentStore)?.gate ?? accessGate)?.removeContentInvalidator(cacheInvalidatorID)
        }
    }

    /// Diagnostic count contains no content and is internal for lifecycle regression tests.
    var cachedSourceCount: Int { sourceCache.count }


    nonisolated func validateAccess(operation: String) throws {
        if let gated = contentStore as? GatedVaultContentStore {
            try gated.validateAccess(operation: operation)
        } else if let accessGate {
            try accessGate.validate(
                lease: sessionLease,
                targetRoot: root,
                targetVaultID: manifest.id,
                operation: operation
            )
        }
    }

    public func scan(progress: (@Sendable (ScanBatch) -> Void)? = nil) async throws -> ScanBatch {
        try await scan(sourceLoading: .complete, progress: progress)
    }

    public func scan(sourceLoading: SourceLoadingPolicy, progress: (@Sendable (ScanBatch) -> Void)? = nil) async throws -> ScanBatch {
        defer { if Task.isCancelled { sourceCache.clear() } }
        try Task.checkCancellation()
        try validateAccess(operation: "scan")
        var batch = try await scanSources(loading: sourceLoading)
        batch.notes = try await sqliteBlockStore.allPages()
        batch.notes.sort { $0.updatedAt > $1.updatedAt }
        try validateAccess(operation: "scan.complete")
        progress?(batch)
        return batch
    }

    /// Source identity and metadata come from the admitted canonical database.
    public func scanSources(loading: SourceLoadingPolicy = .metadataOnly, sourceID: UUID? = nil) async throws -> ScanBatch {
        try await canonicalScanSources(loading: loading, sourceID: sourceID)
    }

    /// Demand-driven loading by identity always rediscovers current metadata through the store.
    public func loadSource(id: UUID, verifyOriginal: Bool = false) async throws -> SourceRecord {
        let batch = try await scanSources(loading: verifyOriginal ? .verifyOriginals : .complete, sourceID: id)
        guard let source = batch.sources.first(where: { $0.id == id }), source.contentState == .loaded else {
            throw VaultError.unavailable(batch.issues.first ?? "Source is unavailable. Refresh the vault.")
        }
        return source
    }

    public func create(title: String = "Untitled", body: String = "") async throws -> NoteRecord {
        try await createPage(title: title, body: body, source: nil, lcc: nil)
    }

    public func create(title: String = "Untitled", body: String = "", lcc: String?) async throws -> NoteRecord {
        try await createPage(title: title, body: body, source: nil, lcc: lcc)
    }

    public func create(title: String, body: String, source: SourceRecord) async throws -> NoteRecord {
        try await createPage(title: title, body: body, source: source, lcc: nil)
    }

    public func create(title: String, body: String, source: SourceRecord, lcc: String?) async throws -> NoteRecord {
        try await createPage(title: title, body: body, source: source, lcc: lcc)
    }

    private func createPage(title: String, body: String, source: SourceRecord?, lcc: String?) async throws -> NoteRecord {
        try validateAccess(operation: "create")
        let snapshot = try await scan()
        if let source {
            guard let current = snapshot.sources.first(where: { $0.id == source.id }),
                  current.metadata.sha256 == source.metadata.sha256,
                  current.metadata.linkedBookmark == source.metadata.linkedBookmark,
                  current.metadata.storedFilename == source.metadata.storedFilename,
                  source.contentState == .loaded, current.body == source.body else {
                throw VaultError.invalid("Source changed or was removed. Refresh before creating a page.")
            }
        }
        var actualTitle = title, suffix = 2
        while titleExists(actualTitle, in: snapshot.notes) {
            actualTitle = "\(title) \(suffix)"; suffix += 1
        }
        let now = timestamp()
        var note = NoteRecord(id: UUID(), title: actualTitle, aliases: [], tags: [], inlineTags: [], createdAt: now, updatedAt: now, body: body, relativePath: "", contentHash: "", originalHeader: nil)
        note.sourceIDs = source.map { [$0.id] }
        let normalizedLCC = lcc?.trimmingCharacters(in: .whitespacesAndNewlines)
        note.lcc = (normalizedLCC?.isEmpty == false ? normalizedLCC : nil) ?? source?.metadata.lcc
        note.relativePath = "sqlite/" + note.id.uuidString.lowercased()
        note.inlineTags = MarkdownService.analyze(note.body).tags
        _ = try await sqliteBlockStore.savePage(record: note, document: BlockDocumentCodec.decode(note.body), condition: .createOnly)
        return try await sqliteBlockStore.loadPage(pageID: note.id).record
    }

    public func setEditingLock(note: NoteRecord, locked: Bool) async throws -> NoteRecord {
        try validateAccess(operation: "setEditingLock")
        var updated = note
        updated.editingLocked = locked
        return try await save(note: updated, title: note.title, body: note.body, tags: note.tags, preserveUpdatedAt: true)
    }

    public func save(note: NoteRecord, title: String, body: String, tags: [String]) async throws -> NoteRecord {
        try validateAccess(operation: "save")
        return try await save(note: note, title: title, body: body, tags: tags, preserveUpdatedAt: false)
    }

    private func save(note: NoteRecord, title: String, body: String, tags: [String], preserveUpdatedAt: Bool) async throws -> NoteRecord {
        try validateAccess(operation: "save")
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw VaultError.invalid("A wiki page needs a title.") }
        let snapshot = try await scan()
        if !snapshot.notes.contains(where: { $0.id == note.id }) {
            throw VaultError.invalid("This page is invalid or has a duplicate ID. Inspect the vault notices before saving. Your local draft is preserved.")
        }
        guard !titleExists(title, in: snapshot.notes.filter { $0.id != note.id }) else { throw VaultError.duplicateTitle(title) }
        if snapshot.notes.first(where: { $0.id == note.id })?.isEditingLocked == true,
           title != note.title || body != note.body || normalizeTags(tags) != note.tags || snapshot.notes.first(where: { $0.id == note.id })?.linkedSourceIDs != note.linkedSourceIDs || snapshot.notes.first(where: { $0.id == note.id })?.lcc != note.lcc {
            throw VaultError.invalid("This article is locked. Unlock it before editing.")
        }
        var updated = note
        updated.title = title; updated.body = body; updated.tags = normalizeTags(tags)
        updated.inlineTags = MarkdownService.analyze(body).tags
        if snapshot.notes.first(where: { $0.id == note.id })?.title != title { updated.aiTitleProvenance = nil }
        if snapshot.notes.first(where: { $0.id == note.id })?.lcc != updated.lcc {
            updated.aiLCCProvenance = nil; updated.lccClassification = nil
        }
        updated.updatedAt = preserveUpdatedAt ? note.updatedAt : timestamp()
        if updated.createdAt.isEmpty { updated.createdAt = updated.updatedAt }
        if normalized(title) != normalized(note.title), !updated.aliases.contains(note.title) { updated.aliases.append(note.title) }
        _ = try await sqliteBlockStore.savePage(record: updated, document: BlockDocumentCodec.decode(updated.body), condition: .replace(expected: sqliteRevision(note)))
        return try await sqliteBlockStore.loadPage(pageID: note.id).record
    }

    func sqliteRevision(_ note: NoteRecord) throws -> BlockStoreRevision {
        guard let token = Data(base64Encoded: note.contentHash), !token.isEmpty else {
            throw VaultContentStoreError.stale(note.relativePath)
        }
        return BlockStoreRevision(token: token)
    }

    public func setSourceReference(note: NoteRecord, sourceID: UUID, linked: Bool) async throws -> NoteRecord {
        try validateAccess(operation: "setSourceReference")
        guard !note.isEditingLocked else { throw VaultError.invalid("Unlock this article before editing its sources.") }
        if linked, !((try await scan()).sources.contains { $0.id == sourceID }) {
            throw VaultError.invalid("This source is unavailable. Refresh before adding it.")
        }
        var updated = note
        var ids = Set(note.linkedSourceIDs)
        if linked { ids.insert(sourceID) } else { ids.remove(sourceID) }
        updated.sourceIDs = ids.sorted { $0.uuidString < $1.uuidString }
        return try await save(note: updated, title: note.title, body: note.body, tags: note.tags)
    }

    public func trash(note: NoteRecord) async throws {
        try validateAccess(operation: "trash")
        _ = try await sqliteBlockStore.setTrashed(pageID: note.id, expected: sqliteRevision(note), trashed: true)
    }

    public func trashedPages() async throws -> [TrashedPage] {
        try validateAccess(operation: "trashedPages")
        return try await sqliteBlockStore.allTrashedPages().map { TrashedPage(note: $0) }
    }

    public func restore(_ page: TrashedPage) async throws {
        try validateAccess(operation: "restore")
        guard page.canRestore, page.id.hasPrefix("sqlite/") else { throw VaultError.invalid("Invalid canonical Trash entry.") }
        let notes = try await sqliteBlockStore.allPages()
        guard !notes.contains(where: { $0.id == page.note.id }) else { throw VaultError.invalid("A page with this identity already exists.") }
        guard !titleExists(page.note.title, in: notes) else { throw VaultError.duplicateTitle(page.note.title) }
        _ = try await sqliteBlockStore.setTrashed(pageID: page.note.id, expected: sqliteRevision(page.note), trashed: false)
    }

    public func permanentlyDelete(_ page: TrashedPage) async throws {
        try validateAccess(operation: "permanentlyDelete")
        guard page.canPermanentlyDelete, page.id.hasPrefix("sqlite/") else { throw VaultError.invalid("Invalid canonical Trash entry.") }
        let collection = try await sqliteBlockStore.canonicalVaultRevision()
        try await sqliteBlockStore.purgeCanonicalEntity(id: page.note.id, kind: .page,
            expected: sqliteRevision(page.note), expectedVaultRevision: collection)
    }

    public func emptyTrash(_ pages: [TrashedPage]) async -> [String] {
        // Delete only the confirmed snapshot; keep changed/conflicted files and report partial failures.
        var failures: [String] = []
        for page in pages {
            do { try await permanentlyDelete(page) }
            catch { failures.append("\(page.note.title): \(error.localizedDescription)") }
        }
        return failures
    }
    private func rejectDuplicateSource(checksum: String, linkedURL: URL? = nil, excludingID: UUID? = nil) async throws {
        for snapshot in try await sqliteBlockStore.sourceSnapshots() {
            let metadata = try snapshot.source.sourceMetadata()
            guard metadata.id != excludingID else { continue }
            if !checksum.isEmpty && metadata.sha256 == checksum { throw VaultError.invalid("File already added as a source.") }
            if let linkedURL, let bookmark = metadata.linkedBookmark {
                var stale = false
                if let existing = try? Self.resolveBookmarkData(bookmark, isStale: &stale),
                   existing.standardizedFileURL.resolvingSymlinksInPath() == linkedURL.standardizedFileURL.resolvingSymlinksInPath() {
                    throw VaultError.invalid("File already added as a linked source.")
                }
            }
        }
    }

    public func importSource(data: Data, filename: String, title: String, originURL: String?) async throws -> SourceRecord {
        try validateAccess(operation: "importSource")
        return try await publishSource(data: data, filename: filename, title: title, originURL: originURL, isURLSource: false)
    }

    public func importURLSource(_ address: String, fetch: @Sendable (URL) async throws -> WebSourceFetch = WebSourceFetcher.fetch) async throws -> SourceRecord {
        try validateAccess(operation: "importURLSource")
        let url = try WebSourceFetcher.validatedURL(address)
        let fetched = try await fetch(url)
        try validateAccess(operation: "importURLSource")
        return try await publishSource(data: fetched.data, filename: fetched.filename, title: url.host ?? address, originURL: url.absoluteString, isURLSource: true)
    }

    public func checkURLSourceAvailability(_ source: SourceRecord, fetch: @Sendable (URL) async throws -> WebSourceFetch = WebSourceFetcher.fetch) async throws -> String {
        try validateAccess(operation: "checkURLSourceAvailability")
        guard source.metadata.isURLSource == true, let address = source.metadata.originURL else { throw VaultError.invalid("This source was not fetched from a URL.") }
        let issue: String?
        do { _ = try await fetch(WebSourceFetcher.validatedURL(address)); issue = nil }
        catch { issue = "Archived fetch · Unavailable: " + error.localizedDescription }
        try validateAccess(operation: "checkURLSourceAvailability")
        var metadata = source.metadata; metadata.webAvailabilityIssue = issue
        _ = try await canonicalReplaceSource(source, metadata: metadata)
        return issue ?? "Available"
    }

    private func publishSource(id: UUID = UUID(), capturedAt: String? = nil, data: Data, filename: String, title: String, originURL: String?, isURLSource: Bool) async throws -> SourceRecord {
        try validateAccess(operation: "publishSource")
        guard data.count <= Self.maximumImportBytes else { throw VaultError.invalid("Files larger than 2 MB must be linked instead of imported.") }
        try await rejectDuplicateSource(checksum: digest(data), excludingID: id)
        let body = try Self.sourceText(data, filename: filename)
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let storedExtension = ext.isEmpty ? "bin" : ext
        if let originURL, !originURL.isEmpty {
            guard let url = URL(string: originURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw VaultError.invalid("The origin URL must be an http or https address.") }
        }
        var metadata = SourceMetadata(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent : title, capturedAt: capturedAt ?? timestamp(), originalFilename: URL(fileURLWithPath: filename).lastPathComponent, originURL: originURL?.isEmpty == true ? nil : originURL, sha256: digest(data), fileSize: data.count, storedFilename: "original.\(storedExtension)")
        metadata.isURLSource = isURLSource ? true : nil
        try await canonicalPublish(metadata: metadata, original: data)
        return SourceRecord(metadata: metadata, body: body)
    }

    public static let maximumImportBytes = 2_000_000

    private static func sourceText(_ data: Data, filename: String) throws -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if ["txt", "md", "html", "htm"].contains(ext) {
            guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalid("Text sources must use UTF-8 encoding.") }
            return text
        }
        if ext == "pdf", !data.starts(with: Data("%PDF-".utf8)) { throw VaultError.invalid("This file is not a PDF document.") }
        return ""
    }

    public static func sourceAvailabilityMessage(_ error: Error, linked: Bool) -> String {
        if case VaultContentStoreError.missing = error { return linked ? "Linked file not found" : "File not found" }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
            return linked ? "Linked file not found" : "File not found"
        }
        return "Unavailable: " + error.localizedDescription
    }

    public static func checkSourceAvailability(_ source: SourceRecord, root: URL, contentStore: any VaultContentStore) -> String {
        do {
            if let gated = contentStore as? GatedVaultContentStore {
                let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
                if normalizedRoot != gated.root {
                    throw VaultAccessError.wrongVault(
                        expectedVaultID: gated.vaultID,
                        expectedRoot: gated.root,
                        actualVaultID: nil,
                        actualRoot: normalizedRoot,
                        operation: "checkSourceAvailability"
                    )
                }
                try gated.validateAccess(operation: "checkSourceAvailability")
            }
            guard source.metadata.storedFilename == URL(fileURLWithPath: source.metadata.storedFilename).lastPathComponent,
                  !source.metadata.storedFilename.hasPrefix(".") else { throw VaultError.invalid("Invalid source path.") }
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let data = try readSourceOriginal(source, root: root, contentStore: contentStore)
            guard source.metadata.isLinked || digest(data) == source.metadata.sha256 else { throw VaultError.invalid("Original checksum does not match.") }
            return "Available"
        } catch { return sourceAvailabilityMessage(error, linked: source.metadata.isLinked) }
    }

    /// Linked originals have external ownership and never pass through vault storage.
    public static func readSourceOriginal(_ source: SourceRecord, root: URL, contentStore: any VaultContentStore) throws -> Data {
        if let gated = contentStore as? GatedVaultContentStore {
            let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            if normalizedRoot != gated.root {
                throw VaultAccessError.wrongVault(
                    expectedVaultID: gated.vaultID,
                    expectedRoot: gated.root,
                    actualVaultID: nil,
                    actualRoot: normalizedRoot,
                    operation: "readSourceOriginal"
                )
            }
            try gated.validateAccess(operation: "readSourceOriginal")
        }
        if let bookmark = source.metadata.linkedBookmark { return try readLinkedSource(bookmark) }
        let filename = source.metadata.storedFilename
        guard filename == URL(fileURLWithPath: filename).lastPathComponent, !filename.hasPrefix(".") else { throw VaultError.invalid("Invalid source path.") }
        let data = try contentStore.read(at: "Sources/" + source.id.uuidString.lowercased() + "/" + filename)
        guard digest(data) == source.metadata.sha256 else { throw VaultError.invalid("Original checksum does not match.") }
        return data
    }

    private static func makeBookmarkData(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadUnknownError {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    private static func resolveBookmarkData(_ bookmark: Data, isStale: inout Bool) throws -> URL {
        do {
            return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &isStale)
        } catch {
            return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &isStale)
        }
    }

    public static func readLinkedSource(_ bookmark: Data) throws -> Data {
        var stale = false
        let url = try resolveBookmarkData(bookmark, isStale: &stale)
        guard !stale else { throw VaultError.unavailable("Linked source permission is stale. Link the file again.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try coordinatedRead(url)
    }

    public func beginSourceDownload(at url: URL, shouldImport: Bool) async throws -> SourceRecord {
        try validateAccess(operation: "beginSourceDownload")
        let targetURL = Self.logicalCloudURL(url)
        var st = stat()
        if lstat(url.path, &st) == 0 {
            let mode = st.st_mode & S_IFMT
            guard mode != S_IFDIR, mode != S_IFLNK else {
                throw VaultError.invalid(shouldImport ? "Choose a regular file. Folders are not supported." : "Choose files only. Folder linking is no longer supported.")
            }
            if shouldImport, Int(st.st_size) > Self.maximumImportBytes {
                throw VaultError.invalid("Files larger than 2 MB must be linked instead of imported.")
            }
        } else {
            let values = try? targetURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isDirectory != true, values?.isSymbolicLink != true else {
                throw VaultError.invalid(shouldImport ? "Choose a regular file. Folders are not supported." : "Choose files only. Folder linking is no longer supported.")
            }
            if shouldImport, let size = values?.fileSize, size > Self.maximumImportBytes {
                throw VaultError.invalid("Files larger than 2 MB must be linked instead of imported.")
            }
        }
        try await rejectDuplicateSource(checksum: "", linkedURL: targetURL)
        let id = UUID()
        let ext = targetURL.pathExtension.lowercased()
        let storedExtension = ext.isEmpty ? "bin" : ext
        let rawTitle = targetURL.deletingPathExtension().lastPathComponent
        let fileSize: Int? = (lstat(url.path, &st) == 0 && st.st_size > 0) ? Int(st.st_size) : (try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let metadata = SourceMetadata(
            id: id,
            title: rawTitle.isEmpty ? targetURL.lastPathComponent : rawTitle,
            capturedAt: timestamp(),
            originalFilename: targetURL.lastPathComponent,
            originURL: nil,
            sha256: "",
            fileSize: fileSize,
            linkedBookmark: shouldImport ? nil : Data(),
            storedFilename: "original.\(storedExtension)"
        )
        let source = SourceRecord(metadata: metadata, body: "", availabilityIssue: "Downloading from iCloud", contentState: .unavailable)
        downloadingSources[id] = source
        return source
    }

    public func completeSourceDownload(id: UUID, at url: URL, data: Data, shouldImport: Bool) async throws -> SourceRecord {
        try validateAccess(operation: "completeSourceDownload")
        guard let pending = downloadingSources[id] else {
            throw VaultError.invalid("Source download is no longer active.")
        }
        let targetURL = Self.logicalCloudURL(url)
        defer { downloadingSources.removeValue(forKey: id) }
        if shouldImport {
            return try await publishSource(
                id: id,
                capturedAt: pending.metadata.capturedAt,
                data: data,
                filename: targetURL.lastPathComponent,
                title: pending.title,
                originURL: nil,
                isURLSource: false
            )
        }
        try await rejectDuplicateSource(checksum: digest(data), linkedURL: targetURL, excludingID: id)
        let body = try Self.sourceText(data, filename: targetURL.lastPathComponent)
        let bookmark = try Self.makeBookmarkData(for: targetURL)
        let metadata = SourceMetadata(
            id: id,
            title: pending.title,
            capturedAt: pending.metadata.capturedAt,
            originalFilename: targetURL.lastPathComponent,
            originURL: nil,
            sha256: digest(data),
            fileSize: data.count,
            linkedBookmark: bookmark,
            storedFilename: pending.metadata.storedFilename
        )
        try await canonicalPublish(metadata: metadata)
        let current = try await canonicalSourceMetadata(id: metadata.id)
        return SourceRecord(metadata: current.metadata, body: body)
    }

    public func cancelSourceDownload(id: UUID) {
        downloadingSources.removeValue(forKey: id)
    }

    @discardableResult
    public func cancelAllSourceDownloads() -> [UUID] {
        let ids = Array(downloadingSources.keys)
        downloadingSources.removeAll()
        return ids
    }

    public var activeDownloadingSourceIDs: [UUID] {
        Array(downloadingSources.keys)
    }

    public func importPreparedSource(
        id: UUID = UUID(),
        capturedAt: String? = nil,
        data: Data,
        filename: String,
        title: String,
        originURL: String?,
        isURLSource: Bool
    ) async throws -> SourceRecord {
        try validateAccess(operation: "importSource")
        return try await publishSource(
            id: id,
            capturedAt: capturedAt,
            data: data,
            filename: filename,
            title: title,
            originURL: originURL,
            isURLSource: isURLSource
        )
    }

    @discardableResult
    public func cleanupInterruptedImportStaging(id: UUID) throws -> Bool {
        try validateAccess(operation: "cleanupInterruptedImportStaging")
        let pending = "Sources/.import-" + id.uuidString
        let url = root.appendingPathComponent(pending).standardizedFileURL
        guard fm.fileExists(atPath: url.path) else { return false }
        let snapshot = try contentStore.snapshot(at: pending)
        try contentStore.delete(at: pending, expected: snapshot)
        return true
    }

    public func linkSources(at url: URL, maximumFiles: Int) async throws -> [SourceRecord] {
        try validateAccess(operation: "linkSources")
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VaultError.invalid("Choose files only. Folder linking is no longer supported.") }
        let files = [url]
        // Validate every member before publishing any records.
        var prepared: [SourceRecord] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let data = try Self.coordinatedRead(file)
            try await rejectDuplicateSource(checksum: digest(data), linkedURL: file)
            let body = try Self.sourceText(data, filename: file.lastPathComponent)
            let bookmark = try Self.makeBookmarkData(for: file)
            let metadata = SourceMetadata(id: UUID(), title: file.deletingPathExtension().lastPathComponent, capturedAt: timestamp(), originalFilename: file.lastPathComponent, originURL: nil, sha256: digest(data), fileSize: data.count, linkedBookmark: bookmark, storedFilename: "original." + file.pathExtension.lowercased())
            prepared.append(SourceRecord(metadata: metadata, body: body))
        }
        var published: [SourceRecord] = []
        for source in prepared {
            try await canonicalPublish(metadata: source.metadata)
            let current = try await canonicalSourceMetadata(id: source.id)
            published.append(SourceRecord(metadata: current.metadata, body: source.body))
        }
        return published
    }

    func invalidateSummaryCaches(pagePath: String?, sourceID: UUID?) {
        if let sourceID { sourceCache.remove(sourceID) }
    }

    public func renameSource(_ source: SourceRecord, title: String, summary: String? = nil) async throws -> SourceRecord {
        try await renameSource(source, title: title, summary: summary, lcc: nil)
    }

    public func renameSource(_ source: SourceRecord, title: String, summary: String? = nil, lcc: String? = nil) async throws -> SourceRecord {
        try validateAccess(operation: "renameSource")
        sourceCache.remove(source.id)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw VaultError.invalid("Invalid source title.") }
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, summary.isEmpty { throw VaultError.invalid("Source summary must not be empty.") }
        let normalizedLCC = lcc?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLCC = (normalizedLCC?.isEmpty == false) ? normalizedLCC : nil
        if var pending = downloadingSources[source.id] {
            guard cleanLCC == nil || pending.metadata.lcc == source.metadata.lcc else {
                throw VaultError.invalid("Source classification changed while its title was generated. Refresh and try again.")
            }
            if pending.metadata.title != title { pending.metadata.aiTitleProvenance = nil }
            pending.metadata.title = title
            if let summary { pending.metadata.aiSummary = summary; pending.metadata.aiSummaryProvenance = nil }
            if let cleanLCC { pending.metadata.lcc = cleanLCC; pending.metadata.aiLCCProvenance = nil; pending.metadata.lccClassification = nil }
            downloadingSources[source.id] = pending
            return pending
        }
        var metadata = source.metadata
        metadata.title = title; metadata.aiTitleProvenance = nil
        if let summary { metadata.aiSummary = summary; metadata.aiSummaryProvenance = nil }
        if let cleanLCC { metadata.lcc = cleanLCC; metadata.aiLCCProvenance = nil; metadata.lccClassification = nil }
        return try await canonicalReplaceSource(source, metadata: metadata)
    }

    public func updateSourceLCC(_ source: SourceRecord, lcc: String?) async throws -> SourceRecord {
        try validateAccess(operation: "updateSourceLCC")
        sourceCache.remove(source.id)
        let normalizedLCC = lcc?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLCC = (normalizedLCC?.isEmpty == false) ? normalizedLCC : nil
        if let cleanLCC, cleanLCC.count > 24 || cleanLCC.contains("\n") || cleanLCC.contains("\r") {
            throw VaultError.invalid("Invalid LCC class code.")
        }
        if var pending = downloadingSources[source.id] {
            pending.metadata.lcc = cleanLCC
            pending.metadata.aiLCCProvenance = nil
            pending.metadata.lccClassification = nil
            downloadingSources[source.id] = pending
            return pending
        }
        var metadata = source.metadata; metadata.lcc = cleanLCC
        metadata.aiLCCProvenance = nil; metadata.lccClassification = nil
        return try await canonicalReplaceSource(source, metadata: metadata)
    }

    public func deleteSource(_ source: SourceRecord) async throws {
        try validateAccess(operation: "deleteSource")
        sourceCache.remove(source.id)
        if downloadingSources.removeValue(forKey: source.id) != nil { return }
        let current = try await canonicalSourceMetadata(id: source.id)
        guard current.metadata == source.metadata else { throw VaultError.conflict("Source changed.") }
        _ = try await sqliteBlockStore.setSourceTrashed(id: source.id, expected: current.revision, trashed: true)
    }

    private func titleExists(_ title: String, in notes: [NoteRecord]) -> Bool {
        let key = normalized(title)
        return notes.contains { normalized($0.title) == key || $0.aliases.contains { normalized($0) == key } }
    }
    public static func logicalCloudURL(_ url: URL) -> URL {
        let name = url.lastPathComponent
        if name.hasPrefix("."), name.lowercased().hasSuffix(".icloud") {
            let trimmed = String(name.dropFirst().dropLast(".icloud".count))
            if !trimmed.isEmpty {
                return url.deletingLastPathComponent().appendingPathComponent(trimmed)
            }
        }
        return url
    }
    public static func isCloudFileNotDownloaded(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix("."), url.pathExtension.lowercased() == "icloud" {
            return true
        }
        var st = stat()
        if lstat(url.path, &st) == 0 {
            if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
                return true
            }
            if st.st_size > 0, st.st_blocks == 0,
               url.path.contains("/CloudStorage/") || url.path.localizedCaseInsensitiveContains("OneDrive") || url.path.contains("Mobile Documents") {
                return true
            }
        }
        var refreshed = url
        refreshed.removeAllCachedResourceValues()
        if let values = try? refreshed.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]) {
            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                return true
            }
            if values.ubiquitousItemIsDownloading == true, values.ubiquitousItemDownloadingStatus != .current {
                return true
            }
        }
        return false
    }
    public static func downloadCloudFile(_ url: URL) async throws -> Data {
        let targetURL = logicalCloudURL(url)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        if targetURL != url {
            try? FileManager.default.startDownloadingUbiquitousItem(at: targetURL)
        }
        return try await Task.detached {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            if targetURL != url {
                try? FileManager.default.startDownloadingUbiquitousItem(at: targetURL)
            }
            var data: Data?, failure: Error?, coordinatorError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: targetURL, options: [], error: &coordinatorError) { coordinatedURL in
                do { data = try Data(contentsOf: coordinatedURL) } catch { failure = error }
            }
            var checkURL = targetURL
            checkURL.removeAllCachedResourceValues()
            if let data, !isCloudFileNotDownloaded(checkURL) {
                return data
            }
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if Task.isCancelled { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(250))
                var refreshedURL = targetURL
                refreshedURL.removeAllCachedResourceValues()
                if !isCloudFileNotDownloaded(refreshedURL) {
                    if let data, !data.isEmpty { return data }
                    var retryData: Data?, retryFailure: Error?, retryCoordError: NSError?
                    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: refreshedURL, options: [], error: &retryCoordError) { coordinatedURL in
                        do { retryData = try Data(contentsOf: coordinatedURL) } catch { retryFailure = error }
                    }
                    if let retryData { return retryData }
                    if let retryFailure { throw retryFailure }
                    if let retryCoordError { throw retryCoordError }
                }
            }
            if let data { return data }
            if let failure { throw failure }
            if let coordinatorError { throw coordinatorError }
            throw VaultError.unavailable("Downloading \(targetURL.lastPathComponent) from iCloud. Try again when the download finishes.")
        }.value
    }
    public static func coordinatedRead(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw VaultError.unavailable("Downloading \(url.lastPathComponent) from iCloud. Try again when the download finishes.")
        }
        var data: Data?, failure: Error?, coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            do { data = try Data(contentsOf: coordinatedURL) } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinatorError { throw coordinatorError }
        guard let data else { throw VaultError.storage("Could not read \(url.lastPathComponent).") }
        return data
    }
}


extension FileVaultRepository {
    public static let trashRetentionInterval: TimeInterval = 15 * 24 * 60 * 60

    public func trashItems() async throws -> [TrashedItem] {
        try validateAccess(operation: "trashItems")
        var items = try await trashedPages().map(TrashedItem.page)
        for snapshot in try await sqliteBlockStore.sourceSnapshots(includeTrashed: true) where snapshot.trashed {
            let metadata = try snapshot.source.sourceMetadata()
            items.append(.source(TrashedSource(id: "sqlite/source/" + metadata.id.uuidString,
                source: SourceRecord(metadata: metadata, body: "", contentState: .notLoaded),
                contentHash: snapshot.revision.token.base64EncodedString())))
        }
        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public func restore(_ item: TrashedItem) async throws {
        try validateAccess(operation: "restore")
        switch item {
        case .page(let page): try await restore(page)
        case .source(let entry):
            guard entry.readIssue == nil, let source = entry.source else { throw VaultError.invalid("Repair this source before restoring it.") }
            _ = try await sqliteBlockStore.setSourceTrashed(id: source.id,
                expected: BlockStoreRevision(token: Data(base64Encoded: entry.contentHash) ?? Data()), trashed: false)
        }
    }
    public func permanentlyDelete(_ item: TrashedItem) async throws {
        try validateAccess(operation: "permanentlyDelete")
        switch item {
        case .page(let page): try await permanentlyDelete(page)
        case .source(let source):
            guard let record = source.source else { throw VaultError.invalid("Unreadable source cannot be deleted.") }
            let collection = try await sqliteBlockStore.canonicalVaultRevision()
            try await sqliteBlockStore.purgeCanonicalEntity(id: record.id, kind: .source,
                expected: BlockStoreRevision(token: Data(base64Encoded: source.contentHash) ?? Data()),
                expectedVaultRevision: collection)
        }
    }
    public func emptyTrashItems(_ items: [TrashedItem]) async -> [String] {
        var failures: [String] = []
        for item in items {
            do { try await permanentlyDelete(item) } catch { failures.append("\(item.title): \(error.localizedDescription)") }
        }
        return failures
    }
    public func expireTrash(now: Date = Date()) async throws -> [String] {
        try validateAccess(operation: "expireTrash")
        return try await canonicalExpireTrash(now: now)
    }
}
