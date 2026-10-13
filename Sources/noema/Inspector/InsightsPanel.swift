import SwiftUI
import VaultCore

struct InspectionAuthorityCaption: View {
    let authority: InspectionAuthority

    var body: some View {
        Text(authority.note)
            .font(NoemaTypography.metadata)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(authority.note)
    }
}

/// Equatable group of semantic blocks for cached inspector presentation.
struct SemanticBlockGroup: Identifiable, Equatable, Sendable {
    let tag: String
    let blocks: [EditorBlock]

    var id: String { tag }
}

/// Cached decoded presentation of a page's AI summary and semantic blocks (UI.R6).
struct PageInsightsSnapshot: Equatable, Sendable {
    let noteID: UUID
    let body: String
    let summaryText: String?
    let summaryProvenanceLabel: String
    let semanticGroups: [SemanticBlockGroup]
    let semanticBlockCount: Int

    var hasSummary: Bool {
        summaryText != nil
    }
}

/// Selection-aware, session-invalidated cache for decoded `BlockDocument` insights (UI.R6).
/// Prevents redundant `BlockDocumentCodec.decode` work across tab switches or unrelated view updates.
@MainActor
@Observable
final class InsightsPresentationCache {
    private var cachedSnapshot: PageInsightsSnapshot?
    private(set) var decodeCount: Int = 0

    init() {}

    /// Returns a cached or newly decoded insights snapshot for the given page and body.
    func snapshot(for noteID: UUID, body: String) -> PageInsightsSnapshot {
        if let existing = cachedSnapshot,
           existing.noteID == noteID,
           existing.body == body {
            return existing
        }
        decodeCount += 1
        let document = BlockDocumentCodec.decode(body)
        let groups = document.semanticGroups.map { group in
            SemanticBlockGroup(tag: group.tag, blocks: group.blocks)
        }
        let blockCount = groups.reduce(0) { $0 + $1.blocks.count }
        let snapshot = PageInsightsSnapshot(
            noteID: noteID,
            body: body,
            summaryText: document.aiSummary?.text,
            summaryProvenanceLabel: aiSummaryProvenanceLabel(
                provider: document.aiSummary?.metadata.extra["aiProvider"],
                model: document.aiSummary?.metadata.extra["aiModel"]
            ),
            semanticGroups: groups,
            semanticBlockCount: blockCount
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    /// Invalidates cached insights if the target page changed.
    func reconcileTarget(id: UUID?) {
        guard let cachedSnapshot else { return }
        if cachedSnapshot.noteID != id {
            self.cachedSnapshot = nil
        }
    }

    /// Immediately purges cached document state on vault lock, close, or switch.
    func invalidate() {
        cachedSnapshot = nil
    }

    var currentCachedNoteID: UUID? {
        cachedSnapshot?.noteID
    }
}

/// Inspector panel consolidating AI summaries and semantic blocks (UI.R6).
struct InsightsPanel: View {
    @Environment(\.noemaTheme) private var theme
    @Bindable var model: AppModel
    let context: InspectorContext
    let cache: InsightsPresentationCache
    var scrollPosition: Binding<ScrollPosition>? = nil


    var body: some View {
        switch context {
        case .none:
            EmptyView()
        case .page(let note):
            pageInsightsView(note)
        case .source(let source, _):
            sourceInsightsView(source)
        }
    }

    private func pageInsightsView(_ note: NoteRecord) -> some View {
        let isCurrent = model.currentNote?.id == note.id
        let effectiveBody = isCurrent ? model.body : note.body
        let snapshot = cache.snapshot(for: note.id, body: effectiveBody)

        return VStack(spacing: 0) {
            InspectorPanelHeader(title: "Insights")
            Divider().overlay(theme.color(for: .separator))
            ScrollView {
                VStack(alignment: .leading, spacing: NoemaSpacing.lg) {
                    InspectorSection(title: "AI summary", showTopDivider: false) {
                        if snapshot.summaryText != nil {
                            InspectionAuthorityCaption(authority: .document)
                        }
                        AISummaryProviderDisclosure(provider: model.preferredAIProvider(for: .summarizePage))
                        AISummaryStatus(model: model, target: .page(note.id))
                        AISummaryControls(model: model, target: .page(note.id))
                        if let summaryText = snapshot.summaryText {
                            SidebarAISummary(text: summaryText).id(note.id)
                            Text(snapshot.summaryProvenanceLabel)
                                .font(NoemaTypography.metadata)
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        } else {
                            Text("No AI summary available.")
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        }
                    }

                    if isCurrent { SemanticInspectionSection(model: model, pageID: note.id).id("semantic-associations") }
                    InspectorSection(
                        title: "Semantic blocks",
                        count: snapshot.semanticBlockCount,
                        showTopDivider: true
                    ) {
                        if snapshot.semanticGroups.isEmpty {
                            Text("No semantic blocks on this page.")
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        } else {
                            ForEach(snapshot.semanticGroups) { group in
                                ForEach(group.blocks) { block in
                                    SemanticBlockSidebarRow(block: block) {
                                        model.editorAction = EditorAction(operation: .block(block.id))
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .textSelection(.enabled)
                .padding(.horizontal, NoemaMetrics.inspectorInset)
                .padding(.vertical, NoemaSpacing.md)
            }
            .modifier(OptionalScrollPositionModifier(position: scrollPosition))
            .onAppear {
                if model.semanticInspectionFocusID != nil { scrollPosition?.wrappedValue.scrollTo(id: "semantic-associations", anchor: .top) }
            }
            .onChange(of: model.semanticInspectionOpenRequest) {
                scrollPosition?.wrappedValue.scrollTo(id: "semantic-associations", anchor: .top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insights panel")
    }

    private func sourceInsightsView(_ source: SourceRecord) -> some View {
        let trimmedSummary = source.metadata.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = trimmedSummary?.isEmpty == false

        return VStack(spacing: 0) {
            InspectorPanelHeader(title: "Insights")
            Divider().overlay(theme.color(for: .separator))
            ScrollView {
                VStack(alignment: .leading, spacing: NoemaSpacing.lg) {
                    InspectorSection(title: "AI summary", showTopDivider: false) {
                        if hasSummary {
                            InspectionAuthorityCaption(authority: .document)
                        }
                        AISummaryProviderDisclosure(provider: model.preferredAIProvider(for: .summarizeSource))
                        AISummaryStatus(model: model, target: .source(source.id))
                        AISummaryControls(model: model, target: .source(source.id))
                        if let summary = source.metadata.aiSummary, hasSummary {
                            SidebarAISummary(text: summary).id(source.id)
                            Text(aiSummaryProvenanceLabel(provider: source.metadata.aiSummaryProvenance?.provider, model: source.metadata.aiSummaryProvenance?.model))
                                .font(NoemaTypography.metadata)
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        } else {
                            Text("No AI summary available.")
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, NoemaMetrics.inspectorInset)
                .padding(.vertical, NoemaSpacing.md)
            }
            .modifier(OptionalScrollPositionModifier(position: scrollPosition))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insights panel")
    }
}
