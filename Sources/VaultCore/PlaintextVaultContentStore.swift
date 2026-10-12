import Foundation
import Darwin
import CryptoKit

/// Filesystem adapter; it neither encodes content nor owns repository conflict-copy policy.
/// Root access is scoped for each operation (the app may also retain a longer-lived scope).
/// A false startAccessing result is normal for ordinary accessible, non-bookmarked URLs.
/// Coordination protects cooperating presenters; it is not a lock against arbitrary POSIX writers.
public struct PlaintextVaultContentStore: VaultContentStore {
    public let root: URL
    private let accessRoot: URL

    public init(root: URL) throws {
        guard root.isFileURL else { throw VaultContentStoreError.unsafePath(root.absoluteString) }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        // Match repository open: the selected root itself may resolve through a symlink.
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.accessRoot = root
        guard try self.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw VaultContentStoreError.unsupportedItem(root.path)
        }
    }

    public func createDirectory(at path: String) throws {
        try withScope {
            let url = try checked(path)
            let _: Bool = try coordinated { coordinator, error, access in
                coordinator.coordinate(writingItemAt: url, options: [], error: error) { url in
                    access {
                        let url = try self.checked(url)
                        guard !FileManager.default.fileExists(atPath: url.path) else { throw VaultContentStoreError.alreadyExists(path) }
                        try self.rejectConflicts(url)
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                        return true
                    }
                }
            }
        }
    }

    /// Local filesystem durability: F_FULLFSYNC for regular payloads, fsync for
    /// directory entries. Unsupported filesystems fail closed; this is not proof
    /// of arbitrary device power-loss behavior or cloud delivery.
    func synchronizePublicationRoot() throws {
        try withScope {
            let fd = open(root.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw VaultError.storage("Cannot open publication root.") }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw VaultError.storage("Publication root fsync failed.") }
        }
    }
    public func synchronize(at path: String) throws {
        try withScope {
            let url = try checked(path)
            let _: Bool = try coordinated { coordinator, error, access in
                coordinator.coordinate(writingItemAt: url, options: [], error: error) { url in
                    access {
                        let url = try self.checked(url)
                        try self.rejectConflicts(url)
                        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
                        guard fd >= 0 else { throw VaultError.storage("Cannot open publication for synchronization: \(errno)") }
                        defer { close(fd) }
                        var info = stat()
                        guard fstat(fd, &info) == 0 else { throw VaultError.storage("Cannot inspect publication descriptor.") }
                        let kind = info.st_mode & S_IFMT
                        guard kind == S_IFREG || kind == S_IFDIR else { throw VaultContentStoreError.unsupportedItem(path) }
                        guard fsync(fd) == 0 else { throw VaultError.storage("Publication fsync failed: \(errno)") }
                        if kind == S_IFREG {
                            guard fcntl(fd, F_FULLFSYNC) == 0 else { throw VaultError.storage("Publication full sync unsupported or failed: \(errno)") }
                        }
                        return true
                    }
                }
            }
        }
    }

    public func read(at path: String) throws -> Data {
        let value = try snapshot(at: path)
        guard case .file(let data) = value else { throw VaultContentStoreError.unsupportedItem(path) }
        return data
    }

    public func changeToken(at path: String) throws -> VaultContentChangeToken? {
        try withScope {
            let url = try checked(path)
            return try coordinated { coordinator, error, access in
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: error) { url in
                    access {
                        let url = try self.checked(url)
                        try self.rejectConflicts(url)
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey])
                        guard values.ubiquitousItemDownloadingStatus != .notDownloaded else {
                            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                            throw VaultContentStoreError.unavailable(path)
                        }
                        guard values.isRegularFile == true else { throw VaultContentStoreError.unsupportedItem(path) }
                        guard FileManager.default.isReadableFile(atPath: url.path) else {
                            throw VaultContentStoreError.io(domain: NSPOSIXErrorDomain, code: Int(EACCES), message: "Source original is not readable.")
                        }
                        var info = stat()
                        guard lstat(url.path, &info) == 0 else { return nil }
                        guard info.st_mode & S_IFMT == S_IFREG else { throw VaultContentStoreError.unsupportedItem(path) }
                        return VaultContentChangeToken(
                            device: info.st_dev, inode: info.st_ino, size: info.st_size,
                            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
                        )
                    }
                }
            }
        }
    }

    public func snapshot(at path: String) throws -> VaultContentSnapshot {
        try withScope {
            let url = try checked(path)
            return try coordinated { coordinator, error, access in
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: error) { url in
                    access { try self.capture(self.checked(url)) }
                }
            }
        }
    }

    public func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        try withScope {
            let url = try checked(path)
            let _: Bool = try coordinated { coordinator, error, access in
                coordinator.coordinate(writingItemAt: url, options: [], error: error) { url in
                    access {
                        let url = try self.checked(url)
                        switch condition {
                        case .createOnly:
                            guard !FileManager.default.fileExists(atPath: url.path) else {
                                throw VaultContentStoreError.alreadyExists(path)
                            }
                        case .replace(let expected):
                            try self.verify(url, expected: .file(expected))
                        }
                        try self.rejectConflicts(url)
                        try data.write(to: url, options: .atomic)
                        return true
                    }
                }
            }
        }
    }

    public func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        try withScope {
            let from = try checked(source), to = try checked(destination)
            let _: Bool = try coordinated { coordinator, error, access in
                coordinator.coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: [], error: error) { from, to in
                    access {
                        let from = try self.checked(from), to = try self.checked(to)
                        try self.verify(from, expected: expected)
                        guard !FileManager.default.fileExists(atPath: to.path) else {
                            throw VaultContentStoreError.alreadyExists(destination)
                        }
                        try self.rejectConflicts(to)
                        try FileManager.default.moveItem(at: from, to: to)
                        coordinator.item(at: from, didMoveTo: to)
                        return true
                    }
                }
            }
        }
    }

    public func delete(at path: String, expected: VaultContentSnapshot) throws {
        try withScope {
            let url = try checked(path)
            let _: Bool = try coordinated { coordinator, error, access in
                coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: error) { url in
                    access {
                        let url = try self.checked(url)
                        try self.verify(url, expected: expected)
                        try FileManager.default.removeItem(at: url)
                        return true
                    }
                }
            }
        }
    }

    private func checked(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\0") else { throw VaultContentStoreError.unsafePath(path) }
        return try checked(root.appendingPathComponent(path))
    }

    private func checked(_ url: URL) throws -> URL {
        let url = url.standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix(root.path + "/"),
              root.resolvingSymlinksInPath() == root,
              url.resolvingSymlinksInPath() == url else {
            throw VaultContentStoreError.unsafePath(url.path)
        }
        // Foundation may leave a missing leaf unresolved even when its parent is
        // a symlink. Inspect every component, including dangling symlinks.
        var ancestor = root
        for component in url.pathComponents.dropFirst(root.pathComponents.count) {
            ancestor.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                throw VaultContentStoreError.unsafePath(url.path)
            }
        }
        return url
    }

    private func rejectConflicts(_ url: URL) throws {
        guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty else {
            throw VaultContentStoreError.cloudConflict(url.path)
        }
    }

    private func capture(_ url: URL) throws -> VaultContentSnapshot {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .ubiquitousItemDownloadingStatusKey])
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw VaultContentStoreError.unavailable(url.path)
        }
        if values.isRegularFile == true { return .file(try Data(contentsOf: url)) }
        guard values.isDirectory == true else { throw VaultContentStoreError.unsupportedItem(url.path) }
        try rejectConflicts(url)
        var files: [String: Data] = [:]
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            let child = try checked(child)
            try rejectConflicts(child)
            guard try child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw VaultContentStoreError.unsupportedItem(child.path)
            }
            guard case .file(let data) = try capture(child) else { throw VaultContentStoreError.unsupportedItem(child.path) }
            files[child.lastPathComponent] = data
        }
        return .directory(files)
    }

    private func verify(_ url: URL, expected: VaultContentSnapshot) throws {
        try rejectConflicts(url)
        if case .directory = expected {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try rejectConflicts(try checked(child))
            }
        }
        guard try capture(url) == expected else { throw VaultContentStoreError.stale(url.path) }
    }

    private func withScope<T>(_ operation: () throws -> T) throws -> T {
        let scoped = accessRoot.startAccessingSecurityScopedResource()
        defer { if scoped { accessRoot.stopAccessingSecurityScopedResource() } }
        do { return try operation() }
        catch let error as VaultContentStoreError { throw error }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                throw VaultContentStoreError.missing(error.userInfo[NSFilePathErrorKey] as? String ?? root.path)
            }
            throw VaultContentStoreError.io(domain: error.domain, code: error.code, message: error.localizedDescription)
        }
    }

    /// Coordinator and callback state never cross actor/task boundaries.
    private func coordinated<T>(_ operation: (NSFileCoordinator, AutoreleasingUnsafeMutablePointer<NSError?>, (() throws -> T) -> Void) -> Void) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?, result: Result<T, Error>?
        operation(coordinator, &coordinationError) { work in result = Result { try work() } }
        if let result { return try result.get() }
        if let error = coordinationError {
            throw VaultContentStoreError.coordination(domain: error.domain, code: error.code, message: error.localizedDescription)
        }
        throw VaultContentStoreError.coordination(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, message: "File coordination did not grant access.")
    }
}


