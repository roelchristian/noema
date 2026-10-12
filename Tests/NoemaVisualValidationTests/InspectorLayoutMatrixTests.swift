import Foundation
import SwiftUI
import AppKit
import Testing
import NoemaBrand
@testable import VaultCore
@testable import noema

/// Full layout assertions are compiled only for explicit visual validation.
@Suite("Visual validation: Inspector full layout matrix", .serialized)
struct InspectorLayoutMatrixTests {
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

    private func makeSource(
        id: UUID = UUID(),
        title: String,
        filename: String = "paper.pdf",
        lcc: String? = "QA76",
        summary: String? = nil
    ) -> SourceRecord {
        SourceRecord(
            metadata: SourceMetadata(
                id: id,
                title: title,
                capturedAt: "2026-10-11T11:00:00Z",
                originalFilename: filename,
                originURL: "https://example.com/\(filename)",
                sha256: "abc123",
                lcc: lcc,
                aiSummary: summary,
                fileSize: 4096,
                storedFilename: "original.pdf"
            ),
            body: "Source content for \(title)"
        )
    }

    @Test @MainActor func inspectorLayoutMatrixCoversApplicableTabsWidthsAndContrast() throws {
        var claimMeta = BlockMetadata(); claimMeta.semantic = "claim"
        var questionMeta = BlockMetadata(); questionMeta.semantic = "question"
        let blocks = [
            EditorBlock(runs: [RichRun("Primary architectural claim regarding contextual tabs.")], metadata: claimMeta),
            EditorBlock(runs: [RichRun("How should ambiguous outgoing links resolve in the sidebar?")], metadata: questionMeta)
        ]
        var doc = BlockDocument(blocks: blocks)
        doc.setAISummary("This page documents the native macOS tabbed contextual inspector architecture, link resolution states, and cached insights.")
        let encodedBody = BlockDocumentCodec.encode(doc)

        let sourceA = makeSource(
            title: "Human Interface Guidelines — Sidebars",
            filename: "hig-sidebars.pdf",
            lcc: "QA76.9.U83",
            summary: "Apple Human Interface Guidelines for macOS inspector panes, toolbar toggles, and contextual tab bars."
        )
        let noteA = makeNote(
            title: "Contextual Inspector Architecture",
            aliases: ["Right Sidebar Redesign", "UI.R"],
            tags: ["architecture", "macos", "ui"],
            inlineTags: ["inspector", "swiftui"],
            body: encodedBody,
            lcc: "QA76.76.D47",
            locked: false,
            sourceIDs: [sourceA.id, UUID()]
        )
        let targetNote = makeNote(title: "SQLite Search Index", aliases: ["SearchIndex"], lcc: "QA76.9.D3")
        let backlinkNote = makeNote(title: "Noema Design System", lcc: "NK1510")
        let ambig1 = makeNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, title: "Mercury", aliases: ["Planet"])
        let ambig2 = makeNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!, title: "Quicksilver", aliases: ["Mercury"])

        let model = AppModel()
        model.notes = [noteA, targetNote, backlinkNote, ambig1, ambig2]
        model.sources = [sourceA]
        model.currentNote = noteA
        model.title = noteA.title
        model.body = noteA.body
        model.tagInput = noteA.tags.joined(separator: ", ")
        model.lccInput = noteA.lcc ?? ""
        model.wordCount = 148
        model.backlinks = [backlinkNote]
        model.outgoingLinkTargets = ["searchindex", "mercury", "future roadmap"]

        let state = InspectorState()
        let pageContext = InspectorContext.page(noteA)
        let sourceContext = InspectorContext.source(sourceA, isDetail: false)

        // Preserve the original 64 routine combinations as explicit specialized
        // layout validation; DesignTokenCaptureTests retains the raster matrix.
        let appearances: [(preference: ThemePreference, dark: Bool, increased: Bool, widths: [CGFloat])] = [
            (.system, false, false, [InspectorState.minWidth, InspectorState.idealWidth, InspectorState.maxWidth]),
            (.system, true, false, [InspectorState.minWidth, InspectorState.idealWidth, InspectorState.maxWidth]),
            (.midnightIris, false, true, [InspectorState.minWidth]),
            (.midnightIris, true, true, [InspectorState.minWidth])
        ]
        for appearance in appearances {
            var theme = NoemaTheme(dark: appearance.dark, increasedContrast: appearance.increased)
            theme.preference = appearance.preference
            theme.fullPalette = true
            let name: NSAppearance.Name = appearance.increased
                ? (appearance.dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                : (appearance.dark ? .darkAqua : .aqua)
            let nativeAppearance = try #require(NSAppearance(named: name))
            for width in appearance.widths {
                for context in [pageContext, sourceContext] {
                    for tab in context.applicableTabs {
                        state.selectTab(tab, for: context)
                        #expect(state.activeTab(for: context) == tab)
                        let view = InspectorContainer(model: model, state: state, context: context)
                            .environment(\.noemaTheme, theme)
                            .environment(\.colorScheme, appearance.dark ? .dark : .light)
                            .transaction { $0.disablesAnimations = true }
                            .frame(width: width, height: 640)
                        let hosting = NSHostingView(rootView: view)
                        hosting.appearance = nativeAppearance
                        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 640)
                        hosting.layoutSubtreeIfNeeded()
                        let kind = context.targetKind == .page ? "page" : "source"
                        let label = "\(kind)-\(tab.rawValue) at \(width)pt, \(appearance.preference.rawValue), dark=\(appearance.dark), contrast=\(appearance.increased)"
                        #expect(hosting.fittingSize.width >= InspectorState.minWidth, "\(label): below minimum")
                        #expect(hosting.fittingSize.width <= width + 1, "\(label): horizontal overflow")
                        let safeArea = hosting.safeAreaInsets.top + hosting.safeAreaInsets.bottom
                        #expect(hosting.fittingSize.height <= 640 + safeArea + 1, "\(label): vertical overflow")
                    }
                }
            }
        }
    }
}
