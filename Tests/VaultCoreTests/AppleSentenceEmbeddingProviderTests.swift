import Foundation
import Synchronization
import Testing
@testable import VaultCore

private final class SentenceTestBackend: AppleSentenceEmbeddingBackend {
    let languageCode: String
    let revision: Int
    let dimension: Int
    let detect: @Sendable (String) -> String?
    let words: @Sendable (String) -> Int
    let infer: @Sendable (String) -> [Double]?
    init(language: String = "en", revision: Int = 7, dimension: Int = 3,
         detect: @escaping @Sendable (String) -> String? = { _ in "en" },
         words: @escaping @Sendable (String) -> Int = { _ in 4 },
         infer: @escaping @Sendable (String) -> [Double]? = { _ in [1, 0, -1] }) {
        self.languageCode = language; self.revision = revision; self.dimension = dimension
        self.detect = detect; self.words = words; self.infer = infer
    }
    func dominantLanguage(for text: String) -> String? { detect(text) }
    func wordCount(for text: String) -> Int { words(text) }
    func vector(for text: String) -> [Double]? { infer(text) }
}

private func sentenceContext(_ provider: AppleSentenceEmbeddingProvider,
                             validate: @escaping @Sendable () throws -> Void = {}) throws
    -> (EmbeddingProcessingScope, EmbeddingExecutionContext) {
    let vault = UUID()
    let scope = EmbeddingProcessingScope.query(vaultID: vault, queryID: UUID())
    let lease = VaultSessionLease(vaultID: vault, root: URL(fileURLWithPath: "/tmp/native-embedding"), generation: 1)
    return (scope, try EmbeddingExecutionContext(lease: lease, scope: scope,
                                                model: provider.descriptor, validateCurrentAuthority: validate))
}

@Test func appleSentenceProviderRecordsActualMetadataAndPreservesInputOrder() async throws {
    let provider = try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(infer: { text in
        text == "first" ? [1, 0, 0] : [0, 1, 0]
    }))
    #expect(provider.descriptor.providerID == "apple-natural-language")
    #expect(provider.descriptor.modelID == "sentence-en-input-v1")
    #expect(provider.descriptor.revision == "7")
    #expect(provider.descriptor.dimensions == 3)
    let (scope, context) = try sentenceContext(provider)
    let vectors = try await provider.embed(["first", "second"], scope: scope, context: context)
    #expect(vectors.map(\.values) == [[1, 0, 0], [0, 1, 0]])
    #expect(vectors.allSatisfy { $0.model == provider.descriptor })
}

@Test func appleSentenceProviderUnavailableMetadataFailsClosed() throws {
    #expect(throws: AppleSentenceEmbeddingError.unavailable(languageCode: "en")) {
        try AppleSentenceEmbeddingProvider(backend: nil)
    }
    #expect(throws: AppleSentenceEmbeddingError.unavailable(languageCode: "en")) {
        try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(language: "fr"))
    }
    #expect(throws: EmbeddingContractError.invalidModel) {
        try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(revision: 0))
    }
    #expect(throws: EmbeddingContractError.invalidModel) {
        try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(dimension: 0))
    }
}

@Test func appleSentenceProviderRejectsUnsupportedLanguageBeforeInference() async throws {
    let calls = Mutex(0)
    let provider = try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(
        detect: { $0 == "French" ? "fr" : nil }, infer: { _ in calls.withLock { $0 += 1 }; return [1, 0, 0] }))
    let (scope, context) = try sentenceContext(provider)
    for input in ["French", "unknown"] {
        await #expect(throws: AppleSentenceEmbeddingError.unsupportedInputLanguage) {
            try await provider.embed([input], scope: scope, context: context)
        }
    }
    #expect(calls.withLock { $0 } == 0)
}

