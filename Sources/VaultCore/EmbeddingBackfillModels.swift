import Foundation

/// Persisted user intent, never a session, grant or request capability.
public enum EmbeddingBackfillState: String, Codable, Sendable {
    case active, paused, awaitingApproval, cancellationRequested, cancelled, completed, incompatible
}
public enum EmbeddingBackfillMode: String, Codable, Sendable { case indexExisting, rebuild }
public enum EmbeddingBackfillMemberState: String, Codable, Sendable {
    case pending, admitted, completed, skipped, blocked, failed, unavailable, cancelled, interrupted, superseded
    public var isTerminal: Bool { [.completed, .skipped, .failed, .unavailable, .cancelled, .superseded].contains(self) }
}

public struct EmbeddingBackfillBatch: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let generation: EmbeddingIndexGeneration
    public let scopes: Set<AIEntityKind>
    public let mode: EmbeddingBackfillMode
    public let createdAt: Date
    public var state: EmbeddingBackfillState
    public var vaultID: UUID { generation.vaultID }

    public init(id: UUID = UUID(), generation: EmbeddingIndexGeneration, scopes: Set<AIEntityKind>,
                mode: EmbeddingBackfillMode = .indexExisting, createdAt: Date,
                state: EmbeddingBackfillState? = nil) throws {
        guard !scopes.isEmpty, createdAt.timeIntervalSince1970.isFinite,
              [generation.model.providerID, generation.model.modelID, generation.model.revision,
               generation.chunkingVersion].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw AIWorkLedgerError.invalidMetadata
        }
        self.id = id; self.generation = generation; self.scopes = scopes; self.mode = mode
        self.createdAt = createdAt
        self.state = state ?? (generation.model.providerID == "openai" ? .awaitingApproval : .active)
    }

    private enum CodingKeys: String, CodingKey { case id, generation, scopes, mode, createdAt, state }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let record = try c.decode(GenerationRecord.self, forKey: .generation)
        try self.init(id: c.decode(UUID.self, forKey: .id), generation: record.value(),
                      scopes: c.decode(Set<AIEntityKind>.self, forKey: .scopes),
                      mode: c.decode(EmbeddingBackfillMode.self, forKey: .mode),
                      createdAt: c.decode(Date.self, forKey: .createdAt),
                      state: c.decode(EmbeddingBackfillState.self, forKey: .state))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(GenerationRecord(generation), forKey: .generation)
        try c.encode(scopes, forKey: .scopes); try c.encode(mode, forKey: .mode)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(state, forKey: .state)
    }

    private struct GenerationRecord: Codable {
        let id: UUID, vaultID: UUID
        let providerID: String, modelID: String, revision: String, chunkingVersion: String
        let dimensions: Int, maximumInputUTF8Bytes: Int, maximumBatchSize: Int
        init(_ g: EmbeddingIndexGeneration) {
            id = g.id; vaultID = g.vaultID; providerID = g.model.providerID; modelID = g.model.modelID
            revision = g.model.revision; chunkingVersion = g.chunkingVersion
            dimensions = g.model.dimensions; maximumInputUTF8Bytes = g.model.maximumInputUTF8Bytes
            maximumBatchSize = g.model.maximumBatchSize
        }
        func value() throws -> EmbeddingIndexGeneration {
            try EmbeddingIndexGeneration(id: id, vaultID: vaultID,
                model: EmbeddingModelDescriptor(providerID: providerID, modelID: modelID, revision: revision,
                    dimensions: dimensions, maximumInputUTF8Bytes: maximumInputUTF8Bytes,
                    maximumBatchSize: maximumBatchSize), chunkingVersion: chunkingVersion)
        }
    }
}

/// Immutable captured inventory identity and stable coordinator job ID. No document text.
public struct EmbeddingBackfillMember: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID { workID }
    public let batchID: UUID
    public let workID: UUID
    public let vaultID: UUID
    public let entityKind: AIEntityKind
    public let entityID: UUID
    public let revision: String
    public var state: EmbeddingBackfillMemberState
    public var failure: AIWorkFailure?

    init(batchID: UUID, change: AIContentChange) {
        self.batchID = batchID; workID = UUID(); vaultID = change.vaultID
        entityKind = change.entityKind; entityID = change.entityID; revision = change.revision
        state = .pending; failure = nil
    }
}
