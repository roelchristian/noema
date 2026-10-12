import Foundation
import SwiftUI
import AppKit
import Testing
import NoemaBrand
@testable import VaultCore
@testable import noema

@Suite("Inspector Redesign (UI.R1–UI.R7)")
struct InspectorRedesignTests {
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

    // MARK: - UI.R1 & UI.R2: Architecture, State, and Shell

    @Test @MainActor func inspectorContextAndTabApplicability() {
        #expect(InspectorTab.pageTabs == [.links, .references, .tags, .properties, .insights])
        #expect(InspectorTab.sourceTabs == [.references, .properties, .insights])
        #expect(InspectorState.minWidth == 280)
        #expect(InspectorState.idealWidth == 340)
        #expect(InspectorState.maxWidth == 420)

        let note = makeNote(title: "Architecture")
        let source = makeSource(title: "Reference Paper")

        let pageContext = InspectorContext.page(note)
        let sourceContext = InspectorContext.source(source, isDetail: false)
        let emptyContext = InspectorContext.none

        #expect(pageContext.isInspectable)
        #expect(pageContext.targetKind == .page)
        #expect(pageContext.targetID == note.id)
        #expect(pageContext.applicableTabs == InspectorTab.pageTabs)

        #expect(sourceContext.isInspectable)
        #expect(sourceContext.targetKind == .source)
        #expect(sourceContext.targetID == source.id)
        #expect(sourceContext.applicableTabs == InspectorTab.sourceTabs)

        #expect(!emptyContext.isInspectable)
        #expect(emptyContext.targetKind == nil)
        #expect(emptyContext.targetID == nil)
        #expect(emptyContext.applicableTabs.isEmpty)
    }

    @Test @MainActor func inspectorStatePreservesTabMemoryAndStepsKeyboardNavigation() {
        let state = InspectorState()
        let pageContext = InspectorContext.page(makeNote(title: "Page A"))
        let sourceContext = InspectorContext.source(makeSource(title: "Source A"), isDetail: false)

        // Default tab is Properties in both contexts
        #expect(state.activeTab(for: pageContext) == .properties)
        #expect(state.activeTab(for: sourceContext) == .properties)

        // Selecting a page-only tab (.links) keeps source context on .properties
        state.selectTab(.links, for: pageContext)
        #expect(state.activeTab(for: pageContext) == .links)
        #expect(state.activeTab(for: sourceContext) == .properties)

        // Selecting a shared tab (.insights) updates both contexts so switching between page and source keeps Insights
        state.selectTab(.insights, for: sourceContext)
        #expect(state.activeTab(for: sourceContext) == .insights)
        #expect(state.activeTab(for: pageContext) == .insights)

        // Selecting .tags on a page and then switching to a source falls back to the last applicable source tab (.insights)
        state.selectTab(.tags, for: pageContext)
        #expect(state.activeTab(for: pageContext) == .tags)
        #expect(state.activeTab(for: sourceContext) == .insights)

        // Keyboard stepping wraps around applicable tabs
        state.selectTab(.links, for: pageContext)
        state.stepTab(by: -1, for: pageContext)
        #expect(state.activeTab(for: pageContext) == .insights)
        state.stepTab(by: 1, for: pageContext)
        #expect(state.activeTab(for: pageContext) == .links)

        // Visibility toggle and session reset
        #expect(state.shouldPresent(for: pageContext))
        state.toggleVisibility()
        #expect(!state.isVisible)
        #expect(!state.shouldPresent(for: pageContext))
        state.toggleVisibility()
        #expect(state.isVisible)

        // Section expansion preferences persist across tab switches and reset on session change
        #expect(state.isSectionExpanded("Timestamps"))
        #expect(state.isSectionExpanded("Status"))
        state.setSectionExpanded(false, for: "Timestamps")
        #expect(!state.isSectionExpanded("Timestamps"))
        state.selectTab(.insights, for: pageContext)
        state.selectTab(.properties, for: pageContext)
        #expect(!state.isSectionExpanded("Timestamps"))
        state.sectionExpansionBinding(for: "Status").wrappedValue = false
        #expect(!state.isSectionExpanded("Status"))

        state.resetForSessionChange()
        #expect(state.activeTab(for: pageContext) == .properties)
        #expect(state.activeTab(for: sourceContext) == .properties)
        #expect(state.isSectionExpanded("Timestamps"))
        #expect(state.isSectionExpanded("Status"))
    }

