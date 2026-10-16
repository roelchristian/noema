import Foundation
import NaturalLanguage
import Testing
@testable import VaultCore

/// Labels are fixed before inference. Synthetic vectors test implementation, never model quality.
private struct RetrievalQualityCorpus {
    struct Document { let title: String; let passages: [String]; let topic: Int }
    struct Query { let text: String; let topic: Int; let relevant: [Int: Int] }
    static let documents: [Document] = [
        .init(title: "Clinical care", passages: ["A doctor treats patients at a hospital and provides medical care."], topic: 0),
        .init(title: "Community medicine", passages: ["A physician gives patients medical treatment in a neighborhood clinic.", "A nurse helps patients recover with clinical treatment and supportive medical care.", "Doctors and nurses work together to treat illness and relieve patient suffering."], topic: 0),
        .init(title: "Kitchen garden", passages: ["A gardener grows tomatoes and roses in rich soil with sunlight and water."], topic: 1),
        .init(title: "Growing vegetables", passages: ["Seeds sprout into vegetables when gardeners irrigate the soil and remove weeds."], topic: 1),
        .init(title: "Lunar expedition", passages: ["Astronauts travel in spacecraft to explore the moon and distant planets."], topic: 2),
        .init(title: "Planetary science", passages: ["An observatory studies stars and planets with powerful telescopes."], topic: 2),
        .init(title: "Database transactions", passages: ["Database transactions preserve atomicity and consistency when committed records change."], topic: 3),
        .init(title: "ACID recovery", passages: ["A write ahead log lets a database recover committed transactions after interruption."], topic: 3),
        .init(title: "Mixed field notes", passages: (0..<14).map { $0.isMultiple(of: 2) ? "A surgeon provides urgent medical care to injured patients." : "A telescope observes distant stars and galaxies." }, topic: 0),
        .init(title: "Bread recipe", passages: ["A baker mixes flour and yeast before kneading dough and baking bread."], topic: 4)
    ]
    static let queries: [Query] = [
        .init(text: "How does a physician help sick people recover?", topic: 0, relevant: [0: 3, 1: 3, 8: 2]),
        .init(text: "How can I cultivate vegetables in my backyard?", topic: 1, relevant: [2: 3, 3: 3]),
        .init(text: "What allows people to explore outer space?", topic: 2, relevant: [4: 3, 5: 2, 8: 1]),
        .init(text: "How are committed records recovered after a database crash?", topic: 3, relevant: [6: 2, 7: 3]),
        .init(text: "How do I prepare a loaf using flour and yeast?", topic: 4, relevant: [9: 3]),
        .init(text: "Database transactions", topic: 3, relevant: [6: 3, 7: 2]),
        .init(text: "How do ACID transactions recover committed records after a failure?", topic: 3, relevant: [6: 2, 7: 3]),
        .init(text: "What kind of care helps recovery?", topic: 0, relevant: [0: 3, 1: 3, 8: 2])
    ]
    static func identity(_ number: Int, vault: UUID) throws -> EmbeddingEntityIdentity {
        try .init(vaultID: vault, entityKind: number.isMultiple(of: 2) ? .page : .source,
            entityID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number + 1))!, revision: "quality-r1")
    }
}

private struct RetrievalQualityMetrics {
    let recall: Double, reciprocalRank: Double, ndcg: Double
    init(order: [Int], relevant: [Int: Int], k: Int) {
        let top = Array(order.prefix(k))
        recall = Double(Set(top).intersection(relevant.keys).count) / Double(relevant.count)
        reciprocalRank = order.firstIndex(where: { relevant[$0] != nil }).map { 1 / Double($0 + 1) } ?? 0
        func dcg(_ grades: [Int]) -> Double {
            grades.enumerated().reduce(0) { $0 + (pow(2, Double($1.element)) - 1) / log2(Double($1.offset + 2)) }
        }
        let ideal = dcg(Array(relevant.values.sorted(by: >).prefix(k)))
        ndcg = ideal == 0 ? 0 : dcg(top.map { relevant[$0] ?? 0 }) / ideal
    }
}

