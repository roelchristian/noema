import Foundation

public struct SQLiteVaultMigrationResult: Sendable {
    public let manifest: VaultManifest
    public let importedPageCount: Int
    /// Verified preservation data. Never removed automatically, including on failure.
    public let backupPath: String?
}

/// Explicit conversion for a quiescent local vault. The caller must close its open
/// repository/editor before conversion and reopen only after this operation returns.
/// The manifest is the sole authority selector; Markdown originals are never changed.
public enum SQLiteVaultMigration {
    /// A receipt is written before publication, and retained as preservation data.
    /// It identifies only this migration's exact closed database, never an arbitrary
    /// occupied destination. Recovery moves those bytes back into their owned run.
    private struct PublicationReceipt: Codable {
        let version: Int
        let manifest: Data
        let databaseDigest: String
    }
    public static func convert(
        root: URL,
        storageProvider: VaultStorageProvider = .plaintext,
        sessionLease: VaultSessionLease,
        accessGate: VaultAccessGate
    ) async throws -> SQLiteVaultMigrationResult {
        try await perform(root: root, storageProvider: storageProvider, sessionLease: sessionLease, accessGate: accessGate)
    }

    static func convert(unguardedTestingRoot root: URL, storageProvider: VaultStorageProvider = .plaintext) async throws -> SQLiteVaultMigrationResult {
        try await perform(root: root, storageProvider: storageProvider, sessionLease: nil, accessGate: nil)
    }

