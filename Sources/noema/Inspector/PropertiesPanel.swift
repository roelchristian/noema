import SwiftUI
import AppKit
import VaultCore

/// Compact native inspector panel for page and source metadata, LCC classification, and editing status.
struct PropertiesPanel: View {
    @Bindable var model: AppModel
    let context: InspectorContext
    var scrollPosition: Binding<ScrollPosition>? = nil

    @Environment(\.noemaTheme) private var theme

    var body: some View {
        switch context {
        case .none:
            EmptyView()
        case .page(let note):
            pageProperties(note)
        case .source(let source, _):
            sourceProperties(source)
        }
    }

    private func pageProperties(_ note: NoteRecord) -> some View {
        VStack(spacing: 0) {
            InspectorPanelHeader(title: "Properties")
            Divider().overlay(theme.color(for: .separator))
            ScrollView {
                VStack(alignment: .leading, spacing: NoemaSpacing.lg) {
                    InspectorSection(title: "Classification & Identity", showTopDivider: false) {
                        pageLCCRow(note)
                        HStack {
                            Button("Suggest Title") { model.suggestPageTitle() }
                                .disabled(model.currentNote?.id != note.id || model.editingLocked || model.generatingPageTitle)
                            if model.generatingPageTitle { ProgressView().controlSize(.mini) }
                        }
                        Text("Title suggestions: \(model.preferredAIProvider(for: .suggestTitle).displayName)")
                            .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                        LabeledContent("Location") {
                            Button(note.relativePath) {
                                if let root = model.root {
                                    NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(note.relativePath)])
                                }
                            }
                            .buttonStyle(.link)
                            .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(note.relativePath)
                        }
                        .font(NoemaTypography.metadata)
                        InspectorProperty("Kind", "Markdown")
                        if !note.aliases.isEmpty {
                            InspectorProperty("Aliases", note.aliases.joined(separator: ", "))
                        }
                    }

                    InspectorSection(title: "Timestamps") {
                        InspectorProperty("Created", InspectorFormatting.metadataDate(note.createdAt))
                            .help(note.createdAt)
                        InspectorProperty("Modified", InspectorFormatting.metadataDate(note.updatedAt))
                            .help(note.updatedAt)
                    }

                    InspectorSection(title: "Status") {
                        LabeledContent("Editing") {
                            Button {
                                model.toggleEditingLock(note.id)
                            } label: {
                                Label(
                                    note.isEditingLocked ? "Unlock Editing" : "Lock Editing",
                                    systemImage: note.isEditingLocked ? "lock.fill" : "lock.open"
                                )
                            }
                            .buttonStyle(.borderless)
                            .help(note.isEditingLocked ? "Unlock Editing" : "Lock Editing")
                            .disabled(model.editingLockOperations.contains(note.id))
                        }
                        .font(NoemaTypography.metadata)
                        if model.editorReadOnly, model.currentNote?.id == note.id {
                            InspectorProperty("Access", "Read-only format")
                        }
                        InspectorProperty("Words", model.wordCount.formatted())
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, NoemaMetrics.inspectorInset)
                .padding(.vertical, NoemaSpacing.md)
            }
            .modifier(OptionalScrollPositionModifier(position: scrollPosition))
        }
    }

    private func sourceProperties(_ source: SourceRecord) -> some View {
        let kindLabel = source.metadata.originalFilename.split(separator: ".").last.map { $0.uppercased() } ?? "Source"
        return VStack(spacing: 0) {
            InspectorPanelHeader(title: "Properties") {
                Menu {
                    Button("Open Preview") { model.openSource(source.id) }
                    Button("Suggest Title · \(model.preferredAIProvider(for: .suggestTitle).displayName)") { model.suggestSourceTitle(source) }
                        .disabled(model.downloadingSources.contains(source.id) || model.generatingSourceTitles.contains(source.id))
                    Button("Check Availability") { model.checkSourceAvailability([source]) }
                        .disabled(model.checkingSourceAvailability.contains(source.id))
                } label: {
                    Label("Source actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Source actions")
                .accessibilityLabel("Source actions")
            }
            Divider().overlay(theme.color(for: .separator))
            ScrollView {
                VStack(alignment: .leading, spacing: NoemaSpacing.lg) {
                    InspectorSection(title: "Classification & File", showTopDivider: false) {
                        LabeledContent("Availability") {
                            sourceAvailabilityStatus(source.id, issue: source.availabilityIssue)
                        }
                        .font(NoemaTypography.metadata)
                        sourceLCCRow(source)
                        InspectorProperty("Original file", source.metadata.originalFilename)
                        InspectorProperty("Kind", kindLabel)
                        InspectorProperty("Location", source.metadata.isLinked ? "Linked" : "In vault")
                        if let size = source.metadata.fileSize {
                            InspectorProperty("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        }
                    }

                    InspectorSection(title: "Capture & Origin") {
                        InspectorProperty("Captured", InspectorFormatting.metadataDate(source.metadata.capturedAt))
                            .help(source.metadata.capturedAt)
                        if let origin = source.metadata.originURL, let url = URL(string: origin), !origin.isEmpty {
                            LabeledContent("Origin") {
                                Link(origin, destination: url)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(origin)
                            }
                            .font(NoemaTypography.metadata)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, NoemaMetrics.inspectorInset)
                .padding(.vertical, NoemaSpacing.md)
            }
            .modifier(OptionalScrollPositionModifier(position: scrollPosition))
        }
    }

    @ViewBuilder private func sourceAvailabilityStatus(_ id: UUID, issue: String?) -> some View {
        if model.downloadingSources.contains(id) {
            HStack(spacing: NoemaSpacing.sm) {
                ProgressView().controlSize(.mini)
                Text("Downloading from iCloud").foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
            }
        } else if model.checkingSourceAvailability.contains(id) {
            HStack(spacing: NoemaSpacing.sm) {
                ProgressView().controlSize(.mini)
                Text("Checking availability…").foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
            }
        } else {
            let label = model.sourceAvailability[id] ?? issue ?? "Available"
            Text(label).lineLimit(1).help(label)
        }
    }

    private func sourceLCCRow(_ source: SourceRecord) -> some View {
        classificationRow(LCCMetadataPresentation(classification: source.metadata.lccClassification,
            legacyCode: source.metadata.lcc, legacyProvenance: source.metadata.aiLCCProvenance))
    }

    private func pageLCCRow(_ note: NoteRecord) -> some View {
        classificationRow(LCCMetadataPresentation(classification: note.lccClassification,
            legacyCode: note.lcc, legacyProvenance: note.aiLCCProvenance))
    }

    private func classificationRow(_ metadata: LCCMetadataPresentation) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: NoemaSpacing.xs) {
                Text(metadata.code).foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                if let caption = metadata.caption {
                    Text(caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
            .help(metadata.detail)
            .accessibilityLabel(metadata.detail)
        } label: {
            Text("LCC").foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
        }
        .font(NoemaTypography.metadata)
    }
}

/// Presents generated metadata and preserves historical manual values without claiming AI origin.
struct LCCMetadataPresentation {
    let code: String
    let caption: String?
    let detail: String

    init(classification: LCCClassification?, legacyCode: String?, legacyProvenance: SummaryProvenance?) {
        let selectedCode = classification?.code ?? legacyCode
        code = selectedCode?.isEmpty == false ? selectedCode! : "None"
        caption = selectedCode.flatMap { LCCClassificationVocabulary.caption(for: $0) }
        let provenance = classification?.provenance ?? legacyProvenance
        var parts = [code]
        if let caption { parts.append(caption) }
        if let provenance {
            parts.append(aiSummaryProvenanceLabel(provider: provenance.provider, model: provenance.model))
            parts.append(provenance.generatedAt.formatted(date: .abbreviated, time: .shortened))
        } else if selectedCode != nil {
            parts.append("Preserved classification · Origin unspecified")
        }
        parts.append("Updated with content enrichment")
        detail = parts.joined(separator: " · ")
    }
}
