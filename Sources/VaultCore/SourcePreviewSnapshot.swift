import Foundation

/// A disposable Quick Look copy of adapter-validated bytes, never a canonical URL.
/// The reader owns its lifetime; the process lease permits bounded orphan cleanup after a crash.
public struct SourcePreviewSnapshot: Sendable {
    public let url: URL
    private let lease: SourcePreviewLease

    public init(data: Data, filename: String) throws {
        self = try SourcePreviewDirectory.application.makeSnapshot(data: data, filename: filename)
    }

    init(lease: SourcePreviewLease) {
        self.lease = lease
        url = lease.url
    }

    public func remove() { lease.remove() }
}
