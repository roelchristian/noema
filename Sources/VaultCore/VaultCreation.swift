import Foundation

/// Creation intent is transient; it is never an encryption claim in the manifest.
public enum VaultCreation {
    public static let encryptionUnavailable = "Encrypted vault creation is unavailable. Encryption must protect the canonical database, WAL/SHM, temporary data, recovery artifacts, recovery keys, and indexes before it can be enabled."

    public static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VaultError.invalid("Enter a folder name without slashes, colons, or control characters.")
        }
        return trimmed
    }
}

extension FileVaultRepository {
    /// Initializes a positively empty owned root as schema 6, publishing its matching manifest last.
    /// Favourites, collections, and folders are tables in that vault database.
    /// This explicit async path is also used by session creation of an empty selected root.
    static func initializeSchema5(root: URL, storageProvider: VaultStorageProvider) async throws {
        try SQLiteVaultLocality.requireLocalRoot(root)
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw VaultError.invalid("New vault initialization requires an empty folder.")
        }
        let store = try storageProvider.makeStore(root: root)
        // Selecting bytes precedes database creation, so provider failures cannot invent authority.
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw VaultError.invalid("The staging folder changed before initialization.")
        }
        let manifest = VaultManifest()
        let database = try storageProvider.makeAssociationStagingStore(
            url: root.appendingPathComponent(VaultManifest.sqliteDatabasePath), vaultID: manifest.id)
        do {
            try await database.validateIntegrity()
            try await database.checkpoint()
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }
        for directory in ["Sources", trashDirectoryName, "Conflicts"] {
            try store.createDirectory(at: directory)
        }
        try store.synchronize(at: VaultManifest.sqliteDatabasePath)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try store.write(encoder.encode(manifest), at: "vault.json", condition: .createOnly)
        try store.synchronize(at: "vault.json")
    }

    /// Publishes a closed schema-6 vault by a create-only, same-parent move.
    public static func createNewVault(parent: URL, name: String, encryptionRequested: Bool,
                                      storageProvider: VaultStorageProvider = .plaintext) async throws -> URL {
        guard !encryptionRequested else { throw VaultError.invalid(VaultCreation.encryptionUnavailable) }
        let name = try VaultCreation.validatedName(name)
        let parent = parent.standardizedFileURL
        try SQLiteVaultLocality.requireLocalRoot(parent)
        let fm = FileManager.default
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .volumeIsReadOnlyKey])
        guard values.isDirectory == true, values.volumeIsReadOnly != true,
              fm.isWritableFile(atPath: parent.path) else {
            throw VaultError.storage("Choose an existing writable parent folder.")
        }
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else {
            throw VaultError.invalid("A folder with this name already exists. Choose another name or open the existing vault.")
        }
        let staging = parent.appendingPathComponent(".noema-create-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try Task.checkCancellation()
            try await initializeSchema5(root: staging, storageProvider: storageProvider)
            try Task.checkCancellation()
            var coordinationError: NSError?
            var publicationError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: [], error: &coordinationError) { destination in
                do {
                    guard !fm.fileExists(atPath: destination.path) else {
                        throw VaultContentStoreError.alreadyExists(destination.path)
                    }
                    try fm.moveItem(at: staging, to: destination)
                } catch { publicationError = error }
            }
            if let coordinationError { throw coordinationError }
            if let publicationError { throw publicationError }
            return destination
        } catch {
            // Preserve every nonempty or unreadable staging root, including completed vaults.
            if (try? fm.contentsOfDirectory(atPath: staging.path))?.isEmpty == true {
                try? fm.removeItem(at: staging)
                throw error
            }
            throw VaultError.storage("Vault creation failed. Staged content was preserved at \(staging.path). \(error.localizedDescription)")
        }
    }
}
