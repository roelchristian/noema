import Foundation

/// A disposable Quick Look copy of adapter-validated bytes, never a canonical URL.
/// The reader owns its lifetime and removes it when its window closes.
public struct SourcePreviewSnapshot: Sendable {
    public let url: URL
    private let directory: URL

    public init(data: Data, filename: String) throws {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent, !filename.hasPrefix(".") else {
            throw VaultError.invalid("Invalid preview filename.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noema-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent(filename)
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        self.directory = directory; self.url = url
    }

    public func remove() { try? FileManager.default.removeItem(at: directory) }
}
