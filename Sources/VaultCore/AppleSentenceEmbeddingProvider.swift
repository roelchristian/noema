import Foundation
import NaturalLanguage

public enum AppleSentenceEmbeddingError: Error, Sendable, Equatable {
    case unavailable(languageCode: String)
    case unsupportedInputLanguage
}

/// Actor ownership confines the framework model; no framework object crosses isolation.
/// The input-v1 policy is deliberately conservative, not a claim about Apple's model capacity.
public actor AppleSentenceEmbeddingProvider: EmbeddingProvider {
    public nonisolated let descriptor: EmbeddingModelDescriptor
    private let backend: any AppleSentenceEmbeddingBackend
    private static let maximumWords = 128

    /// Availability is checked locally. Failure never selects another model or a cloud provider.
    public init(languageCode: String = "en") throws {
        let backend = try NaturalLanguageSentenceEmbeddingBackend(languageCode: languageCode)
        self.descriptor = try Self.modelDescriptor(backend)
        self.backend = backend
    }

    /// Transferring the backend permits deterministic tests without loading system models.
    init(languageCode: String = "en", backend: sending (any AppleSentenceEmbeddingBackend)?) throws {
        guard let backend, backend.languageCode == languageCode else {
            throw AppleSentenceEmbeddingError.unavailable(languageCode: languageCode)
        }
        self.descriptor = try Self.modelDescriptor(backend)
        self.backend = backend
    }

    private static func modelDescriptor(_ backend: any AppleSentenceEmbeddingBackend) throws -> EmbeddingModelDescriptor {
        guard backend.revision > 0, !backend.languageCode.isEmpty else {
            throw EmbeddingContractError.invalidModel
        }
        return try EmbeddingModelDescriptor(
            providerID: "apple-natural-language", modelID: "sentence-\(backend.languageCode)-input-v1",
            revision: String(backend.revision), dimensions: backend.dimension,
            maximumInputUTF8Bytes: 1024, maximumBatchSize: 16)
    }

    public func embed(_ inputs: [String], scope: EmbeddingProcessingScope,
                      context: EmbeddingExecutionContext) async throws -> [EmbeddingVector] {
        try context.validate(scope: scope, model: descriptor)
        guard !inputs.isEmpty, inputs.count <= descriptor.maximumBatchSize,
              inputs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.utf8.count <= descriptor.maximumInputUTF8Bytes }) else {
            throw EmbeddingContractError.invalidInput
        }
        // Validate the complete batch before invoking inference for its first input.
        for input in inputs {
            guard backend.dominantLanguage(for: input) == backend.languageCode else {
                throw AppleSentenceEmbeddingError.unsupportedInputLanguage
            }
            let words = backend.wordCount(for: input)
            guard words > 0, words <= Self.maximumWords else { throw EmbeddingContractError.invalidInput }
        }
        var results: [EmbeddingVector] = []
        for input in inputs {
            await Task.yield()
            try context.validate(scope: scope, model: descriptor)
            guard let values = backend.vector(for: input) else { throw EmbeddingContractError.invalidVector }
            results.append(try EmbeddingVector(values: values.map(Float.init), model: descriptor))
            // Native inference is synchronous; revoked authority discards its output immediately.
            try context.validate(scope: scope, model: descriptor)
        }
        return results
    }
}

/// Non-Sendable by design: the owning actor serializes every framework invocation.
protocol AppleSentenceEmbeddingBackend: AnyObject {
    var languageCode: String { get }
    var revision: Int { get }
    var dimension: Int { get }
    func dominantLanguage(for text: String) -> String?
    func wordCount(for text: String) -> Int
    func vector(for text: String) -> [Double]?
}

private final class NaturalLanguageSentenceEmbeddingBackend: AppleSentenceEmbeddingBackend {
    let languageCode: String
    private let model: NLEmbedding
    var revision: Int { model.revision }
    var dimension: Int { model.dimension }

    init(languageCode: String) throws {
        let language = NLLanguage(rawValue: languageCode)
        let revision = NLEmbedding.currentSentenceEmbeddingRevision(for: language)
        guard revision > 0,
              NLEmbedding.supportedSentenceEmbeddingRevisions(for: language).contains(revision),
              let model = NLEmbedding.sentenceEmbedding(for: language, revision: revision),
              model.language == language, model.dimension > 0 else {
            throw AppleSentenceEmbeddingError.unavailable(languageCode: languageCode)
        }
        self.languageCode = languageCode
        self.model = model
    }

    func dominantLanguage(for text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }

    func wordCount(for text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(NLLanguage(rawValue: languageCode))
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return count <= 128
        }
        return count
    }

    func vector(for text: String) -> [Double]? { model.vector(for: text) }
}
