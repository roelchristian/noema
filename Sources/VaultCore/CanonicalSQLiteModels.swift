import Foundation

/// Canonical source identity does not confer ownership of original bytes.
public enum CanonicalSourceOwnership: String, Codable, Sendable { case imported, linked, unavailable }

/// Versioned source metadata excludes identity, revision, relationships and lifecycle.
/// Opaque JSON values are retained; publication of owned/linked originals remains
/// closed until a durable byte/scoped-access receipt is available.
public struct CanonicalSource: Equatable, Sendable {
    public var id: UUID
    public var ownership: CanonicalSourceOwnership
    public var metadata: Data
    public var payloadVersion: Int
    public var requiredFeatures: [String]
    public init(id: UUID, ownership: CanonicalSourceOwnership = .unavailable,
                metadata: Data = Data("{}".utf8), payloadVersion: Int = 1,
                requiredFeatures: [String] = []) {
        self.id = id; self.ownership = ownership; self.metadata = metadata
        self.payloadVersion = payloadVersion; self.requiredFeatures = requiredFeatures
    }
    func validateWritable() throws {
        guard payloadVersion == 1, requiredFeatures.isEmpty, metadata.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
            throw VaultError.invalid("Unsupported canonical source payload.")
        }
        let reserved: Set<String> = ["id", "revision", "ownership", "trashed", "trashedAt", "blobPath", "sha256", "size", "linkedBookmark"]
        guard reserved.isDisjoint(with: object.keys) else { throw VaultError.invalid("Source payload duplicates relational fields.") }
        func validateDepth(_ value: Any, _ depth: Int) throws {
            guard depth <= 32 else { throw VaultError.invalid("Canonical source payload exceeds nesting limit.") }
            if let object = value as? [String: Any] { for value in object.values { try validateDepth(value, depth + 1) } }
            else if let array = value as? [Any] { for value in array { try validateDepth(value, depth + 1) } }
        }
        try validateDepth(object, 0)
    }
}
public struct CanonicalSourceSnapshot: Equatable, Sendable {
    public let source: CanonicalSource
    public let revision: BlockStoreRevision
    public let trashed: Bool
    public let trashedAt: Date?
}
public struct CanonicalPagePublication: Sendable {
    public let record: NoteRecord
    public let document: BlockDocument
    public let condition: BlockStoreWriteCondition
    public init(record: NoteRecord, document: BlockDocument, condition: BlockStoreWriteCondition) {
        self.record = record; self.document = document; self.condition = condition
    }
}
public struct CanonicalPublicationOutcome: Equatable, Sendable {
    public let operationID: UUID
    public let sourceID: UUID
    public let sourceRevision: BlockStoreRevision
    public let pageID: UUID?
    public let pageRevision: BlockStoreRevision?
    public let vaultRevision: BlockStoreRevision
}
public enum CanonicalEntityKind: String, Codable, Sendable { case page, source }
public struct CanonicalTombstone: Equatable, Sendable {
    public let id: UUID
    public let kind: CanonicalEntityKind
    public let lastRevision: BlockStoreRevision
    public let deletedAt: Date
    public let disposition: String
}
