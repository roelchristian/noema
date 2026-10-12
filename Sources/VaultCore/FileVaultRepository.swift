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
    private static let legacyTrashDirectoryName = ".Trash"
    public nonisolated let root: URL
    public nonisolated let manifest: VaultManifest
    public nonisolated let contentStore: any VaultContentStore
    public nonisolated let sessionLease: VaultSessionLease?
    public nonisolated let accessGate: VaultAccessGate?
    private var cache: [String: (Date?, Int?, NoteRecord)] = [:]
    private let sourceCache = SourceSnapshotCache()
    private var cacheInvalidatorID: UUID?
    private var downloadingSources: [UUID: SourceRecord] = [:]
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
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
        guard manifest.formatVersion == 1 else {
            throw VaultError.invalid("This vault uses an unsupported format version.")
        }
        // v1 has no required storage schema. A declaration must not silently select
        // a future authority merely because Codable ignores unknown fields.
        let declaration = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let storage = declaration?["storage"] {
            guard let storage = storage as? [String: Any],
                  storage["mode"] as? String == "markdown",
                  storage["schemaVersion"] == nil,
                  storage["database"] == nil,
                  storage["localOnly"] == nil else {
                throw VaultError.invalid("This vault uses an unsupported or malformed storage declaration.")
            }
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
        for name in ["Wiki", "Sources", trashDirectoryName, "Conflicts"] {
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
        let manifest: VaultManifest
        // Only provider-confirmed missing metadata in an empty root permits creation.
        // Unavailable cloud metadata and damaged/nonempty vaults never initialize.
        if let existing = try inspectManifestIfPresent(at: accessRoot, contentStore: store,
            storageProvider: storageProvider, allowCreation: create) {
            manifest = existing
        } else {
            guard create else { throw VaultError.invalid("Choose a vault folder containing vault.json, or create a new vault.") }
            manifest = VaultManifest()
            try store.write(JSONEncoder().encode(manifest), at: "vault.json", condition: .createOnly)
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
        for name in ["Wiki", "Sources", trashDirectoryName, "Conflicts"] {
            let directory = root.appendingPathComponent(name)
            guard directory.resolvingSymlinksInPath() == directory else { throw VaultContentStoreError.unsafePath(name) }
            if !fm.fileExists(atPath: directory.path) { try store.createDirectory(at: name) }
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw VaultContentStoreError.unsupportedItem(name)
            }
        }
        return FileVaultRepository(
            root: root,
            manifest: manifest,
            contentStore: store,
            sessionLease: sessionLease,
            accessGate: accessGate
        )
    }

    private init(
        root: URL,
        manifest: VaultManifest,
        contentStore: any VaultContentStore,
        sessionLease: VaultSessionLease? = nil,
        accessGate: VaultAccessGate? = nil
    ) {
        self.root = root
        self.manifest = manifest
        self.contentStore = contentStore
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

    public func scan(progress: (@Sendable (ScanBatch) -> Void)? = nil) throws -> ScanBatch {
        try scan(sourceLoading: .complete, progress: progress)
    }

    public func scan(sourceLoading: SourceLoadingPolicy, progress: (@Sendable (ScanBatch) -> Void)? = nil) throws -> ScanBatch {
        defer { if Task.isCancelled { sourceCache.clear() } }
        try Task.checkCancellation()
        try validateAccess(operation: "scan")
        var result = ScanBatch(), chunk = ScanBatch()
        var seenIDs: Set<UUID> = [], seenPaths: Set<String> = []
        var duplicateIDs: Set<UUID> = []
        let wiki = root.appendingPathComponent("Wiki")
        var enumerationError: String?
        guard let enumerator = fm.enumerator(at: wiki, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey], options: [], errorHandler: { url, error in
            enumerationError = "Cannot read \(url.lastPathComponent): \(error.localizedDescription)"; return false
        }) else {
            throw VaultError.storage("The Wiki directory cannot be read.")
        }
        for case let url as URL in enumerator {
            try validateAccess(operation: "scan")
            if url.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(root.path + "/Wiki/") else { result.issues.append("Skipped wiki file outside the vault: \(url.lastPathComponent)"); continue }
            let path = String(canonical.path.dropFirst(root.path.count + 1))
            seenPaths.insert(path)
            do {
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey])
                guard isAvailable(values) else {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    result.issues.append("Downloading \(url.lastPathComponent) from iCloud. It will appear when available.")
                    if let old = cache[path]?.2 { result.notes.append(old) }
                    continue
                }
                let note: NoteRecord
                if let previous = cache[path], previous.0 == values.contentModificationDate, previous.1 == values.fileSize {
                    note = previous.2
                } else {
                    note = try NoteCodec.decode(contentStore.read(at: path), path: path, vaultID: manifest.id)
                    cache[path] = (values.contentModificationDate, values.fileSize, note)
                }
                guard seenIDs.insert(note.id).inserted else {
                    duplicateIDs.insert(note.id)
                    result.notes.removeAll { $0.id == note.id }
                    chunk.notes.removeAll { $0.id == note.id }
                    result.issues.append("Duplicate note ID in \(path). Resolve the duplicate files before editing this page.")
                    continue
                }
                guard !duplicateIDs.contains(note.id) else { continue }
                result.notes.append(note); chunk.notes.append(note)
                if chunk.notes.count >= 128 { progress?(chunk); chunk = ScanBatch() }
            } catch let accessError as VaultAccessError {
                throw accessError
            } catch { result.issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        cache = cache.filter { seenPaths.contains($0.key) }
        if let enumerationError { throw VaultError.storage(enumerationError) }
        let sourceBatch = try scanSources(loading: sourceLoading)
        result.sources = sourceBatch.sources
        result.issues += sourceBatch.issues
        result.sourceVerification = sourceBatch.sourceVerification
        result.sourceContentRevisions = sourceBatch.sourceContentRevisions
        chunk.sources = sourceBatch.sources
        progress?(chunk)
        if let conflicts = try? fm.contentsOfDirectory(at: root.appendingPathComponent("Conflicts"), includingPropertiesForKeys: nil), !conflicts.isEmpty {
            result.issues.append("\(conflicts.count) preserved conflict file(s). Use Reveal Vault to inspect the Conflicts folder.")
        }
        result.notes.sort { $0.updatedAt > $1.updatedAt }
        result.sources.sort { $0.metadata.capturedAt > $1.metadata.capturedAt }
        try Task.checkCancellation()
        try validateAccess(operation: "scan.complete")
        return result
    }

    /// Discovery exposes explicit metadata-only records. Complete scans preserve the legacy
    /// full-content contract; verifyOriginals deliberately bypasses change-indicator reuse.
    public func scanSources(loading: SourceLoadingPolicy = .metadataOnly, sourceID: UUID? = nil) throws -> ScanBatch {
        try SourceScanPerformance.measure("Source Scan") { try discoverSources(loading: loading, sourceID: sourceID) }
    }

    private func discoverSources(loading: SourceLoadingPolicy, sourceID: UUID?) throws -> ScanBatch {
        do {
            try Task.checkCancellation()
            try validateAccess(operation: "scanSources")
            var batch = ScanBatch()
            let directories = try fm.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
            var seen: Set<UUID> = []
            for directory in directories {
                try Task.checkCancellation()
                try validateAccess(operation: "scanSources.item")
                guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
                seen.insert(id)
                if let sourceID, sourceID != id { continue }
                do {
                    let path = "Sources/" + directory.lastPathComponent + "/"
                    let bytes = try contentStore.read(at: path + "metadata.json")
                    var metadata = try JSONDecoder().decode(SourceMetadata.self, from: bytes)
                    guard metadata.id == id,
                          metadata.storedFilename == URL(fileURLWithPath: metadata.storedFilename).lastPathComponent,
                          !metadata.storedFilename.hasPrefix(".") else { throw VaultError.invalid("Invalid source metadata.") }
                    let token: VaultContentChangeToken?
                    do { token = try metadata.isLinked ? nil : contentStore.changeToken(at: path + metadata.storedFilename) }
                    catch let error as VaultAccessError { throw error }
                    catch {
                        sourceCache.remove(id)
                        guard loading == .metadataOnly else { throw error }
                        let issue = Self.sourceAvailabilityMessage(error, linked: false)
                        batch.sources.append(SourceRecord(metadata: metadata, body: "", availabilityIssue: issue, contentState: .unavailable))
                        batch.sourceVerification[id] = .notVerified
                        batch.issues.append("Source \(metadata.title): \(issue)")
                        continue
                    }
                    let old = sourceCache.entry(id)
                    let reusable = token != nil && old?.token == token && old?.metadataBytes == bytes
                    if !reusable { sourceCache.remove(id) }
                    if loading == .metadataOnly {
                        if reusable, let old { metadata = old.record.metadata }
                        else if let token { metadata.fileSize = Int(exactly: token.size) }
                        batch.sources.append(SourceRecord(metadata: metadata, body: "", availabilityIssue: metadata.webAvailabilityIssue ?? "Not verified", contentState: .notLoaded))
                        batch.sourceVerification[id] = .notVerified
                        if reusable, let old { batch.sourceContentRevisions[id] = old.contentRevision }
                        continue
                    }
                    if loading == .complete, reusable, let old {
                        try validateAccess(operation: "scanSources.cached")
                        SourceScanPerformance.event("Source Cache Reuse")
                        batch.sources.append(old.record)
                        batch.sourceContentRevisions[id] = old.contentRevision
                        batch.sourceVerification[id] = .reusedPreviouslyVerified
                        continue
                    }
                    let data: Data
                    do {
                        data = try SourceScanPerformance.measure("Source Original Read") {
                            try metadata.linkedBookmark.map(Self.readLinkedSource) ?? contentStore.read(at: path + metadata.storedFilename)
                        }
                    } catch let error as VaultAccessError { throw error }
                    catch {
                        guard metadata.isLinked else { throw error }
                        let issue = Self.sourceAvailabilityMessage(error, linked: true)
                        batch.sources.append(SourceRecord(metadata: metadata, body: "", availabilityIssue: issue, contentState: .unavailable))
                        batch.sourceVerification[id] = .notVerified
                        batch.issues.append("Source \(metadata.title): \(issue)")
                        continue
                    }
                    guard metadata.isLinked || digest(data) == metadata.sha256 else {
                        throw VaultError.invalid("Original source has changed; its checksum does not match. Restore the original or import a new copy.")
                    }
                    metadata.fileSize = data.count
                    let body = try SourceScanPerformance.measure("Source Text Extraction") {
                        try Self.sourceText(data, filename: metadata.originalFilename)
                    }
                    let source = SourceRecord(metadata: metadata, body: body, availabilityIssue: metadata.webAvailabilityIssue)
                    let revision = digest(Data(body.utf8))
                    try Task.checkCancellation()
                    try validateAccess(operation: "scanSources.loaded")
                    // Recheck after reading; never associate bytes with a token captured before a concurrent replacement.
                    if let token, try contentStore.changeToken(at: path + metadata.storedFilename) == token {
                        sourceCache.insert(.init(metadataBytes: bytes, token: token, record: source, contentRevision: revision), id: id)
                    }
                    batch.sources.append(source)
                    batch.sourceContentRevisions[id] = revision
                    batch.sourceVerification[id] = metadata.isLinked ? .linkedContentRead : .verifiedThisScan
                } catch let error as VaultAccessError { throw error }
                catch is CancellationError { throw CancellationError() }
                catch {
                    sourceCache.remove(id)
                    batch.issues.append("Source \(directory.lastPathComponent): \(error.localizedDescription). Incomplete imports are left intact for recovery.")
                    // A metadata-only consumer can still display an inaccessible original, without old plaintext.
                    if let data = try? contentStore.read(at: "Sources/" + directory.lastPathComponent + "/metadata.json"),
                       let metadata = try? JSONDecoder().decode(SourceMetadata.self, from: data), metadata.id == id,
                       case VaultContentStoreError.unavailable = error {
                        batch.sources.append(SourceRecord(metadata: metadata, body: "", availabilityIssue: Self.sourceAvailabilityMessage(error, linked: metadata.isLinked), contentState: .unavailable))
                        batch.sourceVerification[id] = .notVerified
                    }
                }
            }
            if sourceID == nil { sourceCache.retain(seen) }
            else if let sourceID, !seen.contains(sourceID) { sourceCache.remove(sourceID) }
            let ids = Set(batch.sources.map(\.id))
            for pending in downloadingSources.values where !ids.contains(pending.id) && (sourceID == nil || sourceID == pending.id) {
                var pending = pending; pending.contentState = .unavailable
                batch.sources.append(pending); batch.sourceVerification[pending.id] = .notVerified
            }
            batch.sources.sort { $0.metadata.capturedAt > $1.metadata.capturedAt }
            try Task.checkCancellation()
            try validateAccess(operation: "scanSources.complete")
            return batch
        } catch {
            sourceCache.clear()
            throw error
        }
    }

    /// Demand-driven loading by identity always rediscovers current metadata through the store.
    public func loadSource(id: UUID, verifyOriginal: Bool = false) throws -> SourceRecord {
        let batch = try scanSources(loading: verifyOriginal ? .verifyOriginals : .complete, sourceID: id)
        guard let source = batch.sources.first(where: { $0.id == id }), source.contentState == .loaded else {
            throw VaultError.unavailable(batch.issues.first ?? "Source is unavailable. Refresh the vault.")
        }
        return source
    }

    public func create(title: String = "Untitled", body: String = "") throws -> NoteRecord {
        try createPage(title: title, body: body, source: nil, lcc: nil)
    }

    public func create(title: String = "Untitled", body: String = "", lcc: String?) throws -> NoteRecord {
        try createPage(title: title, body: body, source: nil, lcc: lcc)
    }

    public func create(title: String, body: String, source: SourceRecord) throws -> NoteRecord {
        try createPage(title: title, body: body, source: source, lcc: nil)
    }

    public func create(title: String, body: String, source: SourceRecord, lcc: String?) throws -> NoteRecord {
        try createPage(title: title, body: body, source: source, lcc: lcc)
    }

    private func createPage(title: String, body: String, source: SourceRecord?, lcc: String?) throws -> NoteRecord {
        try validateAccess(operation: "create")
        let snapshot = try scan()
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
        note.relativePath = availablePath(title: actualTitle)
        let data = try NoteCodec.encode(note)
        do { try contentStore.write(data, at: note.relativePath, condition: .createOnly) }
        catch VaultContentStoreError.alreadyExists { throw VaultError.storage("A file appeared at this path. Please try again.") }
        return try NoteCodec.decode(data, path: note.relativePath, vaultID: manifest.id)
    }

    public func setEditingLock(note: NoteRecord, locked: Bool) throws -> NoteRecord {
        try validateAccess(operation: "setEditingLock")
        var updated = note
        updated.editingLocked = locked
        return try save(note: updated, title: note.title, body: note.body, tags: note.tags, preserveUpdatedAt: true)
    }

    public func save(note: NoteRecord, title: String, body: String, tags: [String]) throws -> NoteRecord {
        try validateAccess(operation: "save")
        return try save(note: note, title: title, body: body, tags: tags, preserveUpdatedAt: false)
    }

    private func save(note: NoteRecord, title: String, body: String, tags: [String], preserveUpdatedAt: Bool) throws -> NoteRecord {
        try validateAccess(operation: "save")
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw VaultError.invalid("A wiki page needs a title.") }
        let snapshot = try scan()
        if fm.fileExists(atPath: root.appendingPathComponent(note.relativePath).path), !snapshot.notes.contains(where: { $0.id == note.id }) {
            throw VaultError.invalid("This page is invalid or has a duplicate ID. Inspect the vault notices before saving. Your local draft is preserved.")
        }
        guard !titleExists(title, in: snapshot.notes.filter { $0.id != note.id }) else { throw VaultError.duplicateTitle(title) }
        if snapshot.notes.first(where: { $0.id == note.id })?.isEditingLocked == true,
           title != note.title || body != note.body || normalizeTags(tags) != note.tags || snapshot.notes.first(where: { $0.id == note.id })?.linkedSourceIDs != note.linkedSourceIDs || snapshot.notes.first(where: { $0.id == note.id })?.lcc != note.lcc {
            throw VaultError.invalid("This article is locked. Unlock it before editing.")
        }
        var updated = note
        updated.title = title; updated.body = body; updated.tags = normalizeTags(tags)
        if snapshot.notes.first(where: { $0.id == note.id })?.title != title { updated.aiTitleProvenance = nil }
        if snapshot.notes.first(where: { $0.id == note.id })?.lcc != updated.lcc {
            updated.aiLCCProvenance = nil; updated.lccClassification = nil
        }
        updated.updatedAt = preserveUpdatedAt ? note.updatedAt : timestamp()
        if updated.createdAt.isEmpty { updated.createdAt = updated.updatedAt }
        if normalized(title) != normalized(note.title), !updated.aliases.contains(note.title) { updated.aliases.append(note.title) }
        let data = try NoteCodec.encode(updated)
        let url = try checkedWikiURL(note.relativePath)
        do {
            let current = try contentStore.read(at: note.relativePath)
            guard digest(current) == note.contentHash else { throw VaultContentStoreError.stale(note.relativePath) }
            // The adapter checks these exact bytes again inside write coordination.
            try contentStore.write(data, at: note.relativePath, condition: .replace(expected: current))
        } catch let error as VaultContentStoreError {
            switch error {
            case .missing, .stale, .cloudConflict:
                try preservePageConflict(data, note: note, at: url)
            case .unavailable:
                throw VaultError.unavailable("Downloading \(url.lastPathComponent) from iCloud. Try again when the download finishes.")
            default: throw error
            }
        }
        cache.removeValue(forKey: note.relativePath)
        // Keep the filename stable on title changes: aliases and metadata carry identity.
        return try NoteCodec.decode(data, path: note.relativePath, vaultID: manifest.id)
    }

    private func preservePageConflict(_ data: Data, note: NoteRecord, at url: URL) throws {
        var failure: Error?, coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinatedURL) ?? []
                let path = "Conflicts/\(note.id.uuidString)-\(UUID().uuidString).md"
                try contentStore.write(data, at: path, condition: .createOnly)
                // OS-owned versions are external to the adapter's vault-relative boundary.
                // Preserve every version before resolving any of them.
                for version in versions {
                    try contentStore.write(Self.coordinatedRead(version.url), at: "Conflicts/cloud-\(UUID().uuidString).md", condition: .createOnly)
                }
                for version in versions { version.isResolved = true; try? version.remove() }
                throw VaultError.conflict(root.appendingPathComponent(path).path)
            } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinationError { throw coordinationError }
    }

    public func setSourceReference(note: NoteRecord, sourceID: UUID, linked: Bool) throws -> NoteRecord {
        try validateAccess(operation: "setSourceReference")
        guard !note.isEditingLocked else { throw VaultError.invalid("Unlock this article before editing its sources.") }
        if linked, !((try scan()).sources.contains { $0.id == sourceID }) {
            throw VaultError.invalid("This source is unavailable. Refresh before adding it.")
        }
        var updated = note
        var ids = Set(note.linkedSourceIDs)
        if linked { ids.insert(sourceID) } else { ids.remove(sourceID) }
        updated.sourceIDs = ids.sorted { $0.uuidString < $1.uuidString }
        return try save(note: updated, title: note.title, body: note.body, tags: note.tags)
    }

    public func trash(note: NoteRecord) throws {
        try validateAccess(operation: "trash")
        _ = try checkedWikiURL(note.relativePath)
        try ensureTrashDirectory()
        let destination = root.appendingPathComponent("\(Self.trashDirectoryName)/trash-\(Int(Date().timeIntervalSince1970))-\(note.id.uuidString)-\(UUID().uuidString).md")
        try movePage(from: note.relativePath, to: Self.trashDirectoryName + "/" + destination.lastPathComponent,
                     hash: note.contentHash, staleMessage: "This page changed externally. Reload it before moving it to trash.")
        cache.removeValue(forKey: note.relativePath)
    }

    public func trashedPages() throws -> [TrashedPage] {
        try validateAccess(operation: "trashedPages")
        let directory = root.appendingPathComponent(Self.trashDirectoryName)
        try ensureTrashDirectory()
        var files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
        var migrationIssues: [String: String] = [:]
        let legacy = root.appendingPathComponent(Self.legacyTrashDirectoryName)
        if fm.fileExists(atPath: legacy.path) {
            guard legacy.resolvingSymlinksInPath().path == legacy.path else { throw VaultError.invalid("The legacy Trash directory must not be a symbolic link.") }
            for url in try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) where url.pathExtension.lowercased() == "md" {
                do { files.append(try migrateTrashedFile(url)) }
                catch let accessError as VaultAccessError { throw accessError }
                catch {
                    files.append(url)
                    migrationIssues[url.lastPathComponent] = "Could not preserve this legacy Trash file in Removed Pages: " + error.localizedDescription
                }
            }
        }
        return try files.map { url in
                let path = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
                var data: Data?
                do {
                    _ = try checkedTrashURL(path)
                    let bytes = try contentStore.read(at: path); data = bytes
                    // UI.R.REM03: classify the validated relative path so URL directory hints
                    // and canonical representations cannot hide a failed legacy migration.
                    let issue = path.hasPrefix(Self.legacyTrashDirectoryName + "/")
                        ? migrationIssues[url.lastPathComponent] : nil
                    return TrashedPage(note: try NoteCodec.decode(bytes, path: path, vaultID: manifest.id), readIssue: issue)
                } catch let accessError as VaultAccessError {
                    throw accessError
                } catch {
                    // Keep damaged/unavailable entries visible without blocking healthy pages or refresh.
                    var note = try NoteCodec.decode(Data(), path: path, vaultID: manifest.id)
                    note.contentHash = data.map(digest) ?? ""
                    return TrashedPage(note: note, readIssue: error.localizedDescription)
                }
            }.sorted { $0.note.title.localizedStandardCompare($1.note.title) == .orderedAscending }
    }
    private func migrateTrashedFile(_ url: URL) throws -> URL {
        let path = Self.legacyTrashDirectoryName + "/" + url.lastPathComponent
        _ = try checkedTrashURL(path)
        var destination = root.appendingPathComponent(Self.trashDirectoryName).appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent(Self.trashDirectoryName).appendingPathComponent(UUID().uuidString + ".md")
        }
        try contentStore.move(from: path, to: Self.trashDirectoryName + "/" + destination.lastPathComponent,
                              expected: .file(contentStore.read(at: path)))
        return destination
    }
    public func restore(_ page: TrashedPage) throws {
        try validateAccess(operation: "restore")
        guard page.canRestore else { throw VaultError.invalid("Repair this page's file before restoring it.") }
        let snapshot = try scan()
        guard !snapshot.notes.contains(where: { $0.id == page.note.id }),
              !snapshot.issues.contains(where: { $0.contains("Duplicate note ID") }) else {
            throw VaultError.invalid("A page with this identity already exists. Resolve the duplicate before restoring.")
        }
        guard !titleExists(page.note.title, in: snapshot.notes) else { throw VaultError.duplicateTitle(page.note.title) }
        _ = try checkedTrashURL(page.id)
        let path = availablePath(title: page.note.title)
        _ = try checkedWikiURL(path)
        try movePage(from: page.id, to: path, hash: page.note.contentHash,
                     staleMessage: "This trashed page changed. Refresh Trash before restoring.")
    }
    public func permanentlyDelete(_ page: TrashedPage) throws {
        try validateAccess(operation: "permanentlyDelete")
        guard page.canPermanentlyDelete else { throw VaultError.invalid("This trashed page could not be read. Refresh Trash before deleting it.") }
        _ = try checkedTrashURL(page.id)
        let message = "This trashed page changed. Refresh Trash before deleting."
        do {
            try contentStore.delete(at: page.id, expected: checkedPageSnapshot(page.id, hash: page.note.contentHash, message: message))
        } catch VaultContentStoreError.stale { throw VaultError.invalid(message) }
        catch VaultContentStoreError.cloudConflict {
            throw VaultError.invalid("Resolve this page's cloud conflicts before permanently deleting it.")
        }
    }
    private func checkedPageSnapshot(_ path: String, hash: String, message: String) throws -> VaultContentSnapshot {
        let bytes = try contentStore.read(at: path)
        guard digest(bytes) == hash else { throw VaultError.invalid(message) }
        return .file(bytes)
    }
    private func movePage(from source: String, to destination: String, hash: String, staleMessage: String) throws {
        do {
            try contentStore.move(from: source, to: destination,
                                  expected: checkedPageSnapshot(source, hash: hash, message: staleMessage))
        } catch VaultContentStoreError.stale { throw VaultError.invalid(staleMessage) }
        catch VaultContentStoreError.alreadyExists {
            throw VaultError.invalid("The move destination is occupied. Refresh and try again.")
        }
    }

    public func emptyTrash(_ pages: [TrashedPage]) -> [String] {
        // Delete only the confirmed snapshot; keep changed/conflicted files and report partial failures.
        var failures: [String] = []
        for page in pages {
            do { try permanentlyDelete(page) }
            catch { failures.append("\(page.note.title): \(error.localizedDescription)") }
        }
        return failures
    }
    private func ensureTrashDirectory() throws {
        let directory = root.appendingPathComponent(Self.trashDirectoryName)
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw VaultError.invalid("The Trash directory must not be a symbolic link.") }
        if !fm.fileExists(atPath: directory.path) {
            try contentStore.createDirectory(at: Self.trashDirectoryName)
        }
    }
    private func checkedTrashURL(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        let directories = [Self.trashDirectoryName, Self.legacyTrashDirectoryName].map { root.appendingPathComponent($0).standardizedFileURL }
        guard directories.contains(url.deletingLastPathComponent()), url.pathExtension.lowercased() == "md",
              url.resolvingSymlinksInPath() == url else { throw VaultError.invalid("Invalid trash file path.") }
        return url
    }

    private func rejectDuplicateSource(checksum: String, linkedURL: URL? = nil, excludingID: UUID? = nil) throws {
        let directories = try fm.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent), id != excludingID else { continue }
            let rawMetadata: Data
            do {
                rawMetadata = try contentStore.read(at: "Sources/" + directory.lastPathComponent + "/metadata.json")
            } catch let accessError as VaultAccessError {
                throw accessError
            } catch {
                continue
            }
            guard let metadata = try? JSONDecoder().decode(SourceMetadata.self, from: rawMetadata),
                  metadata.id == id else { continue }
            var sameLinkedFile = false
            if let linkedURL, let bookmark = metadata.linkedBookmark, !bookmark.isEmpty {
                var stale = false
                if let existing = try? Self.resolveBookmarkData(bookmark, isStale: &stale) {
                    sameLinkedFile = existing.standardizedFileURL.resolvingSymlinksInPath() == linkedURL.standardizedFileURL.resolvingSymlinksInPath()
                }
            }
            let sameChecksum = !checksum.isEmpty && !metadata.sha256.isEmpty && metadata.sha256 == checksum
            guard !sameChecksum, !sameLinkedFile else {
                throw VaultError.invalid("File already added as a source: ‘" + metadata.title + "’.")
            }
        }
    }

    public func importSource(data: Data, filename: String, title: String, originURL: String?) throws -> SourceRecord {
        try validateAccess(operation: "importSource")
        return try publishSource(data: data, filename: filename, title: title, originURL: originURL, isURLSource: false)
    }

    public func importURLSource(_ address: String, fetch: @Sendable (URL) async throws -> WebSourceFetch = WebSourceFetcher.fetch) async throws -> SourceRecord {
        try validateAccess(operation: "importURLSource")
        let url = try WebSourceFetcher.validatedURL(address)
        let fetched = try await fetch(url)
        try validateAccess(operation: "importURLSource")
        return try publishSource(data: fetched.data, filename: fetched.filename, title: url.host ?? address, originURL: url.absoluteString, isURLSource: true)
    }

    public func checkURLSourceAvailability(_ source: SourceRecord, fetch: @Sendable (URL) async throws -> WebSourceFetch = WebSourceFetcher.fetch) async throws -> String {
        try validateAccess(operation: "checkURLSourceAvailability")
        guard source.metadata.isURLSource == true, let address = source.metadata.originURL else { throw VaultError.invalid("This source was not fetched from a URL.") }
        let issue: String?
        do { _ = try await fetch(WebSourceFetcher.validatedURL(address)); issue = nil }
        catch { issue = "Archived fetch · Unavailable: " + error.localizedDescription }
        try validateAccess(operation: "checkURLSourceAvailability")
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        let bytes = try contentStore.read(at: path)
        var metadata = try JSONDecoder().decode(SourceMetadata.self, from: bytes)
        guard metadata.id == source.id, metadata.sha256 == source.metadata.sha256, metadata.originURL == address, metadata.isURLSource == true else { throw VaultError.invalid("Source changed. Refresh before checking again.") }
        metadata.webAvailabilityIssue = issue
        try contentStore.write(encoder.encode(metadata), at: path, condition: .replace(expected: bytes))
        return issue ?? "Available"
    }

    private func publishSource(id: UUID = UUID(), capturedAt: String? = nil, data: Data, filename: String, title: String, originURL: String?, isURLSource: Bool) throws -> SourceRecord {
        try validateAccess(operation: "publishSource")
        guard data.count <= Self.maximumImportBytes else { throw VaultError.invalid("Files larger than 2 MB must be linked instead of imported.") }
        try rejectDuplicateSource(checksum: digest(data), excludingID: id)
        let body = try Self.sourceText(data, filename: filename)
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let storedExtension = ext.isEmpty ? "bin" : ext
        if let originURL, !originURL.isEmpty {
            guard let url = URL(string: originURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw VaultError.invalid("The origin URL must be an http or https address.") }
        }
        var metadata = SourceMetadata(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent : title, capturedAt: capturedAt ?? timestamp(), originalFilename: URL(fileURLWithPath: filename).lastPathComponent, originURL: originURL?.isEmpty == true ? nil : originURL, sha256: digest(data), fileSize: data.count, storedFilename: "original.\(storedExtension)")
        metadata.isURLSource = isURLSource ? true : nil
        try stageSource(metadata, original: data)
        return SourceRecord(metadata: metadata, body: body)
    }

    private func stageSource(_ metadata: SourceMetadata, original: Data? = nil) throws {
        let pending = "Sources/.import-" + metadata.id.uuidString
        try contentStore.createDirectory(at: pending)
        // Failed publication deliberately retains the staging directory for recovery.
        var files: [String: Data] = ["metadata.json": try encoder.encode(metadata)]
        if let original {
            files[metadata.storedFilename] = original
            try contentStore.write(original, at: pending + "/" + metadata.storedFilename, condition: .createOnly)
        }
        try contentStore.write(files["metadata.json"]!, at: pending + "/metadata.json", condition: .createOnly)
        try contentStore.move(from: pending, to: "Sources/" + metadata.id.uuidString.lowercased(), expected: .directory(files))
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

    public func beginSourceDownload(at url: URL, shouldImport: Bool) throws -> SourceRecord {
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
        try rejectDuplicateSource(checksum: "", linkedURL: targetURL)
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

    public func completeSourceDownload(id: UUID, at url: URL, data: Data, shouldImport: Bool) throws -> SourceRecord {
        try validateAccess(operation: "completeSourceDownload")
        guard let pending = downloadingSources[id] else {
            throw VaultError.invalid("Source download is no longer active.")
        }
        let targetURL = Self.logicalCloudURL(url)
        defer { downloadingSources.removeValue(forKey: id) }
        if shouldImport {
            return try publishSource(
                id: id,
                capturedAt: pending.metadata.capturedAt,
                data: data,
                filename: targetURL.lastPathComponent,
                title: pending.title,
                originURL: nil,
                isURLSource: false
            )
        }
        try rejectDuplicateSource(checksum: digest(data), linkedURL: targetURL, excludingID: id)
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
        try stageSource(metadata)
        return SourceRecord(metadata: metadata, body: body)
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
    ) throws -> SourceRecord {
        try validateAccess(operation: "importSource")
        return try publishSource(
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

    public func linkSources(at url: URL, maximumFiles: Int) throws -> [SourceRecord] {
        try validateAccess(operation: "linkSources")
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VaultError.invalid("Choose files only. Folder linking is no longer supported.") }
        let files = [url]
        // Validate every member before publishing any records.
        let prepared = try files.sorted { $0.path < $1.path }.map { file -> SourceRecord in
            let data = try Self.coordinatedRead(file)
            try rejectDuplicateSource(checksum: digest(data), linkedURL: file)
            let body = try Self.sourceText(data, filename: file.lastPathComponent)
            let bookmark = try Self.makeBookmarkData(for: file)
            let metadata = SourceMetadata(id: UUID(), title: file.deletingPathExtension().lastPathComponent, capturedAt: timestamp(), originalFilename: file.lastPathComponent, originURL: nil, sha256: digest(data), fileSize: data.count, linkedBookmark: bookmark, storedFilename: "original." + file.pathExtension.lowercased())
            return SourceRecord(metadata: metadata, body: body)
        }
        for source in prepared {
            try stageSource(source.metadata)
        }
        return prepared
    }

    func invalidateSummaryCaches(pagePath: String?, sourceID: UUID?) {
        if let pagePath { cache.removeValue(forKey: pagePath) }
        if let sourceID { sourceCache.remove(sourceID) }
    }

    public func renameSource(_ source: SourceRecord, title: String, summary: String? = nil) throws -> SourceRecord {
        try renameSource(source, title: title, summary: summary, lcc: nil)
    }

    public func renameSource(_ source: SourceRecord, title: String, summary: String? = nil, lcc: String? = nil) throws -> SourceRecord {
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
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        let bytes = try contentStore.read(at: path)
        var metadata = try JSONDecoder().decode(SourceMetadata.self, from: bytes)
        guard metadata.id == source.id, metadata.title == source.title,
              metadata.sha256 == source.metadata.sha256, metadata.aiSummary == source.metadata.aiSummary,
              cleanLCC == nil || metadata.lcc == source.metadata.lcc,
              metadata.linkedBookmark == source.metadata.linkedBookmark,
              metadata.storedFilename == source.metadata.storedFilename else { throw VaultError.invalid("Source changed while its title was generated. Refresh and try again.") }
        if metadata.title != title { metadata.aiTitleProvenance = nil }
        metadata.title = title
        if let summary { metadata.aiSummary = summary; metadata.aiSummaryProvenance = nil }
        if let cleanLCC { metadata.lcc = cleanLCC; metadata.aiLCCProvenance = nil; metadata.lccClassification = nil }
        try contentStore.write(encoder.encode(metadata), at: path, condition: .replace(expected: bytes))
        return SourceRecord(metadata: metadata, body: source.body, availabilityIssue: metadata.webAvailabilityIssue ?? (source.contentState == .notLoaded ? "Not verified" : source.availabilityIssue), contentState: source.contentState)
    }

    public func updateSourceLCC(_ source: SourceRecord, lcc: String?) throws -> SourceRecord {
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
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        let bytes = try contentStore.read(at: path)
        var metadata = try JSONDecoder().decode(SourceMetadata.self, from: bytes)
        guard metadata.id == source.id,
              metadata.sha256 == source.metadata.sha256,
              metadata.linkedBookmark == source.metadata.linkedBookmark,
              metadata.storedFilename == source.metadata.storedFilename else {
            throw VaultError.invalid("Source changed while updating LCC metadata. Refresh and try again.")
        }
        metadata.lcc = cleanLCC
        metadata.aiLCCProvenance = nil
        metadata.lccClassification = nil
        try contentStore.write(encoder.encode(metadata), at: path, condition: .replace(expected: bytes))
        return SourceRecord(metadata: metadata, body: source.body, availabilityIssue: metadata.webAvailabilityIssue ?? (source.contentState == .notLoaded ? "Not verified" : source.availabilityIssue), contentState: source.contentState)
    }

    public func deleteSource(_ source: SourceRecord) throws {
        try validateAccess(operation: "deleteSource")
        sourceCache.remove(source.id)
        if downloadingSources.removeValue(forKey: source.id) != nil {
            let directory = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased())
            if !fm.fileExists(atPath: directory.path) { return }
        }
        let directory = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased())
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw VaultError.invalid("Source directory cannot be a symbolic link.") }
        try ensureTrashDirectory()
        let destination = root.appendingPathComponent(Self.trashDirectoryName).appendingPathComponent("trash-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).source")
        let path = "Sources/" + source.id.uuidString.lowercased()
        let snapshot = try contentStore.snapshot(at: path)
        guard case .directory(let files) = snapshot, let bytes = files["metadata.json"] else { throw VaultError.invalid("Invalid source directory.") }
        let metadata = try JSONDecoder().decode(SourceMetadata.self, from: bytes)
        guard metadata.id == source.id, metadata.title == source.title,
              metadata.sha256 == source.metadata.sha256, metadata.aiSummary == source.metadata.aiSummary,
              metadata.linkedBookmark == source.metadata.linkedBookmark,
              metadata.storedFilename == source.metadata.storedFilename,
              metadata.storedFilename == URL(fileURLWithPath: metadata.storedFilename).lastPathComponent,
              !metadata.storedFilename.hasPrefix(".") else { throw VaultError.invalid("Source changed. Refresh before deleting it.") }
        if !metadata.isLinked {
            guard let original = files[metadata.storedFilename], digest(original) == metadata.sha256 else { throw VaultError.invalid("Imported original changed. Refresh before deleting it.") }
        }
        try contentStore.move(from: path, to: Self.trashDirectoryName + "/" + destination.lastPathComponent, expected: snapshot)
    }

    private func titleExists(_ title: String, in notes: [NoteRecord]) -> Bool {
        let key = normalized(title)
        return notes.contains { normalized($0.title) == key || $0.aliases.contains { normalized($0) == key } }
    }
    func availablePath(title: String) -> String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        let name = String(clean.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let base = name.isEmpty ? "Untitled" : name
        var path = "Wiki/\(base).md", n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(path).path) { path = "Wiki/\(base) \(n).md"; n += 1 }
        return path
    }
    private func checkedWikiURL(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = root.appendingPathComponent("Wiki").standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(allowed), url.pathExtension.lowercased() == "md" else { throw VaultError.invalid("Invalid wiki file path.") }
        return url
    }
    private func isAvailable(_ values: URLResourceValues) -> Bool {
        values.ubiquitousItemDownloadingStatus == nil || values.ubiquitousItemDownloadingStatus != .notDownloaded
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

    private static func sourceSnapshotHash(_ snapshot: VaultContentSnapshot) throws -> String {
        guard case .directory(let files) = snapshot else { throw VaultError.invalid("Invalid source directory.") }
        var bytes = Data()
        for name in files.keys.sorted() {
            bytes.append(Data(name.utf8)); bytes.append(0)
            bytes.append(Data(digest(files[name]!).utf8)); bytes.append(0)
        }
        return digest(bytes)
    }
    private func checkedSourceSnapshot(_ path: String, hash: String) throws -> VaultContentSnapshot {
        _ = try checkedSourceTrashURL(path)
        let snapshot = try contentStore.snapshot(at: path)
        guard try Self.sourceSnapshotHash(snapshot) == hash else { throw VaultError.invalid("Source changed. Refresh Trash before changing it.") }
        return snapshot
    }
    private func checkedSourceTrashURL(_ path: String) throws -> URL {
        try ensureTrashDirectory()
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.deletingLastPathComponent() == root.appendingPathComponent(Self.trashDirectoryName).standardizedFileURL,
              url.pathExtension == "source", url.resolvingSymlinksInPath() == url else { throw VaultError.invalid("Invalid source trash path.") }
        return url
    }
    public func trashItems() throws -> [TrashedItem] {
        try validateAccess(operation: "trashItems")
        var items = try trashedPages().map(TrashedItem.page)
        for url in try fm.contentsOfDirectory(at: root.appendingPathComponent(Self.trashDirectoryName), includingPropertiesForKeys: nil) where url.pathExtension == "source" {
            let path = Self.trashDirectoryName + "/" + url.lastPathComponent
            var hash = ""
            do {
                _ = try checkedSourceTrashURL(path)
                let snapshot = try contentStore.snapshot(at: path)
                hash = try Self.sourceSnapshotHash(snapshot)
                guard case .directory(let files) = snapshot, let bytes = files["metadata.json"] else { throw VaultError.invalid("Invalid source metadata.") }
                let metadata = try JSONDecoder().decode(SourceMetadata.self, from: bytes)
                guard metadata.storedFilename == URL(fileURLWithPath: metadata.storedFilename).lastPathComponent,
                      !metadata.storedFilename.hasPrefix(".") else { throw VaultError.invalid("Invalid source filename.") }
                if !metadata.isLinked {
                    guard let original = files[metadata.storedFilename], digest(original) == metadata.sha256 else { throw VaultError.invalid("Imported original changed. Repair it before restoring.") }
                }
                items.append(.source(TrashedSource(id: path, source: SourceRecord(metadata: metadata, body: "", contentState: .notLoaded), contentHash: hash)))
            } catch let accessError as VaultAccessError {
                throw accessError
            } catch { items.append(.source(TrashedSource(id: path, contentHash: hash, readIssue: error.localizedDescription))) }
        }
        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public func restore(_ item: TrashedItem) throws {
        try validateAccess(operation: "restore")
        switch item {
        case .page(let page): try restore(page)
        case .source(let entry):
            guard entry.readIssue == nil, let source = entry.source else { throw VaultError.invalid("Repair this source before restoring it.") }
            sourceCache.remove(source.id)
            let destination = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased())
            guard destination.deletingLastPathComponent().resolvingSymlinksInPath() == destination.deletingLastPathComponent() else { throw VaultError.invalid("Unsafe Sources directory.") }
            try rejectDuplicateSource(checksum: source.metadata.sha256)
            try contentStore.move(from: entry.id, to: "Sources/" + source.id.uuidString.lowercased(), expected: checkedSourceSnapshot(entry.id, hash: entry.contentHash))
        }
    }
    public func permanentlyDelete(_ item: TrashedItem) throws {
        try validateAccess(operation: "permanentlyDelete")
        switch item {
        case .page(let page): try permanentlyDelete(page)
        case .source(let source):
            guard !source.contentHash.isEmpty else { throw VaultError.invalid("Unreadable source cannot be deleted.") }
            try contentStore.delete(at: source.id, expected: checkedSourceSnapshot(source.id, hash: source.contentHash))
        }
    }
    public func emptyTrashItems(_ items: [TrashedItem]) -> [String] {
        var failures: [String] = []
        for item in items {
            do { try permanentlyDelete(item) } catch { failures.append("\(item.title): \(error.localizedDescription)") }
        }
        return failures
    }
    public func expireTrash(now: Date = Date()) throws -> [String] {
        try validateAccess(operation: "expireTrash")
        let items = try trashItems()
        let ledger = root.appendingPathComponent("Trash Retention.json")
        guard ledger.resolvingSymlinksInPath() == ledger else { throw VaultError.invalid("Unsafe trash retention file.") }
        guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: ledger) ?? []).isEmpty else {
            throw VaultError.invalid("Resolve trash retention conflicts first.")
        }
        let path = "Trash Retention.json"
        let bytes: Data?
        do { bytes = try contentStore.read(at: path) }
        catch VaultContentStoreError.missing { bytes = nil }
        var dates = try bytes.map { try JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        let previous = dates
        for item in items where dates[item.id] == nil {
            let parts = URL(fileURLWithPath: item.id).lastPathComponent.split(separator: "-")
            dates[item.id] = parts.first == "trash" && parts.count > 1 ? Double(parts[1]).map(Date.init(timeIntervalSince1970:)) ?? now : now
        }
        // A competing ledger update aborts expiration; never delete using lost retention dates.
        if dates != previous {
            try contentStore.write(JSONEncoder().encode(dates), at: path,
                                   condition: bytes.map { .replace(expected: $0) } ?? .createOnly)
        }
        let expired = items.filter { now.timeIntervalSince(dates[$0.id] ?? now) >= Self.trashRetentionInterval }
        var failures: [String] = []
        for item in expired {
            guard item.readIssue == nil else { failures.append("\(item.title): repair this item before automatic deletion."); continue }
            do { try permanentlyDelete(item) } catch { failures.append("\(item.title): \(error.localizedDescription)") }
        }
        return failures
    }
}
