import Foundation

/// Creation intent is transient; it is never an encryption claim in the manifest.
public enum VaultCreation {
    public static let encryptionUnavailable = "Encrypted vault creation is unavailable. Encryption, recovery-key setup, and protected indexing must be implemented and tested before it can be enabled."

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
    /// Publishes a complete plaintext vault by a same-parent move, never merging an existing folder.
    public static func createNewVault(parent: URL, name: String, encryptionRequested: Bool, storageProvider: VaultStorageProvider = .plaintext) throws -> URL {
        guard !encryptionRequested else { throw VaultError.invalid(VaultCreation.encryptionUnavailable) }
        let name = try VaultCreation.validatedName(name)
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .volumeIsReadOnlyKey])
        guard values.isDirectory == true, values.volumeIsReadOnly != true,
              fm.isWritableFile(atPath: parent.path) else {
            throw VaultError.storage("Choose an existing writable parent folder.")
        }
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(VaultError.storage("Could not coordinate vault creation."))
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: [], error: &coordinationError) { destination in
            result = Result {
                guard !fm.fileExists(atPath: destination.path) else {
                    throw VaultError.invalid("A folder with this name already exists. Choose another name or open the existing vault.")
                }
                let staging = parent.appendingPathComponent(".noema-create-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                do {
                    _ = try FileVaultRepository.open(root: staging, create: true, storageProvider: storageProvider)
                    // moveItem refuses an occupied destination, including one created after the check.
                    try fm.moveItem(at: staging, to: destination)
                } catch {
                    // Ownership of a temporary root does not make its contents disposable.
                    // Remove only a positively observed empty staging root; preserve partial
                    // canonical writes and completed vaults when initialization/publication fails.
                    if (try? fm.contentsOfDirectory(atPath: staging.path))?.isEmpty == true {
                        try? fm.removeItem(at: staging)
                        throw error
                    }
                    throw VaultError.storage("Vault creation failed. Staged content was preserved at \(staging.path). \(error.localizedDescription)")
                }
                return destination
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
