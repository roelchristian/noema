import Foundation

/// A directory package of committed schema-5 data. Unsaved application-local
/// RecoveryStore drafts and externally owned linked originals are excluded.
public enum NativeVaultArchive {
    public static let indexPath = "noema-archive.json"
    public struct Index: Codable, Sendable {
        public let version: Int
        public let vaultID: UUID
        public let capturedAt: Date
        public let recoveryDraftsIncluded: Bool
        public let externalSourceIDs: [UUID]
        public let files: [String: Entry]
    }
    public struct Entry: Codable, Sendable {
        public let size: Int
        public let sha256: String
    }

    /// Explicit restore requires destination-bound admitted authority. The lease
    /// must be authorized for the archived UUID; authentication remains upstream.
    public static func restore(from archive: URL, parent: URL, name: String,
                               sessionLease: VaultSessionLease, accessGate: VaultAccessGate,
                               storageProvider: VaultStorageProvider = .plaintext) async throws -> URL {
        try SQLiteVaultLocality.requireLocalRoot(parent)
        let name = try VaultCreation.validatedName(name)
        let destination = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        try accessGate.validate(lease: sessionLease, targetRoot: destination, targetVaultID: sessionLease.vaultID, operation: "archive.restore")
        let input = try storageProvider.makeStore(root: archive)
        let index = try JSONDecoder().decode(Index.self, from: input.read(at: indexPath))
        guard index.version == 1, index.vaultID == sessionLease.vaultID,
              !index.recoveryDraftsIncluded, index.files["vault.json"] != nil,
              index.files[VaultManifest.sqliteDatabasePath] != nil else {
            throw VaultError.invalid("Unsupported or incomplete native archive.")
        }
        let parentStore = try storageProvider.makeStore(root: parent)
        let stagingName = ".noema-restore-" + UUID().uuidString
        try parentStore.createDirectory(at: stagingName)
        let staging = parent.appendingPathComponent(stagingName, isDirectory: true)
        let output = try storageProvider.makeStore(root: staging)
        for directory in ["Sources", "Conflicts", FileVaultRepository.trashDirectoryName] { try output.createDirectory(at: directory) }
        // Nonempty failure staging is preservation evidence, never auto-deleted.
        for path in index.files.keys.sorted() {
            try checkedPath(path)
            let bytes = try input.read(at: path)
            guard let expected = index.files[path], bytes.count == expected.size, digest(bytes) == expected.sha256 else {
                throw VaultError.invalid("Archive checksum mismatch: \(path)")
            }
            try directories(for: path, store: output)
            try output.write(bytes, at: path, condition: .createOnly)
        }
        let manifest = try FileVaultRepository.inspectManifest(at: staging, storageProvider: storageProvider)
        guard manifest.id == index.vaultID, manifest.canonicalStorage else { throw VaultError.invalid("Archive vault identity mismatch.") }
        let db = try storageProvider.makeSemanticStagingStore(url: staging.appendingPathComponent(VaultManifest.sqliteDatabasePath), vaultID: index.vaultID, createIfMissing: false)
        do {
            try await validate(db: db, store: output)
            try await db.checkpoint()
            try await db.close()
        } catch { try? await db.close(); throw error }
        try accessGate.validate(lease: sessionLease, targetRoot: destination, targetVaultID: index.vaultID, operation: "archive.restore.publish")
        // This root publication is create-only; occupied and dangling-symlink
        // destinations cannot be merged or overwritten by moveItem.
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    static func checkedPath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\\"), path != indexPath,
              path != "blocks.sqlite-wal", path != "blocks.sqlite-shm" else {
            throw VaultError.invalid("Unsafe archive path: \(path)")
        }
    }
    static func directories(for path: String, store: any VaultContentStore) throws {
        let components = path.split(separator: "/").dropLast()
        var current = ""
        for component in components {
            current = current.isEmpty ? String(component) : current + "/" + component
            do { try store.createDirectory(at: current) }
            catch VaultContentStoreError.alreadyExists { }
        }
    }
    static func inventory(root: URL, store: any VaultContentStore) throws -> [String: Data] {
        var files: [String: Data] = [:]
        func visit(_ directory: URL, prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                let path = prefix + child.lastPathComponent
                if [VaultManifest.sqliteDatabasePath, "blocks.sqlite-wal", "blocks.sqlite-shm"].contains(path) { continue }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw VaultError.invalid("Archive rejects symlinks: \(path)") }
                if values.isDirectory == true { try visit(child, prefix: path + "/") }
                else {
                    guard values.isRegularFile == true else { throw VaultError.invalid("Unsupported archive item: \(path)") }
                    try checkedPath(path)
                    files[path] = try store.read(at: path)
                }
            }
        }
        try visit(root, prefix: "")
        return files
    }
    static func validate(db: SQLiteBlockStore, store: any VaultContentStore) async throws {
        try await db.validateIntegrity()
        _ = try await db.allPages()
        _ = try await db.allTrashedPages()
        for snapshot in try await db.sourceSnapshots(includeTrashed: true) where snapshot.source.ownership == .imported {
            guard let original = snapshot.source.original, let path = original.blobPath else { throw VaultError.invalid("Missing archived source descriptor.") }
            let bytes = try store.read(at: path)
            guard bytes.count == original.size, digest(bytes) == original.checksum else { throw VaultError.invalid("Archived original does not match its source reference.") }
        }
    }
}