/// Evidence can only be minted by the byte adapter after actual scoped/durable I/O.
/// The closure rechecks retained evidence and the original at SQL execution/COMMIT.
public struct CanonicalSourceByteReceipt: Sendable {
    public let sourceID: UUID
    public let vaultID: UUID
    public let operationID: UUID
    public let original: CanonicalSourceOriginal
    private let check: @Sendable () throws -> Void
    fileprivate init(sourceID: UUID, vaultID: UUID, operationID: UUID,
                     original: CanonicalSourceOriginal, check: @escaping @Sendable () throws -> Void) {
        self.sourceID = sourceID; self.vaultID = vaultID; self.operationID = operationID
        self.original = original; self.check = check
    }
    public func validating(_ validation: @escaping @Sendable () throws -> Void) -> CanonicalSourceByteReceipt {
        .init(sourceID: sourceID, vaultID: vaultID, operationID: operationID, original: original) {
            try validation(); try self.check(); try validation()
        }
    }
    func validate(source: CanonicalSource, vaultID: UUID, operationID: UUID) throws {
        guard self.sourceID == source.id, self.vaultID == vaultID,
              self.operationID == operationID, source.original == original else {
            throw VaultError.invalid("Source byte receipt identity/descriptor mismatch.")
        }
        try check()
    }
}

