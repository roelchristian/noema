import Foundation
import Testing
@testable import VaultCore
@testable import noema

@Suite("Inspector Links benchmark")
@MainActor
struct InspectorLinksPerformanceTests {
    private func note(id: UUID = UUID(), title: String, aliases: [String] = [], body: String = "") -> NoteRecord {
        NoteRecord(
            id: id, title: title, aliases: aliases, tags: [], inlineTags: [],
            createdAt: "2026-10-12T00:00:00Z", updatedAt: "2026-10-12T00:00:00Z",
            body: body, relativePath: "Wiki/\(id).md", contentHash: "fixture", originalHeader: nil
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"))
    func benchmarkActualLinksPresentationPathWithFiveThousandPages() {
        let notes = (0..<5_000).map { index in
            note(title: "Research Page \(index)", aliases: ["Legacy Topic \(index)", "Citation \(index)"], body: "A body that the resolver never reads.")
        }
        let pageID = notes[0].id
        let clock = ContinuousClock()
        for count in [12, 60] {
            let targets = (0..<count).map { "Legacy Topic \($0 * 71)" }
            let cache = LinksPresentationCache()
            var cold: LinksPanelModel?
            let coldDuration = clock.measure {
                cold = cache.model(pageID: pageID, backlinks: [notes[1]], outgoingLinkTargets: targets, allNotes: notes)
            }
            var resultCount = 0
            let repeatedDuration = clock.measure {
                for _ in 0..<200 {
                    let model = cache.model(pageID: pageID, backlinks: [notes[1]], outgoingLinkTargets: targets, allNotes: notes)
                    resultCount += model.outgoingLinks.count
                }
            }
            #expect(cold?.outgoingLinks.count == count)
            #expect(cold?.outgoingLinks.allSatisfy { if case .resolved = $0.resolution { return true }; return false } == true)
            #expect(resultCount == count * 200)
            #expect(cache.lookupBuildCount == 1)
            #expect(cache.resolutionCount == 1)
            print("INSPECTOR_LINKS_BENCHMARK UI.R.REM02: 5000 pages, \(count) links; cold lookup/model=\(coldDuration), 200 cached model evaluations=\(repeatedDuration), lookup builds=\(cache.lookupBuildCount), target resolutions=\(cache.resolutionCount)")
        }
    }
}
