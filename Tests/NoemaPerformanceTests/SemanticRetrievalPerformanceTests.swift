import Darwin
import Foundation
import SQLite3
import Synchronization
import Testing
@testable import VaultCore

/// Distinct from projection/indexing benchmarks. Each case owns a disposable derived database.
/// Default five warm samples yield coarse quantiles, not reliable production tail estimates.
struct SemanticRetrievalPerformanceTests {
    private static var enabled: Bool { ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1" }
    private static var widths: [Int] {
        let selected = (ProcessInfo.processInfo.environment["NOEMA_RETRIEVAL_WIDTHS"] ?? "512,1536,3072").split(separator: ",").compactMap { Int($0) }
        return selected.filter { [512, 1536, 3072].contains($0) }
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10)))
    func benchmarkSemanticRetrievalOneThousand() async throws {
        try await measure(documents: 1_000, passages: 1, dimensions: 512, budgetMS: 1_500)
    }
    @Test(.enabled(if: enabled), .timeLimit(.minutes(20)), arguments: widths)
    func benchmarkSemanticRetrievalTenThousand(dimensions: Int) async throws {
        try await measure(documents: 10_000, passages: 1, dimensions: dimensions,
            budgetMS: dimensions == 512 ? 5_000 : dimensions == 1536 ? 10_000 : 20_000)
    }
    @Test(.enabled(if: enabled), .timeLimit(.minutes(20)))
    func benchmarkSemanticRetrievalTenThousandMultiplePassages() async throws {
        try await measure(documents: 10_000, passages: 3, dimensions: 512, budgetMS: 15_000)
    }
    @Test(.enabled(if: enabled), .timeLimit(.minutes(20)))
    func benchmarkSemanticRetrievalLargerStress() async throws {
        try await measure(documents: 20_000, passages: 2, dimensions: 512, budgetMS: 30_000)
    }

    private func measure(documents: Int, passages: Int, dimensions: Int, budgetMS: Double) async throws {
        let run = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/semantic-retrieval-\(UUID())")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data().write(to: run.appendingPathComponent(".active"))
        defer {
            try? Data().write(to: run.appendingPathComponent(".complete"))
            try? FileManager.default.removeItem(at: run.appendingPathComponent(".active"))
        }
        do { try await probe(run: run, documents: documents, passages: passages, dimensions: dimensions, budgetMS: budgetMS) }
        catch { try? Data().write(to: run.appendingPathComponent(".failed")); throw error }
    }

    private func probe(run: URL, documents: Int, passages: Int, dimensions: Int, budgetMS: Double) async throws {
        let session = VaultSession(vaultID: UUID(), root: run.appendingPathComponent("canonical"), generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let support = run.appendingPathComponent("support")
        let index = try SQLiteEmbeddingIndex(applicationSupportRoot: support, lease: session.lease, accessGate: gate)
        let model = try EmbeddingModelDescriptor(providerID: "retrieval-benchmark", modelID: "synthetic-\(dimensions)",
            revision: "1", dimensions: dimensions, maximumInputUTF8Bytes: 8000, maximumBatchSize: 16)
        let generation = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
        try await index.declareGeneration(generation: generation)
        var values = Array(repeating: Float(0.25), count: dimensions); values[0] = 1
        let query = try EmbeddingVector(values: values, model: model)
        let seedStart = ContinuousClock.now
        let database = support.appendingPathComponent("KnowledgeVault/\(session.vaultID.uuidString)/semantic.sqlite")
        try seed(database: database, generation: generation, vector: query, documents: documents, passages: passages)
        // All three real vector widths coexist with persisted rows; query only the selected space.
        for width in [512, 1536, 3072] where width != dimensions {
            let otherModel = try EmbeddingModelDescriptor(providerID: "retrieval-benchmark", modelID: "foreign-\(width)",
                revision: "2", dimensions: width, maximumInputUTF8Bytes: 8000, maximumBatchSize: 16)
            let other = try EmbeddingIndexGeneration(vaultID: session.vaultID, model: otherModel, chunkingVersion: EmbeddingChunker.version)
            try await index.declareGeneration(generation: other)
            try seed(database: database, generation: other,
                vector: EmbeddingVector(values: Array(repeating: 1, count: width), model: otherModel), documents: 2, passages: 2)
        }
        let seedMS = milliseconds(seedStart.duration(to: .now))
        let sampleCount = max(1, min(30, Int(ProcessInfo.processInfo.environment["NOEMA_RETRIEVAL_SAMPLES"] ?? "5") ?? 5))
        let rssBefore = try residentBytes(), sampledPeak = Mutex(try residentBytes())
        let stopSampler = Mutex(false)
        let sampler = Task.detached {
            while !stopSampler.withLock({ $0 }) {
                if let rss = try? residentBytes() { sampledPeak.withLock { $0 = max($0, rss) } }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let heartbeat = Mutex(0.0)
        let stopHeartbeat = Mutex(false)
        let heartbeatTask = Task { @MainActor in
            var previous = ContinuousClock.now
            while !stopHeartbeat.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                heartbeat.withLock { $0 = max($0, milliseconds(previous.duration(to: now))) }
                previous = now
            }
        }
        defer {
            stopSampler.withLock { $0 = true }; stopHeartbeat.withLock { $0 = true }
            sampler.cancel(); heartbeatTask.cancel()
        }
        var usageBefore = rusage(), usageAfter = rusage()
        #expect(getrusage(RUSAGE_SELF, &usageBefore) == 0)
        var samples: [Double] = [], fusion: [Double] = []
        var coldMS = 0.0
        for iteration in 0...sampleCount {
            let started = ContinuousClock.now
            let candidates = try await index.searchCandidates(query: query, generation: generation,
                documentLimit: 20, passagesPerDocument: 3, isCurrent: { _ in true }, validateQuery: {})
            let elapsed = milliseconds(started.duration(to: .now))
            if iteration == 0 { coldMS = elapsed } else { samples.append(elapsed) }
            #expect(candidates.count == 20)
            #expect(candidates.allSatisfy { $0.generation == generation && $0.completion.chunkCount == passages })
            let semantic = candidates.map { HybridSemanticCandidate(candidate: $0, title: "Synthetic \($0.identity.entityID)") }
            let fusionStart = ContinuousClock.now
            let ranked = try HybridSearchRanking.fuse(query: "synthetic", lexical: [], semantic: semantic, generation: generation)
            fusion.append(milliseconds(fusionStart.duration(to: .now)))
            #expect(ranked.count == 20)
        }
        // One scan queues a competing index operation, exposing actor scheduling wait.
        let entered = AsyncStream<Void>.makeStream(), signal = Mutex(false)
        let competingSearch = Task {
            try await index.searchCandidates(query: query, generation: generation,
                documentLimit: 20, isCurrent: { _ in true }, validateQuery: {
                    signal.withLock { if !$0 { $0 = true; entered.continuation.yield(()) } }
                })
        }
        for await _ in entered.stream { break }
        let queueStart = ContinuousClock.now
        try await index.declareGeneration(generation: generation)
        let actorWaitMS = milliseconds(queueStart.duration(to: .now))
        _ = try await competingSearch.value

        // Cancellation is delivered from outside the synchronous index actor traversal.
        let cancellationEntered = AsyncStream<Void>.makeStream(), checks = Mutex(0)
        let cancellable = Task {
            try await index.searchCandidates(query: query, generation: generation,
                documentLimit: 20, isCurrent: { _ in true }, validateQuery: {
                    checks.withLock { $0 += 1; if $0 == 100 { cancellationEntered.continuation.yield(()) } }
                })
        }
        for await _ in cancellationEntered.stream { break }
        let cancelStart = ContinuousClock.now
        cancellable.cancel()
        await #expect(throws: CancellationError.self) { try await cancellable.value }
        let cancelMS = milliseconds(cancelStart.duration(to: .now))
        stopSampler.withLock { $0 = true }; stopHeartbeat.withLock { $0 = true }
        await sampler.value; await heartbeatTask.value
        #expect(getrusage(RUSAGE_SELF, &usageAfter) == 0)
        let rssAfter = try residentBytes(), peak = sampledPeak.withLock { $0 }
        let incremental = peak > rssBefore ? peak - rssBefore : 0
        let p50 = quantile(samples, 0.5), p95 = quantile(samples, 0.95), fusion95 = quantile(fusion, 0.95)
        let gap = heartbeat.withLock { $0 }
        let withinBudget = p95 <= budgetMS && fusion95 <= 50 && cancelMS <= 250 && incremental <= 64 * 1024 * 1024 && gap <= 100
        print("SEMANTIC_RETRIEVAL_REFERENCE configuration=\(_isDebugAssertConfiguration() ? "debug" : "release") os=\(ProcessInfo.processInfo.operatingSystemVersionString) samples=\(sampleCount) host_load=uncontrolled")
        print("SEMANTIC_RETRIEVAL_BENCHMARK documents=\(documents) passages=\(documents * passages) dimensions=\(dimensions) seed_ms=\(seedMS) cold_ms=\(coldMS) warm_p50_ms=\(p50) warm_p95_ms=\(p95) fusion_p95_ms=\(fusion95) cancel_ms=\(cancelMS) competing_index_wait_ms=\(actorWaitMS) main_actor_gap_ms=\(gap) rss_before_bytes=\(rssBefore) sampled_peak_rss_bytes=\(peak) rss_after_bytes=\(rssAfter) query_incremental_rss_bytes=\(incremental) process_peak_rss_bytes=\(usageAfter.ru_maxrss) process_inblock_delta=\(usageAfter.ru_inblock - usageBefore.ru_inblock) process_oublock_delta=\(usageAfter.ru_oublock - usageBefore.ru_oublock) expected_vector_decodes_per_scan=\(documents * passages) expected_vector_bytes_per_scan=\(documents * passages * dimensions * 4) target_p95_ms=\(budgetMS) targets_met=\(withinBudget)")
        if !withinBudget { try Data("Declared reference budget missed; retain benchmark diagnostics.\n".utf8).write(to: run.appendingPathComponent(".failed")) }
        if ProcessInfo.processInfo.environment["NOEMA_ENFORCE_RETRIEVAL_BUDGETS"] == "1" { #expect(withinBudget, "Reference retrieval target exceeded; retain diagnostics") }
        gate.updateState(.closed)
    }

    /// Fixture-only writer, closed before retrieval; production always uses the actor connection.
    private func seed(database: URL, generation: EmbeddingIndexGeneration, vector: EmbeddingVector,
                      documents: Int, passages: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else { throw EmbeddingIndexError.unavailable }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw EmbeddingIndexError.unavailable }
        var finished = false
        defer { if !finished { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        var chunk: OpaquePointer?, document: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO embedding_chunks VALUES(?,?,?,?,?,?,?)", -1, &chunk, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO embedding_documents VALUES(?,?,?,?,?)", -1, &document, nil) == SQLITE_OK,
              let chunk, let document else { throw EmbeddingIndexError.unavailable }
        defer { sqlite3_finalize(chunk); sqlite3_finalize(document) }
        func text(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
            _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        func blob(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
            _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        let bytes = vector.encodedFloat32LittleEndian()
        for number in 0..<documents {
            try autoreleasepool {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number + 1))!
            let kind = number.isMultiple(of: 2) ? "page" : "source"
            var fingerprints: [String] = []
            for ordinal in 0..<passages {
                let locator = kind == "page" ? "block/\(id.uuidString)/\(ordinal)" : "paragraph/\(ordinal)/0"
                fingerprints.append(locator + ":synthetic")
                let metadata = try JSONSerialization.data(withJSONObject: ["entityKind": kind, "entityID": id.uuidString,
                    "revision": "benchmark-r1", "chunkID": locator, "fingerprint": "synthetic", "chunkingVersion": generation.chunkingVersion, "ordinal": ordinal])
                sqlite3_reset(chunk); sqlite3_clear_bindings(chunk)
                text(chunk, 1, generation.id.uuidString); text(chunk, 2, kind); text(chunk, 3, id.uuidString)
                text(chunk, 4, locator); sqlite3_bind_int64(chunk, 5, Int64(ordinal)); blob(chunk, 6, metadata); blob(chunk, 7, bytes)
                guard sqlite3_step(chunk) == SQLITE_DONE else { throw EmbeddingIndexError.unavailable }
            }
            let metadata = try JSONSerialization.data(withJSONObject: ["entityKind": kind, "entityID": id.uuidString,
                "revision": "benchmark-r1", "workRevision": "benchmark-r1", "inputFingerprint": digest(Data(fingerprints.joined(separator: "\n").utf8)), "chunkCount": passages])
            sqlite3_reset(document); sqlite3_clear_bindings(document)
            text(document, 1, generation.id.uuidString); text(document, 2, kind); text(document, 3, id.uuidString)
            sqlite3_bind_int64(document, 4, Int64(passages)); blob(document, 5, metadata)
            guard sqlite3_step(document) == SQLITE_DONE else { throw EmbeddingIndexError.unavailable }
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw EmbeddingIndexError.unavailable }
        finished = true
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}
private func quantile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
}
private func residentBytes() throws -> UInt64 {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw EmbeddingIndexError.unavailable }
    return info.resident_size
}
