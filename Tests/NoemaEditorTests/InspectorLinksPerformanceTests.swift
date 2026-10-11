import Foundation
import Testing
@testable import VaultCore
@testable import noema

@Suite("Inspector Links Cache (UI.R.REM02)")
@MainActor
struct InspectorLinksPerformanceTests {
    private func note(id: UUID = UUID(), title: String, aliases: [String] = [], body: String = "") -> NoteRecord {
        NoteRecord(
            id: id, title: title, aliases: aliases, tags: [], inlineTags: [],
            createdAt: "2026-10-12T00:00:00Z", updatedAt: "2026-10-12T00:00:00Z",
            body: body, relativePath: "Wiki/\(id).md", contentHash: "fixture", originalHeader: nil
        )
    }

    @Test func preservesNormalizationAliasPriorityDeduplicationAndAmbiguityOrdering() {
        let titleMatch = note(title: "Café", aliases: [" CAFÉ ", "Coffee", "coffee"])
        let mercury = note(title: "Mercury")
        let quicksilver = note(title: "Quicksilver", aliases: ["Mercury"])
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let sameTitleA = note(id: earlierID, title: "Same")
        let sameTitleB = note(id: laterID, title: "Same")
        let notes = [quicksilver, sameTitleB, titleMatch, mercury, sameTitleA]
        let targets = [" CAFE\u{301} ", "café", "coffee", "MERCURY", "unknown", "same", "  "]
        let pageID = UUID()
        let result = LinksPresentationCache().model(
            pageID: pageID, backlinks: [mercury], outgoingLinkTargets: targets, allNotes: notes
        )

        #expect(result.outgoingLinks.map(\.target) == [" CAFE\u{301} ", "coffee", "MERCURY", "unknown", "same"])
        #expect(result.outgoingLinks.map(\.resolution) == [
            .resolved(note: titleMatch, matchedAlias: nil),
            .resolved(note: titleMatch, matchedAlias: "Coffee"),
            .ambiguous(target: "MERCURY", matches: [mercury, quicksilver]),
            .unresolved(target: "unknown"),
            .ambiguous(target: "same", matches: [sameTitleA, sameTitleB])
        ])
        #expect(result.totalCount == 6)
        #expect(result == LinksPanelModel(pageID: pageID, backlinks: [mercury], outgoingLinkTargets: targets, allNotes: notes))
    }

    @Test func repeatedEvaluationsReuseResolutionAndHydrateCurrentRecords() {
        let cache = LinksPresentationCache()
        let pageID = UUID()
        var target = note(title: "Target", aliases: ["Prior Title"], body: "Before")
        let other = note(title: "Other")
        let targets = ["Prior Title", "missing"]
        let initial = cache.model(pageID: pageID, backlinks: [], outgoingLinkTargets: targets, allNotes: [target, other])
        for _ in 0..<20 {
            #expect(cache.model(pageID: pageID, backlinks: [], outgoingLinkTargets: targets, allNotes: [target, other]) == initial)
        }
        target.body = "After"
        target.lcc = "QA76.9"
        target.tags = ["updated"]
        target.updatedAt = "2026-10-12T01:00:00Z"
        target.sourceIDs = [UUID()]
        // Reordering pages must refresh hydration positions without rebuilding title/alias buckets.
        let refreshed = cache.model(pageID: pageID, backlinks: [other], outgoingLinkTargets: targets, allNotes: [other, target])
        #expect(refreshed.outgoingLinks[0].resolution == .resolved(note: target, matchedAlias: "Prior Title"))
        #expect(refreshed.backlinks == [other])
        #expect(cache.lookupBuildCount == 1)
        #expect(cache.resolutionCount == 1)

        let retargeted = cache.model(pageID: pageID, backlinks: [], outgoingLinkTargets: ["Target"], allNotes: [other, target])
        #expect(retargeted.outgoingLinks[0].resolution == .resolved(note: target, matchedAlias: nil))
        #expect(cache.lookupBuildCount == 1)
        #expect(cache.resolutionCount == 2)
    }

    @Test func renameAliasAddDeleteAndSameCountReplacementInvalidateLookup() {
        let cache = LinksPresentationCache()
        let pageID = UUID()
        var target = note(title: "Original")
        let targets = ["Original", "Renamed", "Alias"]
        func evaluate(_ notes: [NoteRecord]) -> [OutgoingLinkResolution] {
            cache.model(pageID: pageID, backlinks: [], outgoingLinkTargets: targets, allNotes: notes).outgoingLinks.map(\.resolution)
        }

        #expect(evaluate([target])[0] == .resolved(note: target, matchedAlias: nil))
        target.title = "Renamed"
        target.aliases = ["Original"]
        #expect(evaluate([target]) == [
            .resolved(note: target, matchedAlias: "Original"), .resolved(note: target, matchedAlias: nil), .unresolved(target: "Alias")
        ])
        target.aliases.append("Alias")
        #expect(evaluate([target])[2] == .resolved(note: target, matchedAlias: "Alias"))
        let collision = note(title: "Z Page", aliases: ["Alias"])
        #expect(evaluate([collision, target])[2] == .ambiguous(target: "Alias", matches: [target, collision]))
        #expect(evaluate([collision])[2] == .resolved(note: collision, matchedAlias: "Alias"))
        let replacement = note(title: "Alias")
        #expect(evaluate([replacement])[2] == .resolved(note: replacement, matchedAlias: nil))
        #expect(evaluate([]).allSatisfy { if case .unresolved = $0 { return true }; return false })
        #expect(cache.lookupBuildCount == 7)
        #expect(cache.resolutionCount == 7)
    }

    @Test func targetAndSessionTransitionsPurgeTheAppropriateCachedState() {
        let state = InspectorState()
        let cache = state.linksCache
        let pageA = note(title: "A")
        let pageB = note(title: "B")
        let notes = [pageA, pageB]
        _ = cache.model(pageID: pageA.id, backlinks: [], outgoingLinkTargets: ["B"], allNotes: notes)
        state.reconcile(with: .page(pageB))
        #expect(cache.currentCachedPageID == nil)
        #expect(cache.hasCachedLookup)
        _ = cache.model(pageID: pageB.id, backlinks: [], outgoingLinkTargets: ["A"], allNotes: notes)
        #expect(cache.lookupBuildCount == 1)
        #expect(cache.resolutionCount == 2)

        // A source selection clears the page lookup even when there is no active Links panel.
        let source = SourceRecord(metadata: SourceMetadata(
            id: UUID(), title: "Source", capturedAt: "2026-10-12T00:00:00Z", originalFilename: "source.pdf",
            sha256: "fixture", storedFilename: "original.pdf"
        ), body: "source content")
        state.reconcile(with: .source(source, isDetail: false))
        #expect(cache.currentCachedPageID == nil)
        #expect(!cache.hasCachedLookup)
        _ = cache.model(pageID: pageA.id, backlinks: [], outgoingLinkTargets: ["B"], allNotes: notes)
        state.resetForSessionChange()
        #expect(cache.currentCachedPageID == nil)
        #expect(!cache.hasCachedLookup)
        // A different vault may reuse page IDs; its metadata must be indexed from scratch.
        let renamed = note(id: pageB.id, title: "Changed in new vault")
        let newSession = cache.model(pageID: pageA.id, backlinks: [], outgoingLinkTargets: ["B"], allNotes: [pageA, renamed])
        #expect(newSession.outgoingLinks[0].resolution == .unresolved(target: "B"))
        #expect(cache.lookupBuildCount == 3)
        state.reconcile(with: .none)
        #expect(cache.currentCachedPageID == nil)
        #expect(!cache.hasCachedLookup)
    }

    @Test func benchmarkActualLinksPresentationPathWithFiveThousandPages() {
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