public extension PlaintextVaultContentStore {
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        guard !metadata.isLinked else { throw VaultError.invalid("Linked originals are externally owned.") }
        try validateOriginal(data, metadata: metadata)
        let sourceDirectory = "Sources/" + metadata.id.uuidString.lowercased()
        try ensurePublicationDirectory("Sources")
        try createDirectory(at: sourceDirectory)
        try synchronize(at: "Sources")
        let path = sourceDirectory + "/" + metadata.storedFilename
        // The occupied identity/path is never overwritten, including after failure.
        try write(data, at: path, condition: .createOnly)
        return try verifyCanonicalOriginal(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }

    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        guard !metadata.isLinked else { throw VaultError.invalid("Imported original required.") }
        let source = try CanonicalSource(metadata: metadata)
        guard let original = source.original, let path = original.blobPath else { throw VaultError.invalid("Original descriptor missing.") }
        try validateOriginal(read(at: path), metadata: metadata)
        try synchronize(at: path)
        try synchronize(at: "Sources/" + metadata.id.uuidString.lowercased())
        try synchronize(at: "Sources")
        return try retainedReceipt(source: source, vaultID: vaultID, operationID: operationID) {
            try self.validateOriginal(self.read(at: path), metadata: metadata)
        }
    }

    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        guard let bookmark = metadata.linkedBookmark, !bookmark.isEmpty else { throw VaultError.invalid("Linked original bookmark required.") }
        let source = try CanonicalSource(metadata: metadata)
        // Read through the existing scoped, coordinated, read-only external adapter.
        try validateOriginal(FileVaultRepository.readLinkedSource(bookmark), metadata: metadata)
        return try retainedReceipt(source: source, vaultID: vaultID, operationID: operationID) {
            try self.validateOriginal(FileVaultRepository.readLinkedSource(bookmark), metadata: metadata)
        }
    }

    private func validateOriginal(_ data: Data, metadata: SourceMetadata) throws {
        guard !metadata.storedFilename.isEmpty, metadata.storedFilename != ".", metadata.storedFilename != "..",
              !metadata.storedFilename.contains("/"), !metadata.storedFilename.hasPrefix("."),
              metadata.fileSize == data.count,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else {
            throw VaultError.invalid("Original identity, checksum or byte size failed verification.")
        }
    }

    private func ensurePublicationDirectory(_ path: String) throws {
        do { try createDirectory(at: path) }
        catch VaultContentStoreError.alreadyExists {
            let directory = try checked(path)
            try rejectConflicts(directory)
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw VaultContentStoreError.unsupportedItem(path) }
        }
    }

    private func retainedReceipt(source: CanonicalSource, vaultID: UUID, operationID: UUID,
                                 verify: @escaping @Sendable () throws -> Void) throws -> CanonicalSourceByteReceipt {
        guard let original = source.original else { throw VaultError.invalid("Missing source original.") }
        try ensurePublicationDirectory("Source Publications")
        let path = "Source Publications/" + operationID.uuidString.lowercased() + ".json"
        var object: [String: Any] = ["version": 1, "sourceID": source.id.uuidString, "vaultID": vaultID.uuidString,
                                   "operationID": operationID.uuidString, "ownership": source.ownership.rawValue,
                                   "checksum": original.checksum, "size": original.size]
        object["blobPath"] = original.blobPath
        object["linkedBookmark"] = original.linkedBookmark?.base64EncodedString()
        let evidence = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try write(evidence, at: path, condition: .createOnly)
        try synchronize(at: path)
        try synchronize(at: "Source Publications")
        // Flush the root entry created for this recoverable evidence directory.
        try synchronizePublicationRoot()
        try verify()
        return .init(sourceID: source.id, vaultID: vaultID, operationID: operationID, original: original) {
            guard try self.read(at: path) == evidence else { throw VaultError.invalid("Source publication evidence changed.") }
            try verify()
        }
    }
}
