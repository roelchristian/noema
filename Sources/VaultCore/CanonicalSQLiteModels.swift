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
    public var original: CanonicalSourceOriginal?
    public var payloadVersion: Int
    public var requiredFeatures: [String]
    public init(id: UUID, ownership: CanonicalSourceOwnership = .unavailable,
                metadata: Data = Data("{}".utf8), payloadVersion: Int = 1,
                requiredFeatures: [String] = [], original: CanonicalSourceOriginal? = nil) {
        self.id = id; self.ownership = ownership; self.metadata = metadata
        self.original = original
        self.payloadVersion = payloadVersion; self.requiredFeatures = requiredFeatures
    }
    func validateWritable() throws {
        guard payloadVersion == 1, requiredFeatures.isEmpty, metadata.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
            throw VaultError.invalid("Unsupported canonical source payload.")
        }
        let reserved: Set<String> = ["id", "revision", "ownership", "trashed", "trashedAt", "blobPath", "sha256", "size", "fileSize", "linkedBookmark", "storedFilename"]
        guard reserved.isDisjoint(with: object.keys) else { throw VaultError.invalid("Source payload duplicates relational fields.") }
        func validateDepth(_ value: Any, _ depth: Int) throws {
            guard depth <= 32 else { throw VaultError.invalid("Canonical source payload exceeds nesting limit.") }
            if let object = value as? [String: Any] { for value in object.values { try validateDepth(value, depth + 1) } }
            else if let array = value as? [Any] { for value in array { try validateDepth(value, depth + 1) } }
        }
        try validateDepth(object, 0)
        if let raw = object["extensions"] {
            let payload = try JSONDecoder().decode(PersistencePayload.self, from: JSONSerialization.data(withJSONObject: raw))
            try payload.validateWritable()
        }
        if let original {
            guard ownership != .unavailable, original.size >= 0, original.checksum.count == 64,
                  original.checksum.allSatisfy({ $0.isHexDigit }) else { throw VaultError.invalid("Invalid original checksum/size descriptor.") }
            switch ownership {
            case .imported:
                let prefix = "Sources/" + id.uuidString.lowercased() + "/"
                guard let path = original.blobPath, path.hasPrefix(prefix), original.linkedBookmark == nil,
                      !path.dropFirst(prefix.count).contains("/"), !path.dropFirst(prefix.count).isEmpty,
                      !path.dropFirst(prefix.count).hasPrefix(".") else { throw VaultError.invalid("Original descriptor escapes source ownership.") }
            case .linked:
                guard original.blobPath == nil, let bookmark = original.linkedBookmark, !bookmark.isEmpty else { throw VaultError.invalid("Invalid linked original descriptor.") }
            case .unavailable: break
            }
        }
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

/// Unique conflict bytes remain preserved after disposition, including when the
/// original target is unavailable or tombstoned.
public struct CanonicalConflict: Equatable, Sendable {
    public var id: UUID
    public var targetID: UUID
    public var targetKind: CanonicalEntityKind
    public var baseRevision: BlockStoreRevision?
    public var payloadVersion: Int
    public var preservedPayload: Data
    public init(id: UUID = UUID(), targetID: UUID, targetKind: CanonicalEntityKind,
                baseRevision: BlockStoreRevision? = nil, payloadVersion: Int = 1,
                preservedPayload: Data) {
        self.id = id; self.targetID = targetID; self.targetKind = targetKind
        self.baseRevision = baseRevision; self.payloadVersion = payloadVersion
        self.preservedPayload = preservedPayload
    }
}
public enum CanonicalConflictDisposition: String, Sendable { case pending, retained, pagePublished }
public struct CanonicalConflictSnapshot: Equatable, Sendable {
    public let conflict: CanonicalConflict
    public let createdAt: Date
    public let disposition: CanonicalConflictDisposition
    public let revision: BlockStoreRevision
}

/// Relational immutable-original descriptor; metadata never duplicates these fields.
public struct CanonicalSourceOriginal: Equatable, Sendable {
    public let blobPath: String?
    public let checksum: String
    public let size: Int
    public let linkedBookmark: Data?
    public init(blobPath: String?, checksum: String, size: Int, linkedBookmark: Data? = nil) {
        self.blobPath = blobPath; self.checksum = checksum; self.size = size; self.linkedBookmark = linkedBookmark
    }
}
public extension CanonicalSource {
    init(metadata: SourceMetadata) throws {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any] else { throw VaultError.invalid("Invalid source metadata object.") }
        for key in ["id", "sha256", "fileSize", "linkedBookmark", "storedFilename"] { object.removeValue(forKey: key) }
        let path = "Sources/" + metadata.id.uuidString.lowercased() + "/" + metadata.storedFilename
        self.init(id: metadata.id, ownership: metadata.isLinked ? .linked : .imported,
                  metadata: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  original: .init(blobPath: metadata.isLinked ? nil : path, checksum: metadata.sha256,
                                  size: metadata.fileSize ?? 0, linkedBookmark: metadata.linkedBookmark))
        try validateWritable()
    }
    func sourceMetadata() throws -> SourceMetadata {
        try validateWritable()
        guard var object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] else { throw VaultError.invalid("Invalid source payload object.") }
        object["id"] = id.uuidString
        object["sha256"] = original?.checksum ?? ""
        object["fileSize"] = original?.size
        object["storedFilename"] = original?.blobPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? object["originalFilename"] ?? "original"
        if let bookmark = original?.linkedBookmark { object["linkedBookmark"] = bookmark.base64EncodedString() }
        return try JSONDecoder().decode(SourceMetadata.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
