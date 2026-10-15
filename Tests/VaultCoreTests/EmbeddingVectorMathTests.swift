import Foundation
import Testing
@testable import VaultCore

private func vectorMathModel(revision: String = "1", dimensions: Int = 3) throws -> EmbeddingModelDescriptor {
    try EmbeddingModelDescriptor(providerID: "mock", modelID: "vector-math", revision: revision,
        dimensions: dimensions, maximumInputUTF8Bytes: 128, maximumBatchSize: 2)
}

@Test func embeddingFloat32EncodingIsPortableAndRejectsCorruption() throws {
    let model = try vectorMathModel()
    let vector = try EmbeddingVector(values: [1, -2, 0.5], model: model)
    let expected = Data([0, 0, 128, 63, 0, 0, 0, 192, 0, 0, 0, 63])
    #expect(vector.encodedFloat32LittleEndian() == expected)
    #expect(try EmbeddingVector(float32LittleEndian: expected, model: model) == vector)
    for invalid in [Data(), Data(expected.dropLast()), expected + Data([0]), Data(repeating: 0, count: 12),
                    Data([0, 0, 128, 127]) + Data(expected.dropFirst(4))] {
        #expect(throws: EmbeddingContractError.invalidVector) {
            try EmbeddingVector(float32LittleEndian: invalid, model: model)
        }
    }
    // Data slices can have a nonzero startIndex and an unaligned original address.
    let padded = Data([99]) + expected
    #expect(try EmbeddingVector(float32LittleEndian: padded.dropFirst(), model: model) == vector)
}

@Test func embeddingCosineRejectsMixedModelsAndHandlesExtremeFloats() throws {
    let model = try vectorMathModel()
    let x = try EmbeddingVector(values: [1, 0, 0], model: model)
    let y = try EmbeddingVector(values: [0, 1, 0], model: model)
    let opposite = try EmbeddingVector(values: [-1, 0, 0], model: model)
    #expect(try x.cosineSimilarity(to: x) == 1)
    #expect(try x.cosineSimilarity(to: y) == 0)
    #expect(try x.cosineSimilarity(to: opposite) == -1)
    for value in [Float.greatestFiniteMagnitude, Float.leastNonzeroMagnitude] {
        let extreme = try EmbeddingVector(values: [value, value, value], model: model)
        #expect(abs(try extreme.cosineSimilarity(to: extreme) - 1) < 1e-12)
    }
    let foreign = try EmbeddingVector(values: [1, 0, 0], model: vectorMathModel(revision: "2"))
    #expect(throws: EmbeddingContractError.incompatibleGeneration) { try x.cosineSimilarity(to: foreign) }
}