private func qualityRank(query: RetrievalQualityCorpus.Query, vectors: [[EmbeddingVector]],
                         queryVector: EmbeddingVector, generation: EmbeddingIndexGeneration) throws -> [Int] {
    let documents = RetrievalQualityCorpus.documents
    let semantic = try documents.indices.map { number -> HybridSemanticCandidate in
        let identity = try RetrievalQualityCorpus.identity(number, vault: generation.vaultID)
        let passages = try vectors[number].enumerated().map { ordinal, vector in
            let locator = identity.entityKind == .page ? "block/\(identity.entityID.uuidString)/\(ordinal)" : "paragraph/\(ordinal)/0"
            return try SemanticSearchPassage(chunk: .init(identity: identity, chunkID: locator, ordinal: ordinal,
                contentFingerprint: "labelled-\(number)-\(ordinal)", chunkingVersion: generation.chunkingVersion),
                cosineSimilarity: queryVector.cosineSimilarity(to: vector))
        }
        return try .init(candidate: .init(generation: generation,
            completion: .init(identity: identity, workRevision: "quality-r1", inputFingerprint: "labelled", chunkCount: passages.count),
            passages: passages), title: documents[number].title)
    }
    // This intentionally sparse channel isolates paraphrase discovery from incidental token overlap.
    let lexical = try documents.indices.filter { normalized(documents[$0].title) == normalized(query.text) }.map {
        try HybridLexicalCandidate(identity: RetrievalQualityCorpus.identity($0, vault: generation.vaultID), title: documents[$0].title, rank: 1)
    }
    let identities = try documents.indices.map { try RetrievalQualityCorpus.identity($0, vault: generation.vaultID) }
    return try HybridSearchRanking.fuse(query: query.text, lexical: lexical, semantic: semantic, generation: generation)
        .map { result in identities.firstIndex(of: result.identity)! }
}

@Test func semanticRetrievalQualityMetricsAccountForMissingAndMisorderedEvidence() {
    let imperfect = RetrievalQualityMetrics(order: [9, 1, 0], relevant: [0: 3, 1: 1], k: 2)
    #expect(imperfect.recall == 0.5)
    #expect(imperfect.reciprocalRank == 0.5)
    #expect(imperfect.ndcg > 0 && imperfect.ndcg < 0.1)
    let absent = RetrievalQualityMetrics(order: [9], relevant: [0: 3], k: 3)
    #expect(absent.recall == 0 && absent.reciprocalRank == 0 && absent.ndcg == 0)
}

@Test func semanticRetrievalLabelledSyntheticCorpusQualityAndDiversification() throws {
    let model = try EmbeddingModelDescriptor(providerID: "quality-synthetic", modelID: "topic-axes", revision: "1",
        dimensions: 5, maximumInputUTF8Bytes: 1024, maximumBatchSize: 16)
    let generation = try EmbeddingIndexGeneration(vaultID: UUID(), model: model, chunkingVersion: EmbeddingChunker.version)
    func axis(_ topic: Int) throws -> EmbeddingVector {
        var values = Array(repeating: Float(0), count: 5); values[topic] = 1
        return try .init(values: values, model: model)
    }
    let vectors = try RetrievalQualityCorpus.documents.enumerated().map { number, doc in
        try doc.passages.indices.map { try axis(number == 8 && !$0.isMultiple(of: 2) ? 2 : doc.topic) }
    }
    var metrics: [RetrievalQualityMetrics] = []
    for (number, query) in RetrievalQualityCorpus.queries.enumerated() {
        let order = try qualityRank(query: query, vectors: vectors, queryVector: axis(query.topic), generation: generation)
        #expect(Set(order).count == order.count)
        let value = RetrievalQualityMetrics(order: order, relevant: query.relevant, k: 3)
        metrics.append(value)
        #expect(value.recall == 1, "Synthetic labelled query \(number) missed relevant evidence")
        #expect(value.reciprocalRank == 1)
        print("SYNTHETIC_RETRIEVAL_QUALITY query=\(number) recall_at_3=\(value.recall) mrr=\(value.reciprocalRank) ndcg_at_3=\(value.ndcg)")
    }
    #expect(metrics.count == RetrievalQualityCorpus.queries.count)
}

