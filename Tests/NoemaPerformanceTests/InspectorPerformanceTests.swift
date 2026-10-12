import Foundation
import SwiftUI
import AppKit
import Testing
import NoemaBrand
@testable import VaultCore
@testable import noema

@Suite("Inspector tab switching benchmark")
struct InspectorPerformanceTests {
    private func makeNote(
        id: UUID = UUID(),
        title: String,
        aliases: [String] = [],
        tags: [String] = [],
        inlineTags: [String] = [],
        body: String = "",
        lcc: String? = "QA76",
        locked: Bool = false,
        sourceIDs: [UUID]? = nil
    ) -> NoteRecord {
        NoteRecord(
            id: id,
            title: title,
            aliases: aliases,
            tags: tags,
            inlineTags: inlineTags,
            createdAt: "2026-10-11T10:00:00Z",
            updatedAt: "2026-10-11T12:00:00Z",
            body: body,
            relativePath: "Wiki/\(title).md",
            contentHash: digest(Data(body.utf8)),
            lcc: lcc,
            editingLocked: locked ? true : nil,
            sourceIDs: sourceIDs,
            originalHeader: nil
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"))
    @MainActor func benchmarkTabSwitchingWithCachedInsights() {
        var blocks: [EditorBlock] = []
        for i in 0..<240 {
            var meta = BlockMetadata()
            if i.isMultiple(of: 20) { meta.semantic = "evidence" }
            blocks.append(EditorBlock(runs: [RichRun("Paragraph \(i) with [[Target \(i % 12)]] and #tag\(i % 5).")], metadata: meta))
        }
        var doc = BlockDocument(blocks: blocks)
        doc.setAISummary("Synthesized summary for benchmark page.")
        let richBody = BlockDocumentCodec.encode(doc)
        let note = makeNote(title: "Benchmark Page", tags: ["alpha", "beta"], body: richBody)
        let context = InspectorContext.page(note)
        let clock = ContinuousClock()

        // 200 tab switches across Links, References, Tags, Properties, and Insights.
        let state = InspectorState()
        let tabs = InspectorTab.pageTabs
        let tabbedDuration = clock.measure {
            for i in 0..<200 {
                let tab = tabs[i % tabs.count]
                state.selectTab(tab, for: context)
                if tab == .insights {
                    let snapshot = state.insightsCache.snapshot(for: note.id, body: richBody)
                    #expect(snapshot.hasSummary)
                }
            }
        }

        #expect(state.insightsCache.decodeCount == 1)
        print("INSPECTOR_BENCHMARK 200 passes (240 blocks): tabbed inspector with cached Insights=\(tabbedDuration), insights decodes=\(state.insightsCache.decodeCount)")
    }

}
