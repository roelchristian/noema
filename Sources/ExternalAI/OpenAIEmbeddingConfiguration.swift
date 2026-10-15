import Foundation
import VaultCore

/// The explicit embedding allowlist is independent of generative model configuration.
public enum OpenAIEmbeddingModel: String, Sendable, CaseIterable, Codable {
    case small = "text-embedding-3-small"
    case large = "text-embedding-3-large"

    public var dimensions: Int {
        switch self {
        case .small: 1_536
        case .large: 3_072
        }
    }

    public var displayName: String {
        switch self {
        case .small: "text-embedding-3-small (Default) — 1,536 dimensions"
        case .large: "text-embedding-3-large — 3,072 dimensions"
        }
    }
}

/// Nonsecret connection preference. Selection alone never authorizes or schedules inference.
/// Index owners must compare the full configuration before reusing an embedding generation.
public struct OpenAIEmbeddingConfiguration: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public let version: Int
    public let model: OpenAIEmbeddingModel
    public var modelIdentifier: String { model.rawValue }
    public var dimensions: Int { model.dimensions }

    public init(model: OpenAIEmbeddingModel = .small) {
        version = Self.currentVersion
        self.model = model
    }

    public init(modelIdentifier: String) throws {
        guard let model = OpenAIEmbeddingModel(rawValue: modelIdentifier) else {
            throw ExternalAIError.invalidConfiguration
        }
        self.init(model: model)
    }

    /// A necessary selection check only. A match does not prove generation compatibility:
    /// callers must still verify the full descriptor, chunker version, and vault identity.
    public func matchesSelection(of descriptor: EmbeddingModelDescriptor) -> Bool {
        descriptor.providerID == "openai"
            && descriptor.modelID == modelIdentifier
            && descriptor.dimensions == dimensions
    }

    public static let `default` = OpenAIEmbeddingConfiguration()

    private enum CodingKeys: String, CodingKey { case version, model }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw ExternalAIError.invalidConfiguration
        }
        self.init(model: try values.decode(OpenAIEmbeddingModel.self, forKey: .model))
    }
}
