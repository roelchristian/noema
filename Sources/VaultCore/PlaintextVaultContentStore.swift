import Foundation

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

    public func read(at path: String) throws -> Data {
        let value = try snapshot(at: path)
        guard case .file(let data) = value else { throw VaultContentStoreError.unsupportedItem(path) }
        return data
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
