import Foundation
import Testing
@testable import VaultCore

/// Current production FTS5 implementation; sparse/all-match costs reported separately.
struct SemanticLexicalBaselinePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"), arguments: [1_000, 10_000])
    func benchmarkSemanticRetrievalLexicalBaseline(documents: Int) async throws {
        let run = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/retrieval-lexical-\(UUID())")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data().write(to: run.appendingPathComponent(".active"))
        defer {
            try? Data().write(to: run.appendingPathComponent(".complete"))
            try? FileManager.default.removeItem(at: run.appendingPathComponent(".active"))
        }
        do {
            let session = VaultSession(vaultID: UUID(), root: run.appendingPathComponent("canonical"), generation: 1)
            let gate = VaultAccessGate(initialState: .open(session))
            let index = try SQLiteSearchIndex(url: run.appendingPathComponent("support/search.sqlite"), sessionLease: session.lease, accessGate: gate)
            var batch = ScanBatch()
            for number in 0..<documents {
                batch.notes.append(.init(id: UUID(), title: "Fixture \(number)", aliases: [], tags: [], inlineTags: [],
                    createdAt: "2026-10-16", updatedAt: "2026-10-16", body: "Synthetic paragraph \(number < 20 ? "needle" : "ordinary")",
                    relativePath: "fixture-\(number)", contentHash: "fixture-\(number)", originalHeader: nil))
            }
            try await index.reconcile(batch)
            for (query, expected) in [("needle", 20), ("synthetic", documents)] {
                var samples: [Double] = []
                for _ in 0..<15 {
                    let start = ContinuousClock.now
                    let results = try await index.search(query, kind: .wiki)
                    let duration = start.duration(to: .now).components
                    samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                    #expect(results.count == expected)
                }
                samples.sort()
                print("SEMANTIC_RETRIEVAL_LEXICAL_BASELINE documents=\(documents) matched_results=\(expected) samples=15 p50_ms=\(samples[7]) p95_ms=\(samples[14]) configuration=\(_isDebugAssertConfiguration() ? "debug" : "release") host_load=uncontrolled")
            }
        } catch { try? Data().write(to: run.appendingPathComponent(".failed")); throw error }
    }
}