/// Installed model quality is distinct from deterministic algorithm correctness.
/// Predeclared modest acceptance: mean Recall@3 >= 0.5, MRR >= 0.5 on this small labelled corpus.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_NATIVE_EMBEDDING_ACCEPTANCE"] == "1"))
func productionSentenceEmbeddingLabelledRetrievalQuality() async throws {
    let provider = try AppleSentenceEmbeddingProvider(languageCode: "en")
    let vault = UUID()
    let lease = VaultSessionLease(vaultID: vault, root: URL(fileURLWithPath: "/tmp/native-quality"), generation: 1)
    let scope = EmbeddingProcessingScope.query(vaultID: lease.vaultID, queryID: UUID())
    let context = try EmbeddingExecutionContext(lease: lease, scope: scope, model: provider.descriptor, validateCurrentAuthority: {})
    let generation = try EmbeddingIndexGeneration(vaultID: vault, model: provider.descriptor, chunkingVersion: EmbeddingChunker.version)
    var vectors: [[EmbeddingVector]] = []
    for doc in RetrievalQualityCorpus.documents { vectors.append(try await provider.embed(doc.passages, scope: scope, context: context)) }
    var values: [RetrievalQualityMetrics] = []
    for (number, query) in RetrievalQualityCorpus.queries.enumerated() {
        let inferenceStart = ContinuousClock.now
        let queryVector = try #require(await provider.embed([query.text], scope: scope, context: context).first)
        let elapsed = inferenceStart.duration(to: .now).components
        let inferenceMS = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let order = try qualityRank(query: query, vectors: vectors, queryVector: queryVector, generation: generation)
        let metric = RetrievalQualityMetrics(order: order, relevant: query.relevant, k: 3)
        values.append(metric)
        let missed = query.relevant.keys.filter { !order.prefix(3).contains($0) }.sorted()
        print("NATIVE_RETRIEVAL_QUALITY query=\(number) query_embedding_ms=\(inferenceMS) recall_at_3=\(metric.recall) mrr=\(metric.reciprocalRank) ndcg_at_3=\(metric.ndcg) missed_fixture_ids=\(missed)")
    }
    let recall = values.map(\.recall).reduce(0, +) / Double(values.count)
    let mrr = values.map(\.reciprocalRank).reduce(0, +) / Double(values.count)
    let ndcg = values.map(\.ndcg).reduce(0, +) / Double(values.count)
    print("NATIVE_RETRIEVAL_QUALITY_SUMMARY revision=\(provider.descriptor.revision) dimensions=\(provider.descriptor.dimensions) queries=\(values.count) mean_recall_at_3=\(recall) mrr=\(mrr) mean_ndcg_at_3=\(ndcg)")
    #expect(recall >= 0.5); #expect(mrr >= 0.5)
    await #expect(throws: AppleSentenceEmbeddingError.unsupportedInputLanguage) {
        try await provider.embed(["Le jardinier cultive des légumes et arrose les fleurs dans son jardin."], scope: scope, context: context)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_NATIVE_EMBEDDING_ACCEPTANCE"] == "1"))
func productionSentenceEmbeddingRejectsJapaneseAndOversizedInputWithoutTruncation() async throws {
    let provider = try AppleSentenceEmbeddingProvider(languageCode: "en")
    let lease = VaultSessionLease(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/native-quality-limits"), generation: 1)
    let scope = EmbeddingProcessingScope.query(vaultID: lease.vaultID, queryID: UUID())
    let context = try EmbeddingExecutionContext(lease: lease, scope: scope, model: provider.descriptor, validateCurrentAuthority: {})
    await #expect(throws: AppleSentenceEmbeddingError.unsupportedInputLanguage) {
        try await provider.embed(["これは日本語で書かれた文章です。庭の花や野菜について説明しています。"], scope: scope, context: context)
    }
    let excessiveBytes = String(repeating: "a", count: provider.descriptor.maximumInputUTF8Bytes + 1)
    await #expect(throws: EmbeddingContractError.invalidInput) {
        try await provider.embed([excessiveBytes], scope: scope, context: context)
    }
    let excessiveWords = String(repeating: "This is an English sentence about care and recovery. ", count: 15)
    #expect(excessiveWords.utf8.count <= provider.descriptor.maximumInputUTF8Bytes)
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.setLanguage(.english); tokenizer.string = excessiveWords
    var words = 0
    tokenizer.enumerateTokens(in: excessiveWords.startIndex..<excessiveWords.endIndex) { _, _ in words += 1; return true }
    #expect(words > 128)
    await #expect(throws: EmbeddingContractError.invalidInput) {
        try await provider.embed([excessiveWords], scope: scope, context: context)
    }
    print("NATIVE_RETRIEVAL_INPUT_ACCEPTANCE provider=\(provider.descriptor.providerID) model=\(provider.descriptor.modelID) revision=\(provider.descriptor.revision) dimensions=\(provider.descriptor.dimensions) byte_limit=\(provider.descriptor.maximumInputUTF8Bytes) oversized_bytes=\(excessiveBytes.utf8.count) word_limit=128 oversized_words=\(words) unsupported_language=ja oversized_inputs_rejected_without_vectors=true")
}
