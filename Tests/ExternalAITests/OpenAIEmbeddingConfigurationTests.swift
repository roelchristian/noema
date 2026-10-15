import Foundation
import Testing
import ExternalAI
import VaultCore

@Suite("OpenAI embedding model configuration")
struct OpenAIEmbeddingConfigurationTests {
    @Test func allowlistHasIndependentDefaultAndFixedDimensions() throws {
        #expect(OpenAIEmbeddingConfiguration.default.model == .small)
        #expect(OpenAIEmbeddingConfiguration.default.dimensions == 1_536)
        #expect(OpenAIEmbeddingConfiguration.default.version == 1)
        #expect(OpenAIEmbeddingModel.allCases.count == 2)
        let large = try OpenAIEmbeddingConfiguration(modelIdentifier: "text-embedding-3-large")
        #expect(large.dimensions == 3_072)
        #expect(large != .default)
        #expect(try JSONDecoder().decode(OpenAIEmbeddingConfiguration.self,
            from: JSONEncoder().encode(large)) == large)
    }

    @Test func selectionRequiresMatchingProviderModelAndDimensions() throws {
        let small = OpenAIEmbeddingConfiguration.default
        let large = OpenAIEmbeddingConfiguration(model: .large)
        func descriptor(provider: String = "openai", model: OpenAIEmbeddingModel = .small,
                        dimensions: Int? = nil, revision: String = "test-revision") throws -> EmbeddingModelDescriptor {
            try EmbeddingModelDescriptor(providerID: provider, modelID: model.rawValue,
                revision: revision, dimensions: dimensions ?? model.dimensions,
                maximumInputUTF8Bytes: 1_000, maximumBatchSize: 1)
        }
        #expect(small.matchesSelection(of: try descriptor()))
        #expect(large.matchesSelection(of: try descriptor(model: .large)))
        #expect(!small.matchesSelection(of: try descriptor(model: .large)))
        #expect(!large.matchesSelection(of: try descriptor()))
        #expect(!small.matchesSelection(of: try descriptor(provider: "mock")))
        #expect(!small.matchesSelection(of: try descriptor(provider: "OpenAI")))
        #expect(!small.matchesSelection(of: try descriptor(dimensions: 3_072)))
        // Selection cannot establish full revision/input-policy/generation compatibility.
        #expect(small.matchesSelection(of: try descriptor(revision: "another-test-revision")))
    }

    @Test(arguments: ["", "gpt-4.1-mini", "text-embedding-3-small/../../responses", "text-embedding-ada-002"])
    func rejectsModelsOutsideExplicitAllowlist(model: String) {
        #expect(throws: ExternalAIError.invalidConfiguration) {
            try OpenAIEmbeddingConfiguration(modelIdentifier: model)
        }
    }

    @Test(arguments: [
        "{\"version\":2,\"model\":\"text-embedding-3-small\"}",
        "{\"version\":1,\"model\":\"gpt-4.1-mini\"}",
        "{\"model\":\"text-embedding-3-small\"}"
    ])
    func rejectsUnknownStoredVersionOrModel(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(OpenAIEmbeddingConfiguration.self, from: Data(json.utf8))
        }
    }
}
