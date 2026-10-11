import SwiftUI
import VaultCore

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
            summaryProvenanceLabel: document.aiSummary?.metadata.extra["aiProvider"].map {
                $0 + " · " + (document.aiSummary?.metadata.extra["aiModel"] ?? "")
            } ?? "AI-generated on device",
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
    @Bindable var model: AppModel
    let context: InspectorContext
    let cache: InsightsPresentationCache
    var scrollPosition: Binding<ScrollPosition>? = nil

    @AppStorage(EditorPreferences.aiSummariesKey) private var aiSummaries = false

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
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorSection(title: "AI summary", showTopDivider: false) {
                        if !aiSummaries {
                            Text("Enable summaries in Noema → Settings → Apple Intelligence.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        CloudSummaryStatus(model: model, target: .page(note.id))
                        if isCurrent && model.generatingAISummary {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Generating summary…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let summaryText = snapshot.summaryText {
                            SidebarAISummary(text: summaryText).id(note.id)
                            Text(snapshot.summaryProvenanceLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No AI summary available.")
                                .foregroundStyle(.secondary)
                        }
                    } actions: {
                        Menu {
                            Button("Summarize with OpenAI…") { model.prepareCloudPageSummary(id: note.id) }
                                .disabled(note.isEditingLocked || model.cloudSummaryTarget != nil)
                            Button(snapshot.hasSummary ? "Regenerate Summary" : "Generate Summary") {
                                model.summarizePage()
                            }
                            .disabled(!aiSummaries || model.editingLocked || model.generatingAISummary)
                            if snapshot.hasSummary {
                                Button("Delete Summary", role: .destructive) {
                                    model.deleteAISummary()
                                }
                                .disabled(model.editingLocked || model.generatingAISummary)
                            }
                        } label: {
                            Label("Summary actions", systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Summary actions")
                    }

                    InspectorSection(
                        title: "Semantic blocks",
                        count: snapshot.semanticBlockCount,
                        showTopDivider: true
                    ) {
                        if snapshot.semanticGroups.isEmpty {
                            Text("No semantic blocks on this page.")
                                .foregroundStyle(.secondary)
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
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .modifier(OptionalScrollPositionModifier(position: scrollPosition))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insights panel")
    }

    private func sourceInsightsView(_ source: SourceRecord) -> some View {
        let trimmedSummary = source.metadata.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = trimmedSummary?.isEmpty == false

        return VStack(spacing: 0) {
            InspectorPanelHeader(title: "Insights")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorSection(title: "AI summary", showTopDivider: false) {
                        CloudSummaryStatus(model: model, target: .source(source.id))
                        if model.generatingSourceSummaries.contains(source.id) || model.generatingSourceTitles.contains(source.id) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Generating summary…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let summary = source.metadata.aiSummary, hasSummary {
                            SidebarAISummary(text: summary).id(source.id)
                            Text(source.metadata.aiSummaryProvenance.map { "\($0.provider) · \($0.model)" } ?? "AI-generated on device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No AI summary available.")
                                .foregroundStyle(.secondary)
                        }
                    } actions: {
                        Menu {
                            Button("Summarize with OpenAI…") { model.prepareCloudSourceSummary(source) }
                                .disabled(model.cloudSummaryTarget != nil || model.downloadingSources.contains(source.id)
                                    || model.generatingSourceTitles.contains(source.id) || model.generatingSourceSummaries.contains(source.id))
                        Button(hasSummary ? "Regenerate" : "Generate") {
                            model.generateSourceSummary(source)
                        }
                        .disabled(
                            model.downloadingSources.contains(source.id)
                                || model.generatingSourceTitles.contains(source.id)
                                || model.generatingSourceSummaries.contains(source.id)
                        )
                        .labelStyle(.titleOnly)
                        } label: { Label("Summary actions", systemImage: "ellipsis").labelStyle(.iconOnly) }
                        .menuStyle(.borderlessButton)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .modifier(OptionalScrollPositionModifier(position: scrollPosition))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insights panel")
    }
}
