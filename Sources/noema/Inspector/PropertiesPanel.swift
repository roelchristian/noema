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
                        Text("Classification: \(model.preferredAIProvider(for: .classifyLCC).displayName)")
                            .font(NoemaTypography.metadata).foregroundStyle(.secondary)
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
                    Button("Refresh LCC · \(model.preferredAIProvider(for: .classifyLCC).displayName)") { model.refreshSourceLCC(source) }
                        .disabled(model.downloadingSources.contains(source.id) || model.generatingSourceLCCs.contains(source.id))
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
                        Text("Classification: \(model.preferredAIProvider(for: .classifyLCC).displayName)")
                            .font(NoemaTypography.metadata).foregroundStyle(.secondary)
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

    @ViewBuilder private func sourceLCCRow(_ source: SourceRecord) -> some View {
        LabeledContent {
            HStack(spacing: NoemaSpacing.xs) {
                TextField(
                    "None",
                    text: Binding(
                        get: { source.metadata.lcc ?? "" },
                        set: { model.updateSourceLCC(source, lcc: $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(NoemaTypography.metadata)
                .disabled(model.downloadingSources.contains(source.id) || model.generatingSourceLCCs.contains(source.id))
                if model.generatingSourceLCCs.contains(source.id) || model.generatingSourceTitles.contains(source.id) || model.generatingSourceSummaries.contains(source.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        model.refreshSourceLCC(source)
                    } label: {
                        Label("Refresh LCC", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.downloadingSources.contains(source.id))
                    .help("Refresh LCC using " + model.preferredAIProvider(for: .classifyLCC).displayName)
                }
            }
        } label: {
            Text("LCC").foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
        }
        .font(NoemaTypography.metadata)
    }

    @ViewBuilder private func pageLCCRow(_ note: NoteRecord) -> some View {
        LabeledContent {
            HStack(spacing: NoemaSpacing.xs) {
                if model.editingLocked {
                    let effectiveLCC = (model.currentNote?.id == note.id ? model.lccInput : (note.lcc ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(effectiveLCC.isEmpty ? "None" : effectiveLCC).foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                } else {
                    TextField(
                        "None",
                        text: Binding(
                            get: { model.lccInput },
                            set: { model.setPageLCC($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(NoemaTypography.metadata)
                    .disabled(model.generatingPageLCC)
                }
                if model.generatingPageLCC {
                    ProgressView().controlSize(.mini)
                } else if !model.editingLocked {
                    Button {
                        model.refreshPageLCC()
                    } label: {
                        Label("Refresh LCC", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Refresh LCC using " + model.preferredAIProvider(for: .classifyLCC).displayName)
                }
            }
        } label: {
            Text("LCC").foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
        }
        .font(NoemaTypography.metadata)
    }
}