    @Test @MainActor func inspectorContextResolutionRespectsSessionLifecycle() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaInspectorContext-\(UUID())", isDirectory: true)
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: base) }

        let repo = try FileVaultRepository.open(root: root, create: true)
        let note = try await repo.create(title: "Test Page", body: "Content")
        let source = try await repo.importSource(data: Data("Source text".utf8), filename: "source.txt", title: "Test Source", originURL: nil)

        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false

        // Before vault open
        #expect(InspectorContext.resolve(model: model, librarySourceSelection: source.id) == .none)

        await model.open(root, create: false)
        #expect(model.isVaultAvailable)

        // Page selected
        model.currentNote = note
        #expect(InspectorContext.resolve(model: model, librarySourceSelection: nil) == .page(note))

        // Source selected in library table
        model.currentNote = nil
        model.scope = .sources
        #expect(InspectorContext.resolve(model: model, librarySourceSelection: source.id) == .source(source, isDetail: false))

        // Locking vault immediately resolves to .none even if librarySourceSelection was still passed
        #expect(await model.lockVault())
        #expect(InspectorContext.resolve(model: model, librarySourceSelection: source.id) == .none)

        _ = await model.closeVault()
    }

    // MARK: - UI.R3: Properties and Tags Panels

    @Test func tagsPanelModelSeparatesEditableAndInlineTags() {
        let note = makeNote(
            title: "Tagged Note",
            tags: ["architecture", "swift"],
            inlineTags: ["inline-one"],
            body: "Body with #inline-one and #inline-two plus `#ignored-in-code`."
        )

        let editable = TagsPanelModel.editableTags(from: "swift, Architecture, #design ")
        #expect(editable == ["architecture", "design", "swift"])

        let inlineFromBody = TagsPanelModel.inlineTags(for: note, liveBody: note.body)
        #expect(inlineFromBody == ["inline-one", "inline-two"])

        let afterAdd = TagsPanelModel.addingTag("#macOS, swift", to: "architecture, swift")
        #expect(afterAdd == "architecture, macos, swift")

        let afterRemove = TagsPanelModel.removingTag("#Swift", from: afterAdd)
        #expect(afterRemove == "architecture, macos")
    }

    // MARK: - UI.R4: Links, Backlinks, Outlinks, and Stale Query Protection

    @Test func linksPanelModelHandlesExactTitlesAliasesAmbiguousAndUnresolvedLinks() {
        let pageA = makeNote(title: "Origin Page")
        let targetByTitle = makeNote(title: "Quantum Mechanics", aliases: ["QM"])
        let targetByAlias = makeNote(title: "General Relativity", aliases: ["GR", "Einstein Gravity"])
        let duplicate1 = makeNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Mercury", aliases: ["Planet"])
        let duplicate2 = makeNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Element 80", aliases: ["Mercury"])
        let backlinkNote = makeNote(title: "Index Page")

        let allNotes = [pageA, targetByTitle, targetByAlias, duplicate1, duplicate2, backlinkNote]
        let model = LinksPanelModel(
            pageID: pageA.id,
            backlinks: [backlinkNote],
            outgoingLinkTargets: [
                "quantum mechanics",
                "einstein gravity",
                "mercury",
                "missing concept",
                "QUANTUM MECHANICS" // duplicate target should be deduplicated
            ],
            allNotes: allNotes
        )

        #expect(model.backlinks == [backlinkNote])
        #expect(model.outgoingLinks.count == 4)
        #expect(model.totalCount == 5)

        // 1. Direct title match
        #expect(model.outgoingLinks[0].resolution == .resolved(note: targetByTitle, matchedAlias: nil))
        #expect(model.outgoingLinks[0].displayTitle == "Quantum Mechanics")
        #expect(model.outgoingLinks[0].subtitle == nil)

        // 2. Alias match (e.g., after rename or explicit alias)
        #expect(model.outgoingLinks[1].resolution == .resolved(note: targetByAlias, matchedAlias: "Einstein Gravity"))
        #expect(model.outgoingLinks[1].displayTitle == "General Relativity")
        #expect(model.outgoingLinks[1].subtitle == "via Einstein Gravity")

        // 3. Ambiguous match
        #expect(model.outgoingLinks[2].resolution == .ambiguous(target: "mercury", matches: [duplicate2, duplicate1]))
        #expect(model.outgoingLinks[2].subtitle == "Ambiguous · 2 matching pages")

        // 4. Unresolved link
        #expect(model.outgoingLinks[3].resolution == .unresolved(target: "missing concept"))
        #expect(model.outgoingLinks[3].subtitle == "Unresolved link")
    }

    @Test @MainActor func pageRenamePreservesBacklinksAndOutlinkResolutionViaAliases() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaLinksRename-\(UUID())", isDirectory: true)
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: base) }

        let repo = try FileVaultRepository.open(root: root, create: true)
        let sourcePage = try await repo.create(title: "Source Page", body: "Links to [[Original Target]].")
        let targetPage = try await repo.create(title: "Original Target", body: "Content")

        // Rename targetPage -> "Renamed Target"; FileVaultRepository records "Original Target" in aliases
        let renamedTarget = try await repo.save(
            note: targetPage,
            title: "Renamed Target",
            body: targetPage.body,
            tags: targetPage.tags
        )
        #expect(renamedTarget.aliases.contains("Original Target"))

        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)

        model.select(sourcePage.id)
        for _ in 0..<100 {
            if model.currentNote?.id == sourcePage.id && !model.outgoingLinkTargets.isEmpty { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(model.outgoingLinkTargets == ["original target"])

        let linksState = LinksPanelModel(
            pageID: sourcePage.id,
            backlinks: model.backlinks,
            outgoingLinkTargets: model.outgoingLinkTargets,
            allNotes: model.notes
        )
        #expect(linksState.outgoingLinks.first?.resolution == .resolved(note: renamedTarget, matchedAlias: "Original Target"))

        // Selecting the renamed target still shows Source Page in its backlinks
        model.select(renamedTarget.id)
        for _ in 0..<100 {
            if model.currentNote?.id == renamedTarget.id && !model.backlinks.isEmpty { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(model.backlinks.map(\.id) == [sourcePage.id])

        _ = await model.closeVault()
    }

    // MARK: - UI.R5: References and Source Associations

    @Test func referencesPanelModelHandlesLocksMissingSourcesAndConcurrentMutations() {
        let validSource = makeSource(title: "Available Paper")
        let extraSource = makeSource(title: "Unlinked Paper")
        let missingSourceID = UUID()

        let unlockedNote = makeNote(
            title: "Research Note",
            locked: false,
            sourceIDs: [validSource.id, missingSourceID]
        )
        let lockedNote = makeNote(
            title: "Locked Note",
            locked: true,
            sourceIDs: [validSource.id]
        )

        // Page mode with valid + missing source
        let pageState = ReferencesPanelModel.forPage(
            note: unlockedNote,
            sources: [validSource, extraSource],
            editorReadOnly: false,
            updatingSourceReferences: false
        )
        if case .page(_, let linkedSources, let availableToAdd, let canEdit) = pageState.mode {
            #expect(canEdit)
            #expect(linkedSources.count == 2)
            #expect(linkedSources[0].title == "Available Paper" && linkedSources[0].canOpen && linkedSources[0].canRemove)
            #expect(linkedSources[1].title == "Unavailable source" && !linkedSources[1].canOpen && linkedSources[1].canRemove)
            #expect(availableToAdd.map(\.id) == [extraSource.id])
        } else {
            Issue.record("Expected page mode")
        }

        // Page mode when locked or updatingSourceReferences is true
        let lockedPageState = ReferencesPanelModel.forPage(
            note: lockedNote,
            sources: [validSource, extraSource],
            editorReadOnly: false,
            updatingSourceReferences: false
        )
        if case .page(_, let linkedSources, _, let canEdit) = lockedPageState.mode {
            #expect(!canEdit)
            #expect(linkedSources.allSatisfy { !$0.canRemove })
        }

        // Source mode with unlocked and locked referring pages
        let unlinkedNote = makeNote(title: "Candidate Note", locked: false)
        let sourceState = ReferencesPanelModel.forSource(
            source: validSource,
            notes: [unlockedNote, lockedNote, unlinkedNote],
            updatingSourceReferences: false,
            downloadingSources: [],
            generatingSourcePages: [],
            generatingSourceTitles: [],
            generatingSourceSummaries: []
        )
        if case .source(_, let referringPages, let availablePagesToAdd, let canPresentAddMenu, let canCreatePageWithAI, _) = sourceState.mode {
            #expect(canPresentAddMenu)
            #expect(canCreatePageWithAI)
            #expect(referringPages.count == 2)
            #expect(referringPages[0].id == unlockedNote.id && referringPages[0].canRemove)
            #expect(referringPages[1].id == lockedNote.id && !referringPages[1].canRemove)
            #expect(availablePagesToAdd.map(\.id) == [unlinkedNote.id])
        } else {
            Issue.record("Expected source mode")
        }
    }

    // MARK: - UI.R6 & UI.R7: Insights Caching and Tab-Switching Performance

    @Test @MainActor func insightsPresentationCacheAvoidsRedundantDecodingAndInvalidatesOnSelectionOrSessionChange() {
        let state = InspectorState()
        let cache = state.insightsCache

        var claimMeta = BlockMetadata(); claimMeta.semantic = "claim"
        let claimBlock = EditorBlock(runs: [RichRun("Key scientific claim")], metadata: claimMeta)
        var doc = BlockDocument(blocks: [claimBlock])
        doc.setAISummary("Concise on-device summary.")
        let encodedBody = BlockDocumentCodec.encode(doc)

        let noteA = makeNote(title: "Note A", body: encodedBody)
        let noteB = makeNote(title: "Note B", body: "Plain body")
        let contextA = InspectorContext.page(noteA)
        let contextB = InspectorContext.page(noteB)

        // Switching across non-Insights tabs never decodes the document
        for tab in [InspectorTab.links, .references, .tags, .properties] {
            state.selectTab(tab, for: contextA)
        }
        #expect(cache.decodeCount == 0)

        // Evaluating Insights decodes once
        state.selectTab(.insights, for: contextA)
        let snap1 = cache.snapshot(for: noteA.id, body: noteA.body)
        #expect(cache.decodeCount == 1)
        #expect(snap1.summaryText == "Concise on-device summary.")
        #expect(snap1.semanticBlockCount == 1)

        // Switching away and back to Insights with unchanged body reuses cached snapshot without re-decoding
        state.selectTab(.properties, for: contextA)
        state.selectTab(.links, for: contextA)
        state.selectTab(.insights, for: contextA)
        let snap2 = cache.snapshot(for: noteA.id, body: noteA.body)
        #expect(cache.decodeCount == 1)
        #expect(snap1 == snap2)

        // Reconciling with a newly selected page invalidates the previous page's cached snapshot
        state.reconcile(with: contextB)
        #expect(cache.currentCachedNoteID == nil)

        _ = cache.snapshot(for: noteB.id, body: noteB.body)
        #expect(cache.decodeCount == 2)
        #expect(cache.currentCachedNoteID == noteB.id)

        // Session reset purges cached snapshot immediately
        state.resetForSessionChange()
        #expect(cache.currentCachedNoteID == nil)
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

        // Routine layout coverage uses standard light/dark at every width and
        // representative full-palette high contrast at the minimum width.
        // The exhaustive theme/contrast raster matrix is in the visual harness.
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
