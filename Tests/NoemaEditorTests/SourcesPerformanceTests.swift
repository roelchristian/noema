import Foundation
import Testing
@testable import VaultCore
@testable import noema

struct SourcesPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOURCES_BENCHMARK"] == "1"))
    @MainActor func benchmarkSixteenSourceRowsAndUnchangedUpdates() throws {
        let text = String(repeating: "A paragraph of source content that is not required for metadata display.\n\n", count: 1800)
        let sources = (0..<16).map { index in
            SourceRecord(metadata: SourceMetadata(id: UUID(), title: "Source \(index)", capturedAt: "2026-10-11T12:00:00Z", originalFilename: "source-\(index).txt", sha256: "fixture", fileSize: text.utf8.count, storedFilename: "original.txt"), body: text)
        }
        let clock = ContinuousClock()
        let legacy = clock.measure {
            for source in sources {
                let excerpt = BlockDocumentCodec.decode(source.body).flattened.map(\.text).joined(separator: " ")
                #expect(!excerpt.isEmpty)
            }
        }
        let construction = clock.measure {
            let rows = sources.map(LibraryRow.init(source:))
            #expect(rows.count == 16 && rows.allSatisfy { $0.excerpt.isEmpty })
        }
        var builds = 0
        let presentation = SourcesTablePresentation { input in
            builds += 1
            return SourceTableRow(input: input)
        }
        let initial = clock.measure { presentation.synchronize(sources) }
        let unchanged = clock.measure {
            for _ in 0..<1000 { #expect(!presentation.synchronize(sources)) }
        }
        #expect(builds == 16)
        print("SOURCES_BENCHMARK 16 sources, \(text.utf8.count) bytes/body: legacy excerpt decode=\(legacy), metadata LibraryRows=\(construction), initial table prepare/sort=\(initial), 1000 unchanged synchronizations=\(unchanged), constructed rows=\(builds)")
    }
}