extension FileVaultRepository {
    /// Captures a SQLite backup and every controlled original/preservation file.
    /// Failure never publishes the index that identifies a valid archive.
    public func archive(to destination: URL, storageProvider: VaultStorageProvider = .plaintext) async throws -> NativeVaultArchive.Index {
        try validateAccess(operation: "archive.capture")
        let parent = destination.deletingLastPathComponent()
        try SQLiteVaultLocality.requireLocalRoot(parent)
        let parentStore = try storageProvider.makeStore(root: parent)
        guard !destination.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw VaultError.invalid("Archive must be outside the vault.") }
        let before = try NativeVaultArchive.inventory(root: root, store: contentStore)
        try parentStore.createDirectory(at: destination.lastPathComponent)
        let output = try storageProvider.makeStore(root: destination)
        try await sqliteBlockStore.backup(to: destination.appendingPathComponent(VaultManifest.sqliteDatabasePath))
        for (path, bytes) in before {
            try NativeVaultArchive.directories(for: path, store: output)
            try output.write(bytes, at: path, condition: .createOnly)
        }
        let db = try storageProvider.makeSemanticStagingStore(url: destination.appendingPathComponent(VaultManifest.sqliteDatabasePath), vaultID: manifest.id, createIfMissing: false)
        let externalIDs: [UUID]
        do {
            try await NativeVaultArchive.validate(db: db, store: output)
            externalIDs = try await db.sourceSnapshots(includeTrashed: true).filter { $0.source.ownership == .linked }.map { $0.source.id }
            try await db.checkpoint()
            try await db.close()
        } catch { try? await db.close(); throw error }
        guard try NativeVaultArchive.inventory(root: root, store: contentStore) == before else { throw VaultError.conflict("Vault files changed during archival. Retry after writes finish.") }
        try validateAccess(operation: "archive.publish")
        var files = before
        files[VaultManifest.sqliteDatabasePath] = try output.read(at: VaultManifest.sqliteDatabasePath)
        let index = NativeVaultArchive.Index(version: 1, vaultID: manifest.id, capturedAt: Date(), recoveryDraftsIncluded: false, externalSourceIDs: externalIDs, files: files.mapValues { .init(size: $0.count, sha256: digest($0)) })
        try output.write(JSONEncoder().encode(index), at: NativeVaultArchive.indexPath, condition: .createOnly)
        return index
    }
}
