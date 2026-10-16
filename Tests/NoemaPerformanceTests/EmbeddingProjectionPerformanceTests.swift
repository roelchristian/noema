import Darwin
import Foundation
import Testing
@testable import VaultCore

/// Projection-only measurements. Synthetic vectors do not measure native inference,
/// cloud throughput, queue rendering, or a complete large-vault workflow.
/// Query cursor/fusion measurements live in SemanticRetrievalPerformanceTests;
/// entity-local reuse timing below must never substitute for retrieval acceptance.
struct EmbeddingProjectionPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func benchmarkTenThousandEmbeddingDocumentsAndCancellation() async throws {
        let run = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/semantic-projection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data().write(to: run.appendingPathComponent(".active"))
        defer {
            try? Data().write(to: run.appendingPathComponent(".complete"))
            try? FileManager.default.removeItem(at: run.appendingPathComponent(".active"))
        }
        do { try await measureProjection(in: run) }
        catch {
            try? Data().write(to: run.appendingPathComponent(".failed"))
            throw error
        }
    }

    private func measureProjection(in run: URL) async throws {
        let canonical = run.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try await FileVaultRepository.initializeSchema5(root: canonical, storageProvider: .plaintext)
        let manager = VaultSessionManager()
        let (_, lease, repository) = try await manager.openRepository(root: canonical)
        let support = run.appendingPathComponent("support")
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: lease, accessGate: manager.accessGate)
        let model = try EmbeddingModelDescriptor(providerID: "benchmark", modelID: "synthetic-1536", revision: "1",
            dimensions: 1536, maximumInputUTF8Bytes: 8000, maximumBatchSize: 1)
        let generation = try EmbeddingIndexGeneration(vaultID: lease.vaultID, model: model,
            chunkingVersion: EmbeddingChunker.version)
        let vector = try EmbeddingVector(values: Array(repeating: Float(0.25), count: model.dimensions), model: model)
        let clock = ContinuousClock(), seedStart = clock.now
        var selected: EmbeddingEntityIdentity?
        for number in 0..<10_000 {
            let identity = try EmbeddingEntityIdentity(vaultID: lease.vaultID, entityKind: .page,
                entityID: UUID(), revision: "synthetic-revision")
            let record = try EmbeddingRecord(generation: generation,
                chunk: EmbeddingChunk(identity: identity, chunkID: "block", ordinal: 0,
                    contentFingerprint: "synthetic", chunkingVersion: generation.chunkingVersion), vector: vector)
            try await index.replaceDocument(identity: identity, generation: generation, records: [record], validatePublication: {})
            selected = identity
            if (number + 1).isMultiple(of: 2500) { print("EMBEDDING_PROJECTION_SEED documents=\(number + 1)") }
        }
        let seedSeconds = seconds(seedStart.duration(to: clock.now))
        let target = try #require(selected)
        var samples: [Double] = []
        for _ in 0..<100 {
            let start = clock.now
            let records = try await index.records(generation: generation, entityKind: target.entityKind, entityID: target.entityID)
            samples.append(seconds(start.duration(to: clock.now)) * 1000)
            #expect(records.count == 1 && records[0].chunk.identity == target)
        }
        samples.sort()

        let page = try await repository.create(title: "Cancellation probe", body: "A committed human paragraph about gardens and flowers.")
        let entered = AsyncStream<Void>.makeStream()
        let authority = try EmbeddingPublicationAuthority(accessGate: manager.accessGate, lease: lease, generation: generation)
        let processor = try EmbeddingWorkProcessor(repository: repository, index: index, generation: generation,
            lease: lease, publicationAuthority: authority, dispatch: { _, _, _ in
                entered.continuation.yield(())
                try await Task.sleep(for: .seconds(60))
                throw AIWorkFailure.validation
            }, extractOriginal: { _ in "" }, validateAuthority: {})
        let item = AIWorkItem(key: .init(vaultID: lease.vaultID, entityKind: .page, entityID: page.id,
            processorID: processor.descriptor.identifier), revision: page.contentHash,
            processorVersion: processor.descriptor.version, eligibleAt: Date())
        let snapshot = try await processor.prepare(item, lease: lease)
        let work = Task { try await processor.execute(snapshot, context: .init(lease: lease, validate: {})) }
        for await _ in entered.stream { break }
        let cancelStart = clock.now
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        let cancellationMS = seconds(cancelStart.duration(to: clock.now)) * 1000
        #expect(try await index.records(generation: generation, entityKind: .page, entityID: page.id).isEmpty)
        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        print("EMBEDDING_PROJECTION_BENCHMARK documents=10000 chunks=10000 dimensions=1536 seed_seconds=\(seedSeconds) entity_read_p50_ms=\(samples[49]) entity_read_p95_ms=\(samples[94]) cooperative_cancel_ms=\(cancellationMS) test_process_peak_rss_bytes=\(usage.ru_maxrss)")
        try await repository.shutdownPageStorage()
        try await manager.close()
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
