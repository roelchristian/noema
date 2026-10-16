import Foundation

/// Vault-scoped ordered suggestions; these identifiers never assert entity facts.
public struct EntityPropertyTemplateSnapshot: Codable, Equatable, Sendable {
    public static let maximumEntries = 16
    public let typeKey: String
    public let definitionIDs: [UUID]
    public let revision: BlockStoreRevision?

    public init(typeKey: String, definitionIDs: [UUID], revision: BlockStoreRevision?) {
        self.typeKey = typeKey
        self.definitionIDs = definitionIDs
        self.revision = revision
    }
}
