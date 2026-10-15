import Foundation
import Synchronization
import Testing
@testable import VaultCore

private func embeddingTestModel(provider: String = "mock", revision: String = "1", dimensions: Int = 3,
                                bytes: Int = 32, batch: Int = 2) throws -> EmbeddingModelDescriptor {
    try EmbeddingModelDescriptor(providerID: provider, modelID: "synthetic", revision: revision,
                                 dimensions: dimensions, maximumInputUTF8Bytes: bytes, maximumBatchSize: batch)
}

@Test func embeddingModelAndVectorRejectInvalidInputs() throws {
    #expect(throws: EmbeddingContractError.invalidModel) { try embeddingTestModel(provider: " ") }
    #expect(throws: EmbeddingContractError.invalidModel) { try embeddingTestModel(revision: "") }
    #expect(throws: EmbeddingContractError.invalidModel) { try embeddingTestModel(dimensions: 0) }
    #expect(throws: EmbeddingContractError.invalidModel) { try embeddingTestModel(bytes: 0) }
    #expect(throws: EmbeddingContractError.invalidModel) { try embeddingTestModel(batch: 0) }
    let model = try embeddingTestModel()
    for values: [Float] in [[1, 2], [0, 0, 0], [.nan, 1, 2], [.infinity, 1, 2]] {
        #expect(throws: EmbeddingContractError.invalidVector) { try EmbeddingVector(values: values, model: model) }
    }
    #expect(try EmbeddingVector(values: [1, 0, -1], model: model).values == [1, 0, -1])
}

@Test func embeddingGenerationRejectsCrossVaultAndCompatibilityChanges() throws {
    let vault = UUID()
    let model = try embeddingTestModel()
    let generation = try EmbeddingIndexGeneration(vaultID: vault, model: model, chunkingVersion: "1")
    let identity = try EmbeddingEntityIdentity(vaultID: vault, entityKind: .page, entityID: UUID(), revision: "opaque")
    let chunk = try EmbeddingChunk(identity: identity, chunkID: "block-1", ordinal: 0,
                                   contentFingerprint: "digest", chunkingVersion: "1")
    let vector = try EmbeddingVector(values: [1, 2, 3], model: model)
    #expect(try EmbeddingRecord(generation: generation, chunk: chunk, vector: vector).chunk == chunk)
    for changed in [try embeddingTestModel(provider: "other"), try embeddingTestModel(revision: "2"),
                    try embeddingTestModel(dimensions: 4), try embeddingTestModel(bytes: 64),
                    try embeddingTestModel(batch: 3)] {
        let changedVector = try EmbeddingVector(values: Array(repeating: 1, count: changed.dimensions), model: changed)
        #expect(throws: EmbeddingContractError.incompatibleGeneration) {
            try EmbeddingRecord(generation: generation, chunk: chunk, vector: changedVector)
        }
    }
    let foreign = try EmbeddingEntityIdentity(vaultID: UUID(), entityKind: .source, entityID: UUID(), revision: "opaque")
    let foreignChunk = try EmbeddingChunk(identity: foreign, chunkID: "block-1", ordinal: 0,
                                          contentFingerprint: "digest", chunkingVersion: "1")
    #expect(throws: EmbeddingContractError.incompatibleGeneration) {
        try generation.validate(chunk: foreignChunk, vector: vector)
    }
    let rechunked = try EmbeddingChunk(identity: identity, chunkID: "block-1", ordinal: 0,
                                       contentFingerprint: "digest", chunkingVersion: "2")
    #expect(throws: EmbeddingContractError.incompatibleGeneration) {
        try generation.validate(chunk: rechunked, vector: vector)
    }
}

@Test func embeddingIdentitiesRequireOpaqueRevisionAndChunkMetadata() throws {
    #expect(throws: EmbeddingContractError.invalidIdentity) {
        try EmbeddingEntityIdentity(vaultID: UUID(), entityKind: .page, entityID: UUID(), revision: " ")
    }
    let identity = try EmbeddingEntityIdentity(vaultID: UUID(), entityKind: .source, entityID: UUID(), revision: "r")
    #expect(throws: EmbeddingContractError.invalidChunk) {
        try EmbeddingChunk(identity: identity, chunkID: "", ordinal: 0, contentFingerprint: "f", chunkingVersion: "1")
    }
    #expect(throws: EmbeddingContractError.invalidChunk) {
        try EmbeddingChunk(identity: identity, chunkID: "c", ordinal: -1, contentFingerprint: "f", chunkingVersion: "1")
    }
}

@Test func embeddingMockIsDeterministicAndEnforcesUTF8AndBatchLimits() async throws {
    let model = try embeddingTestModel(bytes: 4)
    let provider = MockEmbeddingProvider(descriptor: model)
    let vault = UUID()
    let scope = EmbeddingProcessingScope.query(vaultID: vault, queryID: UUID())
    let lease = VaultSessionLease(vaultID: vault, root: URL(fileURLWithPath: "/tmp/embedding-contract"), generation: 1)
    let context = try EmbeddingExecutionContext(lease: lease, scope: scope, model: model, validateCurrentAuthority: {})
    let first = try await provider.embed(["one", "two"], scope: scope, context: context)
    let second = try await provider.embed(["one", "two"], scope: scope, context: context)
    #expect(first == second)
    #expect(first.count == 2)
    #expect(first[0] != first[1])
    for invalid in [[], [""], [" "], ["ééé"], ["a", "b", "c"]] {
        await #expect(throws: EmbeddingContractError.invalidInput) {
            try await provider.embed(invalid, scope: scope, context: context)
        }
    }
}

@Test func embeddingAuthorityCannotCrossScopeVaultModelOrRevocation() async throws {
    let model = try embeddingTestModel()
    let vault = UUID()
    let identity = try EmbeddingEntityIdentity(vaultID: vault, entityKind: .page, entityID: UUID(), revision: "r1")
    let scope = EmbeddingProcessingScope.document(identity)
    let lease = VaultSessionLease(vaultID: vault, root: URL(fileURLWithPath: "/tmp/embedding-contract"), generation: 1)
    let calls = Mutex(0)
    let context = try EmbeddingExecutionContext(lease: lease, scope: scope, model: model) {
        try calls.withLock { count in
            count += 1
            if count > 1 { throw EmbeddingContractError.authorityDenied }
        }
    }
    let provider = MockEmbeddingProvider(descriptor: model)
    // Revocation between dispatch and returning results prevents result publication.
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await provider.embed(["one"], scope: scope, context: context)
    }
    let allowed = try EmbeddingExecutionContext(lease: lease, scope: scope, model: model, validateCurrentAuthority: {})
    for other in [EmbeddingProcessingScope.query(vaultID: vault, queryID: UUID()),
                  .historicalBackfill(jobID: UUID(), entity: identity)] {
        await #expect(throws: EmbeddingContractError.authorityDenied) {
            try await provider.embed(["one"], scope: other, context: allowed)
        }
    }
    #expect(throws: EmbeddingContractError.authorityDenied) {
        try allowed.validate(scope: scope, model: embeddingTestModel(revision: "2"))
    }
    #expect(throws: EmbeddingContractError.authorityDenied) {
        try EmbeddingExecutionContext(lease: lease, scope: .query(vaultID: UUID(), queryID: UUID()),
                                      model: model, validateCurrentAuthority: {})
    }
}