    private static func perform(root: URL, storageProvider: VaultStorageProvider, sessionLease: VaultSessionLease?, accessGate: VaultAccessGate?) async throws -> SQLiteVaultMigrationResult {
        try requireLocalRoot(root)
        let root = root.standardizedFileURL
        let rawStore = try storageProvider.makeStore(root: root)
        let store: any VaultContentStore
        if let accessGate {
            store = GatedVaultContentStore(base: rawStore, root: root, vaultID: sessionLease?.vaultID,
                gate: accessGate, lease: sessionLease)
        } else { store = rawStore }
        let manifestBytes = try store.read(at: "vault.json")
        var manifest = try FileVaultRepository.inspectManifest(at: root, contentStore: store)
        if let accessGate {
            try accessGate.validate(lease: sessionLease, targetRoot: root, targetVaultID: manifest.id, operation: "vaultMigration.identity")
        }
        guard manifest.isSupported else { throw VaultError.invalid("This vault uses an unsupported format version.") }
        if manifest.storageMode == .sqliteBlocks {
            try requirePublishedDatabase(root: root)
            let database = try storageProvider.makeBlockStore(url: root.appendingPathComponent(VaultManifest.sqliteDatabasePath), sessionLease: sessionLease, accessGate: accessGate, createIfMissing: false, manifest: manifest)
            let count = try await database.allPages().count
            try await database.close()
            return SQLiteVaultMigrationResult(manifest: manifest, importedPageCount: count, backupPath: nil)
        }
        try recoverInterruptedPublication(root: root, store: store, manifestBytes: manifestBytes)
        // Capture all canonical files, including source originals, metadata and trash.
        // Enumerating names does not read canonical bytes; reads go through the adapter.
        let paths = try inventory(root)
        var originals: [String: Data] = [:]
        var pages: [(NoteRecord, BlockDocument)] = []
        var ids: Set<UUID> = []
        for path in paths {
            let bytes = try store.read(at: path)
            originals[path] = bytes
            if path.hasPrefix("Wiki/"), path.lowercased().hasSuffix(".md") {
                let note = try NoteCodec.decode(bytes, path: path, vaultID: manifest.id)
                try rejectFutureEnvelopes(note.body, path: path)
                let document = BlockDocumentCodec.decode(note.body)
                guard !document.unsupportedVersion, BlockDocumentCodec.valid(document) else {
                    throw VaultError.invalid("Cannot migrate unsupported block metadata in \(path).")
                }
                guard ids.insert(note.id).inserted else {
                    throw VaultError.invalid("Duplicate page identity in \(path).")
                }
                pages.append((note, document))
            }
        }
        guard originals["vault.json"] == manifestBytes else { throw VaultContentStoreError.stale("vault.json") }
        let run = ".noema-migrations/\(UUID().uuidString.lowercased())"
        let backup = "\(run)/backup"
        try ensureDirectory(".noema-migrations", root: root, store: store)
        try store.createDirectory(at: run)
        try store.createDirectory(at: backup)
        for path in paths {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty { try ensureDirectory("\(backup)/\(parent)", root: root, store: store) }
            try store.write(originals[path]!, at: "\(backup)/\(path)", condition: .createOnly)
            guard try store.read(at: "\(backup)/\(path)") == originals[path] else {
                throw VaultError.invalid("Pre-migration backup verification failed for \(path).")
            }
        }
        let stagingPath = "\(run)/blocks.sqlite"
        let database = try storageProvider.makeBlockStore(url: root.appendingPathComponent(stagingPath), sessionLease: sessionLease, accessGate: accessGate)
        do {
            for (record, document) in pages {
                _ = try await database.savePage(record: record, document: document, condition: .createOnly)
            }
            guard try await database.allPages().count == pages.count else {
                throw VaultError.invalid("SQLite import count verification failed.")
            }
            for (record, document) in pages {
                let imported = try await database.loadPage(pageID: record.id)
                var expected = record
                expected.body = imported.record.body; expected.contentHash = imported.record.contentHash
                guard imported.record == expected, imported.snapshot.document == document else {
                    throw VaultError.invalid("SQLite import verification failed for \(record.relativePath).")
                }
            }
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }
        // Refuse to cut over when any original, manifest or inventory changed.
        guard try inventory(root) == paths else { throw VaultContentStoreError.stale("vault inventory") }
        for path in paths {
            guard try store.read(at: path) == originals[path] else { throw VaultContentStoreError.stale(path) }
        }
        let staged = try store.snapshot(at: stagingPath)
        guard case .file(let databaseBytes) = staged else {
            throw VaultContentStoreError.unsupportedItem(stagingPath)
        }
        let receipt = PublicationReceipt(version: 1, manifest: manifestBytes, databaseDigest: digest(databaseBytes))
        try store.write(try JSONEncoder().encode(receipt), at: "\(run)/publication.json", condition: .createOnly)
        try store.move(from: stagingPath, to: VaultManifest.sqliteDatabasePath, expected: staged)
        // Publication can be delayed or injected providers can observe external
        // edits during the move. Recheck immediately before selecting authority.
        guard try inventory(root, ignoringPublishedDatabase: true) == paths else { throw VaultContentStoreError.stale("vault inventory") }
        for path in paths {
            guard try store.read(at: path) == originals[path] else { throw VaultContentStoreError.stale(path) }
        }
        guard try store.snapshot(at: VaultManifest.sqliteDatabasePath) == staged else {
            throw VaultContentStoreError.stale(VaultManifest.sqliteDatabasePath)
        }
        // Preserve unknown manifest properties as well as the vault UUID.
        guard var envelope = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any] else {
            throw VaultError.invalid("Invalid vault manifest.")
        }
        envelope["formatVersion"] = 2
        envelope["storageMode"] = BlockStorageMode.sqliteBlocks.rawValue
        let publishedManifest = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .prettyPrinted])
        try store.write(publishedManifest, at: "vault.json", condition: .replace(expected: manifestBytes))
        manifest.formatVersion = 2; manifest.storageMode = .sqliteBlocks
        return SQLiteVaultMigrationResult(manifest: manifest, importedPageCount: pages.count, backupPath: backup)
    }

    private static func rejectFutureEnvelopes(_ source: String, path: String) throws {
        let prefix = "<!--noema:document:"
        for line in source.components(separatedBy: .newlines) where line.hasPrefix(prefix) && line.hasSuffix("-->") {
            let payload = String(line.dropFirst(prefix.count).dropLast(3))
            if let bytes = Data(base64Encoded: payload),
               let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let version = envelope["version"] as? Int, version != 1 {
                throw VaultError.invalid("Cannot migrate unsupported block metadata in \(path).")
            }
        }
    }

    private static func ensureDirectory(_ path: String, root: URL, store: any VaultContentStore) throws {
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(current).path) {
                try store.createDirectory(at: current)
            }
        }
    }

    static func requireLocalRoot(_ root: URL) throws {
        guard root.isFileURL, root.standardizedFileURL == root.standardizedFileURL.resolvingSymlinksInPath() else {
            throw VaultContentStoreError.unsafePath(root.path)
        }
        var ancestor = root.standardizedFileURL
        while true {
            let values = try ancestor.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
            let name = ancestor.lastPathComponent.lowercased()
            let knownCloudRoot = ["cloudstorage", "mobile documents", "icloud drive", "dropbox", "onedrive", "google drive", "googledrive", "box"].contains {
                name == $0 || name.hasPrefix($0 + " ") || name.hasPrefix($0 + "-")
            }
            guard values.isUbiquitousItem != true, values.volumeIsLocal == true, !knownCloudRoot else {
                throw VaultError.invalid("SQLite conversion requires a local vault outside cloud-backed folders.")
            }
            if ancestor.path == "/" { break }
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
    }

    private static func requirePublishedDatabase(root: URL) throws {
        let database = root.appendingPathComponent(VaultManifest.sqliteDatabasePath)
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw VaultContentStoreError.missing(VaultManifest.sqliteDatabasePath)
        }
        let values = try database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isUbiquitousItem != true else {
            throw VaultContentStoreError.unsafePath(VaultManifest.sqliteDatabasePath)
        }
    }

    private static func recoverInterruptedPublication(root: URL, store: any VaultContentStore, manifestBytes: Data) throws {
        let databasePath = VaultManifest.sqliteDatabasePath
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(databasePath).path) else { return }
        try requirePublishedDatabase(root: root)
        let snapshot = try store.snapshot(at: databasePath)
        guard case .file(let bytes) = snapshot else { throw VaultContentStoreError.unsupportedItem(databasePath) }
        let migrations = root.appendingPathComponent(".noema-migrations")
        guard FileManager.default.fileExists(atPath: migrations.path) else { throw VaultContentStoreError.alreadyExists(databasePath) }
        let migrationValues = try migrations.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard migrationValues.isDirectory == true, migrationValues.isSymbolicLink != true else {
            throw VaultContentStoreError.unsafePath(".noema-migrations")
        }
        for run in try FileManager.default.contentsOfDirectory(at: migrations, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard UUID(uuidString: run.lastPathComponent) != nil else { continue }
            let values = try run.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let relativeRun = ".noema-migrations/\(run.lastPathComponent)"
            let receiptPath = "\(relativeRun)/publication.json"
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(receiptPath).path) else { continue }
            let receipt = try JSONDecoder().decode(PublicationReceipt.self, from: store.read(at: receiptPath))
            guard receipt.version == 1, receipt.manifest == manifestBytes, receipt.databaseDigest == digest(bytes) else { continue }
            // Never overwrite or delete preservation data, even after repeated failures.
            let preservedPath = "\(relativeRun)/interrupted-\(UUID().uuidString.lowercased()).sqlite"
            try store.move(from: databasePath, to: preservedPath, expected: snapshot)
            return
        }
        throw VaultContentStoreError.alreadyExists(databasePath)
    }

    private static func inventory(_ root: URL, ignoringPublishedDatabase: Bool = false) throws -> [String] {
        var paths: [String] = []
        func visit(_ directory: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
            for child in children {
                if prefix.isEmpty && child.lastPathComponent == ".noema-migrations" { continue }
                if prefix.isEmpty && child.lastPathComponent == VaultManifest.sqliteDatabasePath {
                    if ignoringPublishedDatabase { continue }
                    throw VaultContentStoreError.alreadyExists(VaultManifest.sqliteDatabasePath)
                }
                let path = prefix + child.lastPathComponent
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
                guard values.isSymbolicLink != true, values.isUbiquitousItem != true else {
                    throw VaultContentStoreError.unsafePath(path)
                }
                if values.isDirectory == true { try visit(child, prefix: path + "/") }
                else if values.isRegularFile == true { paths.append(path) }
                else { throw VaultContentStoreError.unsupportedItem(path) }
            }
        }
        try visit(root, prefix: "")
        return paths.sorted()
    }
}
