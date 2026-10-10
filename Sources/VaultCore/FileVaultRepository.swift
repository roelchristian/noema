import Foundation

public protocol VaultRepository: Sendable {
    func scan(progress: (@Sendable (ScanBatch) -> Void)?) async throws -> ScanBatch
    func create(title: String, body: String) async throws -> NoteRecord
    func save(note: NoteRecord, title: String, body: String, tags: [String]) async throws -> NoteRecord
    func trashedPages() async throws -> [TrashedPage]
    func restore(_ page: TrashedPage) async throws
    func permanentlyDelete(_ page: TrashedPage) async throws
    func trash(note: NoteRecord) async throws
    func deleteSource(_ source: SourceRecord) async throws
    func renameSource(_ source: SourceRecord, title: String, summary: String?) async throws -> SourceRecord
    func linkSources(at url: URL, maximumFiles: Int) async throws -> [SourceRecord]
    func importSource(data: Data, filename: String, title: String, originURL: String?) async throws -> SourceRecord
}

public actor FileVaultRepository: VaultRepository {
    public nonisolated let root: URL
    public nonisolated let manifest: VaultManifest
    private var cache: [String: (Date?, Int?, NoteRecord)] = [:]
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }()

    public static func open(root: URL, create: Bool = false) throws -> FileVaultRepository {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent("vault.json")
        let manifest: VaultManifest
        if fm.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(VaultManifest.self, from: coordinatedRead(manifestURL))
            guard manifest.formatVersion == 1 else { throw VaultError.invalid("This vault uses an unsupported format version.") }
        } else {
            guard create else { throw VaultError.invalid("Choose a vault folder containing vault.json, or create a new vault.") }
            manifest = VaultManifest()
            try coordinatedWrite(JSONEncoder().encode(manifest), to: manifestURL)
        }
        for name in ["Wiki", "Sources", ".Trash", "Conflicts"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return FileVaultRepository(root: root, manifest: manifest)
    }
    private init(root: URL, manifest: VaultManifest) { self.root = root; self.manifest = manifest }

    public func scan(progress: (@Sendable (ScanBatch) -> Void)? = nil) throws -> ScanBatch {
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
                    note = try NoteCodec.decode(Self.coordinatedRead(url), path: path, vaultID: manifest.id)
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
            } catch { result.issues.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        cache = cache.filter { seenPaths.contains($0.key) }
        if let enumerationError { throw VaultError.storage(enumerationError) }
        let directories = try fm.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil, options: [])
        for directory in directories {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            do {
                var metadata = try JSONDecoder().decode(SourceMetadata.self, from: Self.coordinatedRead(directory.appendingPathComponent("metadata.json")))
                guard metadata.id.uuidString.lowercased() == directory.lastPathComponent.lowercased(),
                      metadata.storedFilename == URL(fileURLWithPath: metadata.storedFilename).lastPathComponent,
                      !metadata.storedFilename.hasPrefix(".") else { throw VaultError.invalid("Invalid source metadata.") }
                let data: Data
                do {
                    data = try metadata.linkedBookmark.map(Self.readLinkedSource) ?? Self.coordinatedRead(directory.appendingPathComponent(metadata.storedFilename))
                } catch {
                    guard metadata.isLinked else { throw error }
                    let issue = Self.sourceAvailabilityMessage(error, linked: true)
                    let source = SourceRecord(metadata: metadata, body: "", availabilityIssue: issue)
                    result.sources.append(source); chunk.sources.append(source)
                    result.issues.append("Source \(metadata.title): \(issue)")
                    continue
                }
                guard metadata.isLinked || digest(data) == metadata.sha256 else { throw VaultError.invalid("Original source has changed; its checksum does not match. Restore the original or import a new copy.") }
                metadata.fileSize = data.count
                let body = try Self.sourceText(data, filename: metadata.originalFilename)
                let source = SourceRecord(metadata: metadata, body: body)
                result.sources.append(source); chunk.sources.append(source)
                if chunk.sources.count >= 128 { progress?(chunk); chunk = ScanBatch() }
            } catch { result.issues.append("Source \(directory.lastPathComponent): \(error.localizedDescription). Incomplete imports are left intact for recovery.") }
        }
        progress?(chunk)
        if let conflicts = try? fm.contentsOfDirectory(at: root.appendingPathComponent("Conflicts"), includingPropertiesForKeys: nil), !conflicts.isEmpty {
            result.issues.append("\(conflicts.count) preserved conflict file(s). Use Reveal Vault to inspect the Conflicts folder.")
        }
        result.notes.sort { $0.updatedAt > $1.updatedAt }
        result.sources.sort { $0.metadata.capturedAt > $1.metadata.capturedAt }
        return result
    }

    public func create(title: String = "Untitled", body: String = "") throws -> NoteRecord {
        let snapshot = try scan()
        var actualTitle = title, suffix = 2
        while titleExists(actualTitle, in: snapshot.notes) {
            actualTitle = "\(title) \(suffix)"; suffix += 1
        }
        let now = timestamp()
        var note = NoteRecord(id: UUID(), title: actualTitle, aliases: [], tags: [], inlineTags: [], createdAt: now, updatedAt: now, body: body, relativePath: "", contentHash: "", originalHeader: nil)
        note.relativePath = availablePath(title: actualTitle)
        let data = try NoteCodec.encode(note)
        try Self.coordinatedWrite(data, to: root.appendingPathComponent(note.relativePath), mustNotExist: true)
        return try NoteCodec.decode(data, path: note.relativePath, vaultID: manifest.id)
    }

    public func save(note: NoteRecord, title: String, body: String, tags: [String]) throws -> NoteRecord {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw VaultError.invalid("A wiki page needs a title.") }
        let snapshot = try scan()
        if fm.fileExists(atPath: root.appendingPathComponent(note.relativePath).path), !snapshot.notes.contains(where: { $0.id == note.id }) {
            throw VaultError.invalid("This page is invalid or has a duplicate ID. Inspect the vault notices before saving. Your local draft is preserved.")
        }
        guard !titleExists(title, in: snapshot.notes.filter { $0.id != note.id }) else { throw VaultError.duplicateTitle(title) }
        if snapshot.notes.first(where: { $0.id == note.id })?.isEditingLocked == true,
           title != note.title || body != note.body || normalizeTags(tags) != note.tags {
            throw VaultError.invalid("This article is locked. Unlock it before editing.")
        }
        var updated = note
        updated.title = title; updated.body = body; updated.tags = normalizeTags(tags)
        updated.updatedAt = timestamp()
        if updated.createdAt.isEmpty { updated.createdAt = updated.updatedAt }
        if normalized(title) != normalized(note.title), !updated.aliases.contains(note.title) { updated.aliases.append(note.title) }
        let data = try NoteCodec.encode(updated)
        let url = try checkedWikiURL(note.relativePath)
        var operationError: Error?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                let exists = fm.fileExists(atPath: coordinatedURL.path)
                let current = exists ? try Data(contentsOf: coordinatedURL) : Data()
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinatedURL) ?? []
                if !exists || digest(current) != note.contentHash || !versions.isEmpty {
                    let directory = root.appendingPathComponent("Conflicts")
                    let name = "\(note.id.uuidString)-\(UUID().uuidString).md"
                    let draftURL = directory.appendingPathComponent(name)
                    try data.write(to: draftURL, options: .atomic)
                    // Copy all cloud conflict versions before marking any version resolved.
                    for version in versions {
                        let copy = directory.appendingPathComponent("cloud-\(UUID().uuidString).md")
                        try Data(contentsOf: version.url).write(to: copy, options: .atomic)
                    }
                    for version in versions { version.isResolved = true; try? version.remove() }
                    throw VaultError.conflict(draftURL.path)
                }
                try data.write(to: coordinatedURL, options: .atomic)
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinatorError { throw coordinatorError }
        cache.removeValue(forKey: note.relativePath)
        // Keep the filename stable on title changes: aliases and metadata carry identity.
        return try NoteCodec.decode(data, path: note.relativePath, vaultID: manifest.id)
    }

    public func trash(note: NoteRecord) throws {
        let url = try checkedWikiURL(note.relativePath)
        try ensureTrashDirectory()
        var operationError: Error?, coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { coordinatedURL in
            do {
                guard digest(try Data(contentsOf: coordinatedURL)) == note.contentHash else { throw VaultError.invalid("This page changed externally. Reload it before moving it to trash.") }
                let destination = root.appendingPathComponent(".Trash/\(note.id.uuidString)-\(UUID().uuidString).md")
                try fm.moveItem(at: coordinatedURL, to: destination)
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinatorError { throw coordinatorError }
        cache.removeValue(forKey: note.relativePath)
    }

    public func trashedPages() throws -> [TrashedPage] {
        let directory = root.appendingPathComponent(".Trash")
        // Empty folders can disappear externally, including during vault sync.
        try ensureTrashDirectory()
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { url in
                let path = ".Trash/" + url.lastPathComponent
                let checked = try checkedTrashURL(path)
                return TrashedPage(note: try NoteCodec.decode(Self.coordinatedRead(checked), path: path, vaultID: manifest.id))
            }.sorted { $0.note.title.localizedStandardCompare($1.note.title) == .orderedAscending }
    }
    public func restore(_ page: TrashedPage) throws {
        let snapshot = try scan()
        guard !snapshot.notes.contains(where: { $0.id == page.note.id }),
              !snapshot.issues.contains(where: { $0.contains("Duplicate note ID") }) else {
            throw VaultError.invalid("A page with this identity already exists. Resolve the duplicate before restoring.")
        }
        guard !titleExists(page.note.title, in: snapshot.notes) else { throw VaultError.duplicateTitle(page.note.title) }
        let source = try checkedTrashURL(page.id)
        let destination = try checkedWikiURL(availablePath(title: page.note.title))
        var failure: Error?, coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            do {
                guard digest(try Data(contentsOf: from)) == page.note.contentHash else { throw VaultError.invalid("This trashed page changed. Refresh Trash before restoring.") }
                guard !fm.fileExists(atPath: to.path) else { throw VaultError.invalid("The restore destination is occupied. Try again.") }
                try fm.moveItem(at: from, to: to)
            } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinationError { throw coordinationError }
    }
    public func permanentlyDelete(_ page: TrashedPage) throws {
        let url = try checkedTrashURL(page.id)
        var failure: Error?, coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do {
                guard digest(try Data(contentsOf: url)) == page.note.contentHash else { throw VaultError.invalid("This trashed page changed. Refresh Trash before deleting.") }
                guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty else { throw VaultError.invalid("Resolve this page's cloud conflicts before permanently deleting it.") }
                try fm.removeItem(at: url)
            } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinationError { throw coordinationError }
    }
    private func ensureTrashDirectory() throws {
        let directory = root.appendingPathComponent(".Trash")
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }
    private func checkedTrashURL(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        let directory = root.appendingPathComponent(".Trash").standardizedFileURL
        guard url.deletingLastPathComponent() == directory, url.pathExtension.lowercased() == "md",
              url.resolvingSymlinksInPath() == url else { throw VaultError.invalid("Invalid trash file path.") }
        return url
    }

    public func importSource(data: Data, filename: String, title: String, originURL: String?) throws -> SourceRecord {
        guard data.count <= Self.maximumImportBytes else { throw VaultError.invalid("Files larger than 2 MB must be linked instead of imported.") }
        let body = try Self.sourceText(data, filename: filename)
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let storedExtension = ext.isEmpty ? "bin" : ext
        if let originURL, !originURL.isEmpty {
            guard let url = URL(string: originURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw VaultError.invalid("The origin URL must be an http or https address.") }
        }
        let id = UUID()
        let metadata = SourceMetadata(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent : title, capturedAt: timestamp(), originalFilename: URL(fileURLWithPath: filename).lastPathComponent, originURL: originURL?.isEmpty == true ? nil : originURL, sha256: digest(data), fileSize: data.count, storedFilename: "original.\(storedExtension)")
        let pending = root.appendingPathComponent("Sources/.import-\(id.uuidString)")
        try fm.createDirectory(at: pending, withIntermediateDirectories: true)
        do {
            try Self.coordinatedWrite(data, to: pending.appendingPathComponent(metadata.storedFilename))
            try Self.coordinatedWrite(encoder.encode(metadata), to: pending.appendingPathComponent("metadata.json"))
            let final = root.appendingPathComponent("Sources/\(id.uuidString.lowercased())")
            var failure: Error?, coordinatorError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: pending, options: .forMoving, writingItemAt: final, options: [], error: &coordinatorError) { from, to in
                do { try fm.moveItem(at: from, to: to) } catch { failure = error }
            }
            if let failure { throw failure }; if let coordinatorError { throw coordinatorError }
            return SourceRecord(metadata: metadata, body: body)
        } catch {
            // Keep an interrupted import in the hidden staging directory for inspection.
            throw error
        }
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
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
            return linked ? "Linked file not found" : "File not found"
        }
        return "Unavailable: " + error.localizedDescription
    }

    public static func checkSourceAvailability(_ source: SourceRecord, root: URL) -> String {
        do {
            guard source.metadata.storedFilename == URL(fileURLWithPath: source.metadata.storedFilename).lastPathComponent,
                  !source.metadata.storedFilename.hasPrefix(".") else { throw VaultError.invalid("Invalid source path.") }
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let url = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased()).appendingPathComponent(source.metadata.storedFilename)
            let data = try source.metadata.linkedBookmark.map(readLinkedSource) ?? coordinatedRead(url)
            guard source.metadata.isLinked || digest(data) == source.metadata.sha256 else { throw VaultError.invalid("Original checksum does not match.") }
            return "Available"
        } catch { return sourceAvailabilityMessage(error, linked: source.metadata.isLinked) }
    }

    public static func readLinkedSource(_ bookmark: Data) throws -> Data {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale else { throw VaultError.unavailable("Linked source permission is stale. Link the file again.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try coordinatedRead(url)
    }

    public func linkSources(at url: URL, maximumFiles: Int) throws -> [SourceRecord] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VaultError.invalid("Choose files only. Folder linking is no longer supported.") }
        let files = [url]
        // Validate every member before publishing any records.
        let prepared = try files.sorted { $0.path < $1.path }.map { file -> SourceRecord in
            let data = try Self.coordinatedRead(file)
            let body = try Self.sourceText(data, filename: file.lastPathComponent)
            let bookmark = try file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let metadata = SourceMetadata(id: UUID(), title: file.deletingPathExtension().lastPathComponent, capturedAt: timestamp(), originalFilename: file.lastPathComponent, originURL: nil, sha256: digest(data), fileSize: data.count, linkedBookmark: bookmark, storedFilename: "original." + file.pathExtension.lowercased())
            return SourceRecord(metadata: metadata, body: body)
        }
        for source in prepared {
            let pending = root.appendingPathComponent("Sources/.import-" + source.id.uuidString)
            try fm.createDirectory(at: pending, withIntermediateDirectories: true)
            try Self.coordinatedWrite(encoder.encode(source.metadata), to: pending.appendingPathComponent("metadata.json"))
            let final = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased())
            var failure: Error?, coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: pending, options: .forMoving, writingItemAt: final, options: [], error: &coordinationError) { from, to in
                do { try fm.moveItem(at: from, to: to) } catch { failure = error }
            }
            if let failure { throw failure }; if let coordinationError { throw coordinationError }
        }
        return prepared
    }

    public func renameSource(_ source: SourceRecord, title: String, summary: String? = nil) throws -> SourceRecord {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw VaultError.invalid("Invalid source title.") }
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, summary.isEmpty { throw VaultError.invalid("Source summary must not be empty.") }
        let url = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/metadata.json")
        var result: SourceRecord?, failure: Error?, coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do {
                var metadata = try JSONDecoder().decode(SourceMetadata.self, from: Data(contentsOf: target))
                guard metadata.id == source.id, metadata.title == source.title,
                      metadata.sha256 == source.metadata.sha256, metadata.aiSummary == source.metadata.aiSummary,
                      metadata.linkedBookmark == source.metadata.linkedBookmark,
                      metadata.storedFilename == source.metadata.storedFilename else { throw VaultError.invalid("Source changed while its title was generated. Refresh and try again.") }
                metadata.title = title
                if let summary { metadata.aiSummary = summary }
                try encoder.encode(metadata).write(to: target, options: .atomic)
                result = SourceRecord(metadata: metadata, body: source.body)
            } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinationError { throw coordinationError }
        guard let result else { throw VaultError.storage("Source title was not saved.") }
        return result
    }

    public func deleteSource(_ source: SourceRecord) throws {
        let directory = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased())
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw VaultError.invalid("Source directory cannot be a symbolic link.") }
        var failure: Error?, coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: directory, options: .forDeleting, error: &coordinationError) { target in
            do {
                let metadataURL = target.appendingPathComponent("metadata.json")
                guard try metadataURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VaultError.invalid("Invalid source metadata path.") }
                let metadata = try JSONDecoder().decode(SourceMetadata.self, from: Data(contentsOf: metadataURL))
                guard metadata.id == source.id, metadata.title == source.title,
                      metadata.sha256 == source.metadata.sha256, metadata.aiSummary == source.metadata.aiSummary,
                      metadata.linkedBookmark == source.metadata.linkedBookmark,
                      metadata.storedFilename == source.metadata.storedFilename,
                      metadata.storedFilename == URL(fileURLWithPath: metadata.storedFilename).lastPathComponent,
                      !metadata.storedFilename.hasPrefix(".") else { throw VaultError.invalid("Source changed. Refresh before deleting it.") }
                guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: metadataURL) ?? []).isEmpty else { throw VaultError.invalid("Resolve source metadata conflicts before deletion.") }
                if !metadata.isLinked {
                    let original = target.appendingPathComponent(metadata.storedFilename)
                    guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: original) ?? []).isEmpty,
                          digest(try Data(contentsOf: original)) == metadata.sha256 else { throw VaultError.invalid("Imported original changed or has conflicts. Refresh before deleting it.") }
                }
                // Linked originals are outside this directory and are never touched.
                try fm.removeItem(at: target)
            } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinationError { throw coordinationError }
    }

    private func titleExists(_ title: String, in notes: [NoteRecord]) -> Bool {
        let key = normalized(title)
        return notes.contains { normalized($0.title) == key || $0.aliases.contains { normalized($0) == key } }
    }
    private func availablePath(title: String) -> String {
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
    private static func coordinatedWrite(_ data: Data, to url: URL, mustNotExist: Bool = false) throws {
        var failure: Error?, coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                if mustNotExist, FileManager.default.fileExists(atPath: coordinatedURL.path) { throw VaultError.storage("A file appeared at this path. Please try again.") }
                try data.write(to: coordinatedURL, options: .atomic)
            } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinatorError { throw coordinatorError }
    }
}
