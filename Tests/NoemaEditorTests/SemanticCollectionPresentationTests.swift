import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

@Suite("Semantic Blocks collection presentation and filtering (UI.02C)")
struct SemanticCollectionPresentationTests {
    @Test @MainActor func availableFiltersPreservesCanonicalRegistryOrderAndCounts() {
        let rows = [
            SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page A", semantic: "summary", preview: "Final summary"),
            SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page A", semantic: "  Question ", preview: "First question"),
            SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page B", semantic: "definition", preview: "Core definition"),
            SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page B", semantic: "QUESTION", preview: "Second question"),
            SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page C", semantic: "hypothesis", preview: "Custom semantic"),
            SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page C", semantic: "   ", preview: "Ignored blank semantic")
        ]

        let filters = SemanticCollectionPresentation.availableFilters(from: rows)
        #expect(filters.map(\.id) == ["question", "definition", "summary", "hypothesis"])
        #expect(filters.map(\.count) == [2, 1, 1, 1])

        let canonicalKeys = SemanticPresentation.all.map(\.key)
        let knownPositions = filters.compactMap { canonicalKeys.firstIndex(of: $0.id) }
        #expect(knownPositions == knownPositions.sorted())

        #expect(filters[0] == SemanticTypeFilterOption(id: "question", title: "Question", symbol: "questionmark.circle", count: 2))
        #expect(filters[1] == SemanticTypeFilterOption(id: "definition", title: "Definition", symbol: "book", count: 1))
        #expect(filters[2] == SemanticTypeFilterOption(id: "summary", title: "Summary", symbol: "list.bullet.rectangle", count: 1))
        #expect(filters[3] == SemanticTypeFilterOption(id: "hypothesis", title: "Hypothesis", symbol: "tag", count: 1))
    }

    @Test func filteredRowsMatchesCaseInsensitivelyAndReturnsAllWhenUnfiltered() {
        let question1 = SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page 1", semantic: "question", preview: "Q1")
        let idea = SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page 2", semantic: "Idea", preview: "I1")
        let question2 = SemanticBlockHit(pageID: UUID(), blockID: UUID(), pageTitle: "Page 3", semantic: " QUESTION ", preview: "Q2")
        let rows = [question1, idea, question2]

        #expect(SemanticCollectionPresentation.filteredRows(rows, selectedSemantic: nil).map(\.id) == rows.map(\.id))
        #expect(SemanticCollectionPresentation.filteredRows(rows, selectedSemantic: "question").map(\.id) == [question1.id, question2.id])
        #expect(SemanticCollectionPresentation.filteredRows(rows, selectedSemantic: "QUESTION").map(\.id) == [question1.id, question2.id])
        #expect(SemanticCollectionPresentation.filteredRows(rows, selectedSemantic: "idea").map(\.id) == [idea.id])
        #expect(SemanticCollectionPresentation.filteredRows(rows, selectedSemantic: "warning").isEmpty)
    }

    @Test func countLabelFormatsSingularPluralAndFilteredCounts() {
        #expect(SemanticCollectionPresentation.countLabel(filteredCount: 0, totalCount: 0, selectedSemantic: nil) == "0 semantic blocks")
        #expect(SemanticCollectionPresentation.countLabel(filteredCount: 1, totalCount: 1, selectedSemantic: nil) == "1 semantic block")
        #expect(SemanticCollectionPresentation.countLabel(filteredCount: 5, totalCount: 5, selectedSemantic: nil) == "5 semantic blocks")
        #expect(SemanticCollectionPresentation.countLabel(filteredCount: 5, totalCount: 5, selectedSemantic: "question") == "5 semantic blocks")
        #expect(SemanticCollectionPresentation.countLabel(filteredCount: 2, totalCount: 5, selectedSemantic: "question") == "2 of 5 semantic blocks")
        #expect(SemanticCollectionPresentation.countLabel(filteredCount: 1, totalCount: 1, selectedSemantic: "question") == "1 semantic block")
    }

    @Test func statusLabelNormalizesOptionalStatus() {
        #expect(SemanticCollectionPresentation.statusLabel(for: nil) == nil)
        #expect(SemanticCollectionPresentation.statusLabel(for: "") == nil)
        #expect(SemanticCollectionPresentation.statusLabel(for: "   ") == nil)
        #expect(SemanticCollectionPresentation.statusLabel(for: "open") == "Open")
        #expect(SemanticCollectionPresentation.statusLabel(for: " resolved ") == "Resolved")
    }

    @Test @MainActor func semanticBlockCollectionRowRendersWithCompactTwoLineDensity() {
        _ = NSApplication.shared
        let hit = SemanticBlockHit(
            pageID: UUID(),
            blockID: UUID(),
            pageTitle: " Quantum Mechanics & Measurement ",
            semantic: "question",
            preview: "How does decoherence select a pointer basis in macroscopic systems?\nSecond line collapsed."
        )
        let view = SemanticBlockCollectionRow(hit: hit, status: "open")
            .environment(\.noemaTheme, NoemaTheme())
            .frame(width: 600)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 100)
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        #expect(fitting.height > 0)
        #expect(fitting.height <= 48)
    }
}
