import Foundation

/// Portable compact representation for derived vector storage. No text or authority is encoded.
public extension EmbeddingVector {
    func encodedFloat32LittleEndian() -> Data {
        var data = Data()
        for value in values {
            let bits = value.bitPattern
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
            data.append(UInt8(truncatingIfNeeded: bits >> 16))
            data.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        return data
    }

    init(float32LittleEndian data: Data, model: EmbeddingModelDescriptor) throws {
        guard data.count % 4 == 0, data.count / 4 == model.dimensions else {
            throw EmbeddingContractError.invalidVector
        }
        // Decode individual bytes: SQLite BLOBs and Data slices need not be aligned.
        let bytes = Array(data)
        var values: [Float] = []
        values.reserveCapacity(model.dimensions)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let bits = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            values.append(Float(bitPattern: bits))
        }
        try self.init(values: values, model: model)
    }

    /// Exact cosine over one compatible vector space. Double accumulation avoids
    /// Float32 overflow/underflow even for finite extreme or subnormal components.
    func cosineSimilarity(to other: EmbeddingVector) throws -> Double {
        guard model == other.model else { throw EmbeddingContractError.incompatibleGeneration }
        var dot = 0.0, leftNorm = 0.0, rightNorm = 0.0
        for index in values.indices {
            let left = Double(values[index]), right = Double(other.values[index])
            dot += left * right
            leftNorm += left * left
            rightNorm += right * right
        }
        let score = dot / (sqrt(leftNorm) * sqrt(rightNorm))
        guard score.isFinite else { throw EmbeddingContractError.invalidVector }
        return min(1, max(-1, score))
    }
}
