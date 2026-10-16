import Foundation

/// Explicit evidence-to-thing roles, independent of entity property relationships.
public enum SourceEntityAssociationRole: String, Codable, CaseIterable, Sendable {
    case representsWork
    case aboutEntity
}

public struct SourceEntityAssociation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let entityID: UUID
    public let role: SourceEntityAssociationRole
    public let createdAt: Date

    public init(id: UUID = UUID(), sourceID: UUID, entityID: UUID, role: SourceEntityAssociationRole, createdAt: Date = Date()) {
        self.id = id; self.sourceID = sourceID; self.entityID = entityID
        self.role = role; self.createdAt = createdAt
    }
}

public struct SourceEntityAssociationSnapshot: Codable, Equatable, Sendable {
    public let association: SourceEntityAssociation
    public let revision: BlockStoreRevision

    public init(association: SourceEntityAssociation, revision: BlockStoreRevision) {
        self.association = association; self.revision = revision
    }
}
