import Foundation

/// One content authority selected for a vault. This declaration does not enable a
/// new on-disk format; production currently supports Markdown format 1 only.
public enum BlockStorageMode: String, Codable, Sendable {
    case markdown
    case sqliteBlocks
}

/// Opaque store-issued concurrency evidence, scoped to the vault, page and mode.
/// Callers must not derive revisions from exported Markdown or editor timestamps.
public struct BlockStoreRevision: Equatable, Sendable {
    public let token: Data
    public init(token: Data) { self.token = token }
}

public struct BlockStoreSnapshot: Equatable, Sendable {
    public let pageID: UUID
    public let document: BlockDocument
    public let revision: BlockStoreRevision
    public init(pageID: UUID, document: BlockDocument, revision: BlockStoreRevision) {
        self.pageID = pageID; self.document = document; self.revision = revision
    }
}

public enum BlockStoreWriteCondition: Equatable, Sendable {
    case createOnly
    case replace(expected: BlockStoreRevision)
}

/// Domain persistence seam, independent of AppKit, selection, undo and export.
/// Future adapters are selected once per vault by storage construction policy.
/// Each operation revalidates its captured vault lease when access executes;
/// replacing/deleting requires a matching revision in the same commit window.
/// Save preserves page metadata and any opaque fields not understood by this
/// client, and rejects unsupported document versions rather than rewriting them.
/// Invalid/no-op editor commands never reach this seam. No multi-call transaction
/// is implied; repository-level compound changes require adapter-owned atomicity.
/// There is deliberately no runtime implementation or editor routing change yet.
public protocol BlockStore: Sendable {
    var mode: BlockStorageMode { get }
    func load(pageID: UUID) throws -> BlockStoreSnapshot
    @discardableResult
    func save(_ document: BlockDocument, pageID: UUID,
              condition: BlockStoreWriteCondition) throws -> BlockStoreSnapshot
    func delete(pageID: UUID, expected: BlockStoreRevision) throws
}
