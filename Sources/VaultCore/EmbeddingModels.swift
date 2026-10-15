import Foundation

public enum EmbeddingContractError: Error, Sendable, Equatable {
    case invalidModel, invalidIdentity, invalidChunk, invalidVector, incompatibleGeneration
    case invalidInput, authorityDenied
}

/// Exact model identity. A revision or any input-policy change requires a new generation.
/// UTF-8 bytes are a conservative transport limit; providers must also enforce their tokenizer limit.
public struct EmbeddingModelDescriptor: Sendable, Equatable, Hashable {
    public let providerID: String
    public let modelID: String
    public let revision: String
    public let dimensions: Int
    public let maximumInputUTF8Bytes: Int
    public let maximumBatchSize: Int

    public init(providerID: String, modelID: String, revision: String, dimensions: Int,
                maximumInputUTF8Bytes: Int, maximumBatchSize: Int) throws {
        guard [providerID, modelID, revision].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              dimensions > 0, maximumInputUTF8Bytes > 0, maximumBatchSize > 0 else {
            throw EmbeddingContractError.invalidModel
        }
        self.providerID = providerID; self.modelID = modelID; self.revision = revision
        self.dimensions = dimensions; self.maximumInputUTF8Bytes = maximumInputUTF8Bytes
        self.maximumBatchSize = maximumBatchSize
    }
}

/// Immutable finite, nonzero Float32 values with an exact model identity.
public struct EmbeddingVector: Sendable, Equatable {
    public let values: [Float]
    public let model: EmbeddingModelDescriptor
    public init(values: [Float], model: EmbeddingModelDescriptor) throws {
        guard values.count == model.dimensions, values.allSatisfy(\.isFinite),
              values.contains(where: { $0 != 0 }) else { throw EmbeddingContractError.invalidVector }
        self.values = values; self.model = model
    }
}

/// Uses the same opaque revision convention as AIContentChange; never a timestamp or document text.
public struct EmbeddingEntityIdentity: Sendable, Equatable {
    public let vaultID: UUID
    public let entityKind: AIEntityKind
    public let entityID: UUID
    public let revision: String
    public init(vaultID: UUID, entityKind: AIEntityKind, entityID: UUID, revision: String) throws {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmbeddingContractError.invalidIdentity
        }
        self.vaultID = vaultID; self.entityKind = entityKind; self.entityID = entityID; self.revision = revision
    }
}

/// Metadata only: canonical input text remains in the authoritative store or transient request.
public struct EmbeddingChunk: Sendable, Equatable {
    public let identity: EmbeddingEntityIdentity
    public let chunkID: String
    public let ordinal: Int
    public let contentFingerprint: String
    public let chunkingVersion: String
    public init(identity: EmbeddingEntityIdentity, chunkID: String, ordinal: Int,
                contentFingerprint: String, chunkingVersion: String) throws {
        guard ordinal >= 0, [chunkID, contentFingerprint, chunkingVersion].allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw EmbeddingContractError.invalidChunk }
        self.identity = identity; self.chunkID = chunkID; self.ordinal = ordinal
        self.contentFingerprint = contentFingerprint; self.chunkingVersion = chunkingVersion
    }
}

public struct EmbeddingIndexGeneration: Sendable, Equatable {
    public let id: UUID
    public let vaultID: UUID
    public let model: EmbeddingModelDescriptor
    public let chunkingVersion: String
    public init(id: UUID = UUID(), vaultID: UUID, model: EmbeddingModelDescriptor,
                chunkingVersion: String) throws {
        guard !chunkingVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmbeddingContractError.invalidChunk
        }
        self.id = id; self.vaultID = vaultID; self.model = model; self.chunkingVersion = chunkingVersion
    }
    public func validate(chunk: EmbeddingChunk, vector: EmbeddingVector) throws {
        guard chunk.identity.vaultID == vaultID, chunk.chunkingVersion == chunkingVersion,
              vector.model == model else { throw EmbeddingContractError.incompatibleGeneration }
    }
}

public struct EmbeddingRecord: Sendable, Equatable {
    public let generation: EmbeddingIndexGeneration
    public let chunk: EmbeddingChunk
    public let vector: EmbeddingVector
    public init(generation: EmbeddingIndexGeneration, chunk: EmbeddingChunk, vector: EmbeddingVector) throws {
        try generation.validate(chunk: chunk, vector: vector)
        self.generation = generation; self.chunk = chunk; self.vector = vector
    }
}
