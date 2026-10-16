import Foundation
import VaultCore

struct SourceEntityLinksSnapshot: Sendable {
    static let pageSize = 100
    let associations: [SourceEntityAssociationSnapshot]
    let sources: [CanonicalSourceSnapshot]
    let entities: [KnowledgeEntitySnapshot]
    let vaultRevision: BlockStoreRevision
    let sessionID: UUID?
    let offset: Int
    var hasNextPage: Bool { associations.count == Self.pageSize }
}

enum SourceEntityLinksPresentation {
    static func canDisplayEntitySources(_ snapshot: SourceEntityLinksSnapshot, entityID: UUID,
        requestedEntityID: UUID?, requestedSessionID: UUID?, sessionID: UUID?, isLocked: Bool) -> Bool {
        !isLocked && requestedEntityID == entityID && requestedSessionID == sessionID &&
            snapshot.sessionID == sessionID && snapshot.entities.contains { $0.entity.id == entityID }
    }
    static func roleLabel(_ role: SourceEntityAssociationRole) -> String {
        switch role {
        case .representsWork: "Represents work"
        case .aboutEntity: "About entity"
        }
    }
    static func sourceTitle(_ snapshot: CanonicalSourceSnapshot) -> String {
        (try? snapshot.source.sourceMetadata().title) ?? "Unavailable Source · \(snapshot.source.id.uuidString.prefix(8))"
    }
    static func sourceStatus(_ snapshot: CanonicalSourceSnapshot, availability: String?) -> String {
        let status: String
        if snapshot.source.ownership == .unavailable { status = "Original unavailable" }
        else if let availability, !availability.isEmpty { status = "Last check: \(availability)" }
        else { status = "Original not verified" }
        return snapshot.trashed ? "Source in Trash · \(status)" : status
    }
    static func eligibleEntities(_ entities: [KnowledgeEntitySnapshot], role: SourceEntityAssociationRole) -> [KnowledgeEntitySnapshot] {
        entities.filter { entity in entity.entity.lifecycle == .live &&
            KnowledgeEntityType.initial.contains(where: { $0.key == entity.entity.typeKey }) &&
            (role != .representsWork || entity.entity.typeKey == "creativeWork") }
    }
}