@Test func appleSentenceProviderEnforcesUTF8BatchAndWordLimits() async throws {
    let calls = Mutex(0)
    let provider = try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(
        words: { $0 == "too many words" ? 129 : 4 },
        infer: { _ in calls.withLock { $0 += 1 }; return [1, 0, 0] }))
    let (scope, context) = try sentenceContext(provider)
    for input in [[], [" "], [String(repeating: "é", count: 513)],
                  Array(repeating: "hello", count: 17), ["first", "too many words"]] {
        await #expect(throws: EmbeddingContractError.invalidInput) {
            try await provider.embed(input, scope: scope, context: context)
        }
    }
    #expect(calls.withLock { $0 } == 0)
}

@Test func appleSentenceProviderRejectsNilInvalidAndOverflowingVectors() async throws {
    for vector: [Double]? in [nil, [0, 0, 0], [1, 2], [.nan, 1, 0], [.infinity, 1, 0],
                             [Double.greatestFiniteMagnitude, 1, 0]] {
        let provider = try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(infer: { _ in vector }))
        let (scope, context) = try sentenceContext(provider)
        await #expect(throws: EmbeddingContractError.invalidVector) {
            try await provider.embed(["hello"], scope: scope, context: context)
        }
    }
}

@Test func appleSentenceProviderRejectsRevocationAfterNativeInference() async throws {
    let allowed = Mutex(true)
    let provider = try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(infer: { _ in
        allowed.withLock { $0 = false }
        return [1, 0, 0]
    }))
    let (scope, context) = try sentenceContext(provider) {
        guard allowed.withLock({ $0 }) else { throw EmbeddingContractError.authorityDenied }
    }
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await provider.embed(["hello"], scope: scope, context: context)
    }
}

@Test func appleSentenceProviderRejectsCrossScopeAndCancelledTasks() async throws {
    let calls = Mutex(0)
    let provider = try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend(infer: { _ in
        calls.withLock { $0 += 1 }; return [1, 0, 0]
    }))
    let (scope, context) = try sentenceContext(provider)
    await #expect(throws: EmbeddingContractError.authorityDenied) {
        try await provider.embed(["hello"], scope: .query(vaultID: UUID(), queryID: UUID()), context: context)
    }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await provider.embed(["hello"], scope: scope, context: context)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(calls.withLock { $0 } == 0)
}

@Test func appleSentenceOutputPersistsAndReopensThroughCommonIndex() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/sem-emb-sqlite-tests/fixtures/\(UUID())")
    let session = VaultSession(vaultID: UUID(), root: root.appendingPathComponent("canonical"), generation: 1)
    let gate = VaultAccessGate()
    gate.updateState(.open(session))
    let provider = try AppleSentenceEmbeddingProvider(backend: SentenceTestBackend())
    let generation = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: provider.descriptor,
                                                   chunkingVersion: "native-test-1")
    let identity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page,
                                              entityID: UUID(), revision: "committed-r1")
    let scope = EmbeddingProcessingScope.document(identity)
    let context = try EmbeddingExecutionContext(lease: session.lease, scope: scope, model: provider.descriptor) {
        try gate.validate(lease: session.lease, targetRoot: session.root, targetVaultID: session.vaultID,
                          operation: "embedding.native.test")
    }
    let vector = try #require(await provider.embed(["hello"], scope: scope, context: context).first)
    let chunk = try EmbeddingChunk(identity: identity, chunkID: "block-1", ordinal: 0,
                                    contentFingerprint: "input-fingerprint", chunkingVersion: generation.chunkingVersion)
    let record = try EmbeddingRecord(generation: generation, chunk: chunk, vector: vector)
    let support = root.appendingPathComponent("support")
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: session.lease, accessGate: gate)
    try await index.replaceDocument(identity: identity, generation: generation, records: [record]) {
        try context.validate(scope: scope, model: provider.descriptor)
    }
    let reopened = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: session.lease, accessGate: gate)
    #expect(try await reopened.records(generation: generation) == [record])
    gate.updateState(.closed)
    await #expect(throws: (any Error).self) {
        try await reopened.records(generation: generation)
    }
}
