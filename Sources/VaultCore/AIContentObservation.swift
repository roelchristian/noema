import Foundation

extension FileVaultRepository {
    /// Notifications contain committed identities only. Delivery never delays canonical saving.
    public func setAIContentChangeHandler(_ handler: (@Sendable (AIContentChange) -> Void)?) {
        aiContentChangeHandler = handler
    }

    func emitAIPageChange(_ saved: NoteRecord, previous: NoteRecord?, kind: AIChangeKind = .updated,
                          origin: AIChangeOrigin = .user) {
        var dimensions: Set<AIContentDimension> = []
        if kind == .removed || kind == .restored { dimensions.insert(.lifecycle) }
        if previous?.body != saved.body || previous?.document != saved.document { dimensions.insert(.body) }
        if previous?.title != saved.title { dimensions.insert(.title) }
        if previous?.tags != saved.tags || previous?.lcc != saved.lcc || previous?.sourceIDs != saved.sourceIDs {
            dimensions.insert(.metadata)
        }
        guard !dimensions.isEmpty else { return }
        aiContentChangeHandler?(.init(vaultID: manifest.id, entityKind: .page, entityID: saved.id,
            revision: saved.contentHash, kind: kind, origin: origin, dimensions: dimensions))
    }

    func emitAISourceChange(id: UUID, kind: AIChangeKind = .updated, origin: AIChangeOrigin = .user,
                            dimensions: Set<AIContentDimension>) async {
        guard !dimensions.isEmpty, let snapshot = try? await sqliteBlockStore.sourceSnapshot(id: id) else { return }
        aiContentChangeHandler?(.init(vaultID: manifest.id, entityKind: .source, entityID: id,
            revision: snapshot.revision.token.base64EncodedString(), kind: kind, origin: origin, dimensions: dimensions))
    }

    /// Lightweight revision inventory; no source original is read and no historical inference is implied.
    public func aiProcessingInventory() async throws -> [AIContentChange] {
        try validateAccess(operation: "aiProcessingInventory")
        let result = try await sqliteBlockStore.aiProcessingRevisionInventory(vaultID: manifest.id)
        try validateAccess(operation: "aiProcessingInventory.complete")
        return result
    }
}
