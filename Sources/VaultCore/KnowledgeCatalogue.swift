import Foundation

/// Distinct canonical record families; none is inferred from designated block text.
public struct KnowledgeCatalogueSnapshot: Equatable, Sendable {
    public let entities: [KnowledgeEntitySnapshot]
    public let objects: [SemanticObjectSnapshot]
    public let annotations: [SemanticAnnotationSnapshot]
    public let vaultRevision: BlockStoreRevision
    public init(entities: [KnowledgeEntitySnapshot], objects: [SemanticObjectSnapshot], annotations: [SemanticAnnotationSnapshot], vaultRevision: BlockStoreRevision) {
        self.entities = entities; self.objects = objects; self.annotations = annotations; self.vaultRevision = vaultRevision
    }
}
