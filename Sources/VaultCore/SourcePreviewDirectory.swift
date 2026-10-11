import Darwin
import Foundation
import Synchronization

/// Owns disposable plaintext previews outside canonical vault storage.
/// A process lease protects open readers; launch cleanup reaps only proven, unlocked snapshots.
public struct SourcePreviewDirectory: Sendable {
    public static let application = SourcePreviewDirectory(baseDirectory: FileManager.default.temporaryDirectory)
    public static let launchScanLimit = 128
    let root: URL
    private static let marker = ".noema-preview-lease"
    private static let signature = "noema-source-preview-v1\n"

    // Test injection remains internal: runtime callers cannot redirect this exception to a vault.
    init(baseDirectory: URL) {
        root = baseDirectory.appendingPathComponent("noema-source-previews-v1", isDirectory: true)
    }

    func makeSnapshot(data: Data, filename: String) throws -> SourcePreviewSnapshot {
        guard Self.isValidFilename(filename) else { throw VaultError.invalid("Invalid preview filename.") }
        try prepareRoot()
        let directory = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let markerURL = directory.appendingPathComponent(Self.marker)
        let fd = Darwin.open(markerURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let error = Self.posixError()
            _ = Darwin.rmdir(directory.path)
            throw error
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let url = directory.appendingPathComponent(filename)
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Self.posixError() }
            try handle.write(contentsOf: Data((Self.signature + filename).utf8))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return SourcePreviewSnapshot(lease: SourcePreviewLease(url: url, directory: directory,
                                                                  markerURL: markerURL, handle: handle))
        } catch {
            _ = Darwin.unlink(url.path)
            _ = Darwin.unlink(markerURL.path)
            _ = Darwin.rmdir(directory.path)
            try? handle.close()
            throw error
        }
    }

    /// Examines at most `maximumEntries` immediate children and never recursively deletes.
    /// Invalid markers, extra files, symlinks, and leases held by another reader are preserved.
    /// Deletion is ordinary filesystem cleanup, not secure erasure.
    @discardableResult
    public func cleanupOrphans(maximumEntries: Int = launchScanLimit) throws -> Int {
        guard maximumEntries > 0 else { return 0 }
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        try validateRoot()
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                           options: [.skipsSubdirectoryDescendants]) else { return 0 }
        var examined = 0
        var removed = 0
        while examined < maximumEntries, let directory = entries.nextObject() as? URL {
            examined += 1
            let name = directory.lastPathComponent
            guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name,
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let markerURL = directory.appendingPathComponent(Self.marker)
            let fd = Darwin.open(markerURL.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0,
                  Self.isRegularFile(markerURL),
                  let markerBytes = try? handle.read(upToCount: 1024),
                  let marker = String(data: markerBytes, encoding: .utf8),
                  marker.hasPrefix(Self.signature) else { continue }
            let filename = String(marker.dropFirst(Self.signature.count))
            guard Self.isValidFilename(filename) else { continue }
            let url = directory.appendingPathComponent(filename)
            guard let hasPayload = Self.ownedContents(directory, filename: filename),
                  !hasPayload || Self.isRegularFile(url) else { continue }
            // Each unlink is scoped to a marker-validated direct child. rmdir refuses extra contents.
            if hasPayload, Darwin.unlink(url.path) != 0 { continue }
            guard Darwin.unlink(markerURL.path) == 0 else { continue }
            if Darwin.rmdir(directory.path) == 0 { removed += 1 }
        }
        return removed
    }

    private func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            // Another snapshot or process may have created the root first. Accept only an
            // existing-file error, then prove it is a real directory before using it.
            guard (error as? CocoaError)?.code == .fileWriteFileExists else { throw error }
        }
        try validateRoot()
    }

    private func validateRoot() throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VaultError.invalid("Invalid preview directory.")
        }
    }

    private static func isValidFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename != "." && filename != ".." && !filename.hasPrefix(".")
            && !filename.contains("\0") && !filename.contains("\n")
            && filename.utf8.count <= 255 && filename == URL(fileURLWithPath: filename).lastPathComponent
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func ownedContents(_ directory: URL, filename: String) -> Bool? {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                           options: [.skipsSubdirectoryDescendants]) else { return nil }
        var names = Set<String>()
        for _ in 0..<3 {
            guard let url = entries.nextObject() as? URL else {
                if names == [marker, filename] { return true }
                if names == [marker] { return false }
                return nil
            }
            names.insert(url.lastPathComponent)
        }
        return nil
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// The shared reference makes removal idempotent even when a snapshot value is copied.
final class SourcePreviewLease: @unchecked Sendable {
    let url: URL
    private let directory: URL
    private let markerURL: URL
    private let handle: FileHandle
    private let removed = Mutex(false)

    init(url: URL, directory: URL, markerURL: URL, handle: FileHandle) {
        self.url = url; self.directory = directory; self.markerURL = markerURL; self.handle = handle
    }

    func remove() {
        removed.withLock { didRemove in
            guard !didRemove else { return }
            // Retain ownership metadata if payload removal fails, so a later launch can retry.
            if Darwin.unlink(url.path) == 0 || errno == ENOENT {
                _ = Darwin.unlink(markerURL.path)
                _ = Darwin.rmdir(directory.path)
            }
            try? handle.close()
            didRemove = true
        }
    }

    deinit { remove() }
}
