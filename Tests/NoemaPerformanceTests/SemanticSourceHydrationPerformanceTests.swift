import Foundation
import Testing
@testable import VaultCore

/// Bounded winner hydration only; excludes UI previews, linked files and query inference.
struct SemanticSourceHydrationPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func benchmarkSemanticRetrievalSourceHydration() async throws {
        let run = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/retrieval-source-hydration-\(UUID())")
        let canonical = run.appendingPathComponent("canonical")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try Data().write(to: run.appendingPathComponent(".active"))
        defer {
            try? Data().write(to: run.appendingPathComponent(".complete"))
            try? FileManager.default.removeItem(at: run.appendingPathComponent(".active"))
        }
        do {
            try await FileVaultRepository.initializeSchema5(root: canonical, storageProvider: .plaintext)
            let manager = VaultSessionManager()
            let (_, _, repository) = try await manager.openRepository(root: canonical)
            let text = String(repeating: "A scientific paragraph describes stars and planets in the distant universe.\n\n", count: 8_000)
            let original = Data(text.utf8)
            let source = try await repository.importSource(data: original, filename: "large.txt", title: "Synthetic source", originURL: nil)
            let inventory = try await repository.aiProcessingInventory()
            let revision = try #require(inventory.first { $0.entityID == source.id && $0.entityKind == .source }?.revision)
            let model = try EmbeddingModelDescriptor(providerID: "hydration-benchmark", modelID: "synthetic-512", revision: "1",
                dimensions: 512, maximumInputUTF8Bytes: 8000, maximumBatchSize: 16)
            var samples: [Double] = []
            var chunks = 0
            for _ in 0..<5 {
                let started = ContinuousClock.now
                let snapshot = try await repository.embeddingSourceSnapshot(id: source.id, expectedRevision: revision, model: model,
                    extractOriginal: { snapshot in String(decoding: snapshot.original, as: UTF8.self) })
                try await repository.validateEmbeddingSnapshot(snapshot)
                let components = started.duration(to: .now).components
                samples.append(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
                chunks = snapshot.inputs.count
                #expect(snapshot.inputs.first?.text.contains("scientific") == true)
            }
            samples.sort()
            print("SEMANTIC_RETRIEVAL_SOURCE_HYDRATION original_bytes=\(original.count) prepared_passages=\(chunks) samples=5 p50_ms=\(samples[2]) p95_ms=\(samples[4]) includes_original_read_extraction_chunking_revalidation=true excludes_visible_preview_linked_files=true vault=synthetic")
            try await repository.shutdownPageStorage()
            try await manager.close()
            #expect(chunks > 0)
        } catch { try? Data().write(to: run.appendingPathComponent(".failed")); throw error }
    }
}
