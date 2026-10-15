import Foundation
import VaultCore

/// Numeric usage and model metadata only; contains no request text or authorization material.
public struct OpenAIEmbeddingResult: Sendable {
    public let vectors: [EmbeddingVector]
    public let modelID: String
    public let usage: AIActivityUsage?
    public let requestCount: Int

    static func decode(_ body: Data, descriptor: EmbeddingModelDescriptor, count: Int,
                       requestCount: Int) throws -> Self {
        guard body.count <= ExternalAILimits.maximumResponseBytes,
              let response = try? JSONDecoder().decode(Envelope.self, from: body),
              response.object == "list", response.model == descriptor.modelID,
              response.data.count == count,
              Set(response.data.map(\.index)) == Set(0..<count),
              response.data.allSatisfy({ $0.object == "embedding" }) else { throw ExternalAIError.invalidResponse }
        let vectors: [EmbeddingVector]
        do { vectors = try response.data.sorted { $0.index < $1.index }.map { try EmbeddingVector(values: $0.embedding, model: descriptor) } }
        catch { throw ExternalAIError.invalidResponse }
        // Billing metadata is independently decoded so malformed usage cannot invalidate vectors.
        let reportedUsage = (try? JSONDecoder().decode(UsageEnvelope.self, from: body))?.usage
        let usage = reportedUsage.flatMap { usage -> AIActivityUsage? in
            guard (0...1_000_000_000).contains(usage.prompt_tokens), usage.total_tokens == usage.prompt_tokens else { return nil }
            return AIActivityUsage(inputTokens: usage.prompt_tokens, outputTokens: 0)
        }
        return Self(vectors: vectors, modelID: response.model, usage: usage, requestCount: requestCount)
    }
    private struct Envelope: Decodable {
        let object: String
        let model: String
        let data: [Item]
    }
    private struct UsageEnvelope: Decodable { let usage: Usage? }
    private struct Item: Decodable { let object: String; let index: Int; let embedding: [Float] }
    private struct Usage: Decodable { let prompt_tokens: Int; let total_tokens: Int }
}

/// Requires an issuer-minted exact-input capability. A generic execution context alone
/// never grants cloud permission. Construct one provider per approved request.
public struct OpenAIEmbeddingProvider: EmbeddingProvider {
    public let descriptor: EmbeddingModelDescriptor
    private let authorizer: ExternalAIEmbeddingAuthorizer
    private let authorization: ExternalAIEmbeddingAuthorization

    public init(authorizer: ExternalAIEmbeddingAuthorizer, authorization: ExternalAIEmbeddingAuthorization) {
        self.authorizer = authorizer; self.authorization = authorization
        descriptor = authorizer.descriptor
    }
    public func embed(_ inputs: [String], scope: EmbeddingProcessingScope,
                      context: EmbeddingExecutionContext) async throws -> [EmbeddingVector] {
        try await embedWithUsage(inputs, scope: scope, context: context).vectors
    }
    public func embedWithUsage(_ inputs: [String], scope: EmbeddingProcessingScope,
                               context: EmbeddingExecutionContext) async throws -> OpenAIEmbeddingResult {
        try await authorizer.performEmbedding(inputs, scope: scope, context: context, authorization: authorization)
    }
    public func validatePublication() throws { try authorizer.validatePublication(authorization) }
}
